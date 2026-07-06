import Foundation

/// Read-only ISO9660 (ECMA-119) reader with El Torito boot-image extraction.
///
/// Why hand-rolled: the install wizard needs exactly four things from the user's
/// Windows 98 CD image — prove it is an ISO at all, sanity-check that \WIN98 looks
/// like install media, read individual files out of it, and extract the El Torito
/// boot floppy the CD boots from. iOS has no API for any of that, and a filesystem
/// dependency would be wildly oversized for four operations against a frozen,
/// 1999-era disc format.
///
/// Access pattern: every read is a FileHandle seek + exact-length read of only the
/// sectors needed. A Win98 SE image is ~650 MB, so the image is NEVER loaded whole
/// (`Data(contentsOf:)` is banned here); the largest thing this type materializes
/// is the 1.44 MB boot floppy.
///
/// Scope decisions (all deliberate):
///  - Primary Volume Descriptor names only. Joliet SVDs (type 2) are skipped: the
///    wizard only touches 8.3 names like WIN98\*.CAB, which the PVD carries.
///  - No Rock Ridge, no multi-extent files (only matters past 4 GB), no
///    interleaving (never used on pressed data CDs).
///  - Not thread-safe: copies share one FileHandle whose seek offset is shared
///    state. The wizard reads from a single task at a time.
struct ISO9660Image {

    /// One directory entry, with the ISO9660 ";version" suffix already stripped.
    struct Entry: Equatable {
        let name: String
        let isDirectory: Bool
        let size: Int
    }

    enum ISOError: Error, LocalizedError, Equatable {
        case notISO9660(String)
        case truncated(String)
        case ioFailure(String, String)
        case malformed(String)
        case invalidArgument(String)
        case notFound(String)
        case notADirectory(String)
        case notAFile(String)
        case fileTooLarge(path: String, size: Int, limit: Int)
        case noBootRecord
        case badBootCatalog(String)
        case unsupportedBootMedia(UInt8, String)

        var errorDescription: String? {
            switch self {
            case .notISO9660(let why): return "Not a usable CD image: \(why)."
            case .truncated(let what): return "The CD image ends unexpectedly while reading \(what)."
            case .ioFailure(let what, let underlying):
                return "Couldn't read \(what) from the CD image: \(underlying)"
            case .malformed(let what): return "The CD image is damaged: \(what)."
            case .invalidArgument(let why): return "Invalid argument: \(why)."
            case .notFound(let path): return "\(path) does not exist on this CD."
            case .notADirectory(let path): return "\(path) is not a directory on this CD."
            case .notAFile(let path): return "\(path) is not a file on this CD."
            case .fileTooLarge(let path, let size, let limit):
                return "\(path) is \(size) bytes, over the \(limit)-byte limit."
            case .noBootRecord:
                return "This CD image is not bootable (no El Torito boot record)."
            case .badBootCatalog(let why): return "The CD's boot catalog is invalid: \(why)."
            case .unsupportedBootMedia(_, let why): return why
            }
        }
    }

    /// ISO9660 logical sector size. ECMA-119 technically allows 512/1024-byte
    /// logical blocks, but every CD mastering tool (and every Win98 disc) uses
    /// 2048 — the PVD's block-size field is validated in `init` so the constant
    /// can be assumed everywhere else.
    fileprivate static let sectorSize = 2048

    /// Directory extents on a Win98 disc are a few KB. `dataLength` comes off the
    /// disc, i.e. it is corruption-controlled, and reading a directory is the one
    /// place we allocate based on it — so cap it far above any real directory but
    /// far below "oops, 600 MB".
    private static let maxDirectoryExtentBytes = 4 << 20

    private let handle: FileHandle
    private let rootRecord: DirectoryRecord
    /// LBA of the El Torito boot catalog, if a boot volume descriptor was found.
    private let bootCatalogLBA: UInt32?

    // MARK: - Init (volume descriptor scan)

    init(url: URL) throws {
        let handle = try FileHandle(forReadingFrom: url)
        var root: DirectoryRecord?
        var catalog: UInt32?

        // Volume descriptors start at sector 16, one per sector, ending with a
        // type-255 terminator: [u8 type]["CD001"][u8 version]. Scan rather than
        // hardcode positions (the El Torito descriptor is USUALLY sector 17, but
        // that is convention, not spec). The cap keeps a corrupt image from
        // walking us through 650 MB of garbage.
        scan: for index in 16..<64 {
            guard let sector = try? Self.read(handle, at: UInt64(index) * UInt64(Self.sectorSize),
                                              count: Self.sectorSize, what: "volume descriptor"),
                  sector.ascii(1..<6) == "CD001" else {
                break scan // ran off the descriptor list (or the file) without a terminator
            }
            switch sector.u8(0) {
            case 1 where root == nil: // Primary Volume Descriptor
                guard sector.u16le(128) == UInt16(Self.sectorSize) else {
                    throw ISOError.notISO9660("logical block size is not 2048")
                }
                // The root directory record is the 34-byte field at PVD offset 156;
                // everything else in the volume is reached by walking from it.
                root = try Self.parseRecord(in: sector, at: 156)
            case 0: // Boot Record volume descriptor
                // Only El Torito boot records carry a catalog pointer; the boot
                // system identifier at offset 7 is the discriminator.
                if sector.ascii(7..<30) == "EL TORITO SPECIFICATION" {
                    catalog = sector.u32le(0x47)
                }
            case 255: // set terminator
                break scan
            default:
                continue // type 2 = Joliet SVD etc. — primary names are all we need
            }
        }
        guard let root, root.isDirectory else {
            throw ISOError.notISO9660("no Primary Volume Descriptor found at sector 16")
        }
        self.handle = handle
        self.rootRecord = root
        self.bootCatalogLBA = catalog
    }

    // MARK: - Public API

    /// True if `path` resolves to anything (file OR directory), mirroring
    /// `FileManager.fileExists` semantics.
    func fileExists(atPath path: String) -> Bool {
        (try? record(atPath: path)) != nil
    }

    /// Lists a directory ("" or "/" for the root). "." and ".." are omitted and
    /// ";version" suffixes are stripped, so names look the way DOS shows them.
    func list(directory path: String) throws -> [Entry] {
        let record = try record(atPath: path)
        guard record.isDirectory else { throw ISOError.notADirectory(path) }
        return try children(of: record).map {
            Entry(name: $0.name, isDirectory: $0.isDirectory, size: Int($0.dataLength))
        }
    }

    /// Reads a whole file. `maxBytes` is a hard guard, not a truncation limit:
    /// silently returning half of SETUP.EXE or a CAB would corrupt the install
    /// downstream, so an oversized file is an error the caller must handle.
    func readFile(atPath path: String, maxBytes: Int) throws -> Data {
        // A non-positive cap is a caller bug, not a property of the image — fail
        // loudly up front instead of reporting "over the -1-byte limit" later.
        guard maxBytes > 0 else {
            throw ISOError.invalidArgument("maxBytes must be positive, got \(maxBytes)")
        }
        let record = try record(atPath: path)
        guard !record.isDirectory else { throw ISOError.notAFile(path) }
        let size = Int(record.dataLength)
        guard size <= maxBytes else {
            throw ISOError.fileTooLarge(path: path, size: size, limit: maxBytes)
        }
        return try read(at: record.dataOffset, count: size, what: path)
    }

    /// Reads `count` bytes of a file starting at byte `offset` — the streaming
    /// counterpart of `readFile(atPath:maxBytes:)` for callers that copy
    /// CAB-sized files in bounded chunks (the FAT16 install-source builder)
    /// instead of materializing them. Ranges must lie inside the file: a
    /// partial answer would silently truncate whatever is being copied.
    ///
    /// Each call re-walks `path` (a few 2 KB directory-sector reads); at the
    /// builder's 4 MiB chunk size that overhead is noise, and it keeps this
    /// method stateless like the rest of the API.
    func readFile(atPath path: String, offset: Int, count: Int) throws -> Data {
        guard offset >= 0, count >= 0 else {
            throw ISOError.invalidArgument("offset and count must be non-negative")
        }
        let record = try record(atPath: path)
        guard !record.isDirectory else { throw ISOError.notAFile(path) }
        guard offset + count <= Int(record.dataLength) else {
            throw ISOError.invalidArgument(
                "range \(offset)..<\(offset + count) is outside \(path) (\(record.dataLength) bytes)")
        }
        return try read(at: record.dataOffset + UInt64(offset), count: count, what: path)
    }

    /// Cheap authenticity probe for the wizard's ISO picker: a Win98 SE CD has a
    /// \WIN98 directory holding SETUP.EXE plus dozens of *.CAB archives. Requiring
    /// ≥ 10 CABs rejects random ISOs and boot-floppy-only images without
    /// pretending to be a full media validation.
    func looksLikeWin98CD() -> Bool {
        guard let entries = try? list(directory: "WIN98") else { return false }
        let hasSetup = entries.contains { !$0.isDirectory && $0.name.uppercased() == "SETUP.EXE" }
        let cabCount = entries.filter { !$0.isDirectory && $0.name.uppercased().hasSuffix(".CAB") }.count
        return hasSetup && cabCount >= 10
    }

    /// Extracts the El Torito boot image — for a Win98 SE CD, the 1.44 MB boot
    /// floppy that DOS boots from (media type 2, floppy emulation).
    func extractElToritoBootImage() throws -> Data {
        guard let catalogLBA = bootCatalogLBA else { throw ISOError.noBootRecord }
        // Validation entry (32 bytes) + initial/default entry (32 bytes) is all
        // we need from the catalog sector.
        let catalog = try read(at: UInt64(catalogLBA) * UInt64(Self.sectorSize),
                               count: 64, what: "El Torito boot catalog")

        // Validation entry: header 0x01, key bytes 55 AA, and a checksum field
        // chosen at mastering time so all sixteen 16-bit words sum to zero.
        // Verifying it is what distinguishes "boot catalog" from "pointer into
        // random sectors" — a wrong catalog LBA would boot-extract garbage.
        guard catalog.u8(0) == 0x01 else {
            throw ISOError.badBootCatalog("validation entry has wrong header ID")
        }
        guard catalog.u8(0x1E) == 0x55, catalog.u8(0x1F) == 0xAA else {
            throw ISOError.badBootCatalog("validation entry missing 55AA key bytes")
        }
        var sum: UInt32 = 0
        for word in 0..<16 { sum &+= UInt32(catalog.u16le(word * 2)) }
        guard sum % 0x10000 == 0 else {
            throw ISOError.badBootCatalog("validation entry checksum mismatch")
        }

        // Initial/default entry — the one the BIOS actually boots.
        let entry = 32
        guard catalog.u8(entry) == 0x88 else {
            throw ISOError.badBootCatalog("initial entry is not marked bootable")
        }
        // The u16 at +6 is how many 512-byte VIRTUAL sectors the BIOS loads
        // initially (usually 1). It is NOT the image size — for floppy emulation
        // the size is implied by the media type.
        let imageBytes: Int
        switch catalog.u8(entry + 1) {
        case 1: imageBytes = 1_228_800 // 1.2 MB floppy (2400 × 512)
        case 2: imageBytes = 1_474_560 // 1.44 MB floppy (2880 × 512) — Win98 SE retail
        case 3: imageBytes = 2_949_120 // 2.88 MB floppy (5760 × 512)
        case 0:
            throw ISOError.unsupportedBootMedia(0,
                "This CD uses no-emulation boot, not a boot floppy — it doesn't look like a retail Windows 98 CD")
        case 4:
            throw ISOError.unsupportedBootMedia(4,
                "This CD uses hard-disk-emulation boot, not a boot floppy — it doesn't look like a retail Windows 98 CD")
        case let other:
            throw ISOError.unsupportedBootMedia(other, "Unknown El Torito media type \(other)")
        }
        let loadRBA = catalog.u32le(entry + 8) // in 2048-byte CD sectors
        return try read(at: UInt64(loadRBA) * UInt64(Self.sectorSize),
                        count: imageBytes, what: "boot image")
    }

    // MARK: - Directory records

    /// One parsed directory record — just the fields the wizard needs.
    private struct DirectoryRecord {
        let name: String // normalized; "." / ".." for the self/parent entries
        let extentLBA: UInt32
        let extendedAttributeBlocks: UInt8
        let dataLength: UInt32
        let isDirectory: Bool

        /// Extended attribute records, when present, occupy the FIRST blocks of
        /// the extent; the actual data starts after them. Win98 discs use none,
        /// but honoring the field is two tokens of correctness.
        var dataOffset: UInt64 {
            (UInt64(extentLBA) + UInt64(extendedAttributeBlocks)) * UInt64(ISO9660Image.sectorSize)
        }
    }

    /// Walks `path` from the root, one segment at a time. Both "/" and "\" are
    /// accepted as separators (callers think in DOS paths), matching is
    /// case-insensitive, and ";1"-style version suffixes never need to be typed.
    private func record(atPath path: String) throws -> DirectoryRecord {
        var current = rootRecord
        for segment in path.split(whereSeparator: { $0 == "/" || $0 == "\\" }) {
            guard current.isDirectory else { throw ISOError.notADirectory(path) }
            let key = Self.normalize(String(segment)).uppercased()
            guard let next = try children(of: current).first(where: { $0.name.uppercased() == key }) else {
                throw ISOError.notFound(path)
            }
            current = next
        }
        return current
    }

    /// Reads and parses a directory's extent. Every entry except "." / ".." is
    /// returned, in on-disc order.
    private func children(of directory: DirectoryRecord) throws -> [DirectoryRecord] {
        let size = Int(directory.dataLength)
        guard size <= Self.maxDirectoryExtentBytes else {
            throw ISOError.malformed("directory extent claims \(size) bytes")
        }
        let data = try read(at: directory.dataOffset, count: size, what: "directory extent")

        var records: [DirectoryRecord] = []
        var pos = 0
        while pos < size {
            let length = Int(data.u8(pos))
            if length == 0 {
                // Records never span a sector boundary; mastering tools zero-pad
                // the tail of a sector instead. A zero length byte therefore
                // means "resume at the next sector", not "end of directory".
                pos = (pos / Self.sectorSize + 1) * Self.sectorSize
                continue
            }
            guard pos + length <= size else {
                throw ISOError.malformed("directory record overruns its extent")
            }
            let record = try Self.parseRecord(in: data, at: pos)
            if record.name != ".", record.name != ".." {
                records.append(record)
            }
            pos += length
        }
        return records
    }

    /// Parses one on-disc directory record (ECMA-119 §9.1). Offsets:
    /// +0 u8 record length · +1 u8 ext-attr blocks · +2 u32le extent LBA (the LE
    /// half of a both-endian field) · +10 u32le data length (ditto) · +25 flags
    /// (bit 1 = directory) · +32 u8 name length · +33 name bytes.
    private static func parseRecord(in data: Data, at offset: Int) throws -> DirectoryRecord {
        let length = Int(data.u8(offset))
        guard length >= 34, offset + length <= data.count else {
            throw ISOError.malformed("directory record too short")
        }
        let nameLength = Int(data.u8(offset + 32))
        guard nameLength >= 1, 33 + nameLength <= length else {
            throw ISOError.malformed("directory record name overruns the record")
        }

        let name: String
        let firstNameByte = data.u8(offset + 33)
        if nameLength == 1, firstNameByte == 0x00 {
            name = "." // the directory's own entry
        } else if nameLength == 1, firstNameByte == 0x01 {
            name = ".." // parent
        } else {
            name = normalize(data.ascii((offset + 33)..<(offset + 33 + nameLength)))
        }

        return DirectoryRecord(
            name: name,
            extentLBA: data.u32le(offset + 2),
            extendedAttributeBlocks: data.u8(offset + 1),
            dataLength: data.u32le(offset + 10),
            isDirectory: data.u8(offset + 25) & 0x02 != 0
        )
    }

    /// ISO9660 file identifiers carry a ";version" suffix (in practice always
    /// ";1") and can end in a bare "." when the extension is empty — both are
    /// mastering artifacts nobody types, so strip them for display and matching.
    private static func normalize(_ rawName: String) -> String {
        var name = rawName
        if let semicolon = name.firstIndex(of: ";") { name = String(name[..<semicolon]) }
        if name.hasSuffix("."), name.count > 1 { name.removeLast() }
        return name
    }

    // MARK: - Raw sector I/O

    /// Seek + read EXACTLY `count` bytes. Every caller knows precisely how many
    /// bytes the format promises at that offset, so a short read always means a
    /// truncated (or lying) image — surfacing that beats returning partial data.
    private static func read(_ handle: FileHandle, at offset: UInt64, count: Int, what: String) throws -> Data {
        guard count > 0 else { return Data() }
        let data: Data?
        do {
            try handle.seek(toOffset: offset)
            data = try handle.read(upToCount: count)
        } catch {
            // Wrap mid-read I/O failures (an iCloud-evicted file disappearing
            // under us, a yanked USB volume) so wizard-facing errors stay
            // LocalizedError end-to-end instead of leaking a raw POSIX NSError.
            throw ISOError.ioFailure(what, error.localizedDescription)
        }
        guard let data, data.count == count else {
            throw ISOError.truncated(what)
        }
        return data
    }

    private func read(at offset: UInt64, count: Int, what: String) throws -> Data {
        try Self.read(handle, at: offset, count: count, what: what)
    }
}

// MARK: - Little-endian field access

private extension Data {
    /// All accessors are relative to `startIndex`: Data SLICES keep the parent's
    /// indices, so raw `self[offset]` would silently read the wrong bytes the
    /// day someone passes a slice in.
    func u8(_ offset: Int) -> UInt8 {
        self[startIndex + offset]
    }

    func u16le(_ offset: Int) -> UInt16 {
        UInt16(u8(offset)) | UInt16(u8(offset + 1)) << 8
    }

    func u32le(_ offset: Int) -> UInt32 {
        UInt32(u16le(offset)) | UInt32(u16le(offset + 2)) << 16
    }

    func ascii(_ range: Range<Int>) -> String {
        String(decoding: self[(startIndex + range.lowerBound)..<(startIndex + range.upperBound)],
               as: UTF8.self)
    }
}
