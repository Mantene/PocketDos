import Foundation

/// Edits a FAT32 sockdrive WITHOUT touching its chunk files: every mutation is
/// appended to the drive's write-overlay blob (sockdrive `serializeSectors`
/// format), exactly the artifact the emulator replays over the chunks at boot.
///
/// This is the install wizard's post-install surgeon: after Windows 98 Setup
/// finishes, the mouse is dead in integration mode until DBOXMPI.DRV lands in
/// C:\WINDOWS and C:\WINDOWS\SYSTEM and SYSTEM.INI's three mouse lines point
/// at it (LEG 6). Doing that on-device means editing a FAT32 volume that only
/// exists as (chunks ∥ overlay) — no raw image, no mtools — so this type reads
/// sectors through the same precedence the client uses (overlay wins, then
/// chunk, then zeros) and writes by appending raw records to the overlay.
/// Append-only is not laziness, it is the format's own semantics: the client
/// replays records in order and later records supersede earlier ones, so an
/// appended sector IS an edit, with the original blob left bit-identical as a
/// bonus audit trail.
///
/// Overlay blob format (mirrors wizard-s0/flatten-writes.js, the proven
/// reference decoder): u32le record count, then per record u32le blockLen +
/// block. blockLen == 516 → raw u32le absolute LBA + 512 bytes of sector data;
/// anything else → an LZ4 block that decodes to those same 516 bytes. Writes
/// here always append the RAW form — compression would buy a few KB on a
/// one-shot fix and cost a second encoder implementation to trust.
///
/// FAT32 reality, mirrored from FAT12Floppy one level up:
///  - the volume lives inside an MBR partition (LBA 63 on the production
///    template — read from the MBR, never assumed);
///  - FAT entries are 32 bits of which only the low 28 count (mask 0x0FFFFFFF;
///    the top 4 are reserved and preserved verbatim on write);
///  - the root directory is a normal cluster chain (BPB rootCluster), not a
///    fixed region, so it grows through the same code path as any directory.
///
/// NO minimum-cluster-count check on purpose: the FAT32 spec draws the
/// FAT16/FAT32 line at 65525 clusters, but the volume's own layout markers
/// (fatSize16 == 0, rootEntryCount == 0, a rootCluster field) say what it IS,
/// and both Win98 and DOSBox accept undersized FAT32 volumes — as do the
/// compact synthetic volumes the tests are built on.
final class FAT32OverlayEditor {

    // MARK: - Constants

    static let sectorSize = 512
    /// Sockdrive chunk granularity: chunk i covers disk bytes
    /// [i*262144, (i+1)*262144); a missing chunk file means those bytes are 0.
    static let chunkBytes = 262_144
    private static let sectorsPerChunk = chunkBytes / sectorSize

    /// End-of-chain value written for new chains — the canonical maximum,
    /// matching what Windows itself writes. Reads accept the whole EOC band
    /// (masked value ≥ 0x0FFFFFF8).
    private static let endOfChain: UInt32 = 0x0FFF_FFFF
    private static let fatMask: UInt32 = 0x0FFF_FFFF

    /// New directory entries carry the same fixed timestamp FAT16ImageBuilder
    /// stamps: edits must be deterministic (byte-identical overlays are what
    /// the oracle and tests compare). 2026-07-05 12:00:00.
    private static let fixedDate = ((2026 - 1980) << 9) | (7 << 5) | 5
    private static let fixedTime = 12 << 11

    // MARK: - Errors

    enum EditorError: Error, LocalizedError, Equatable {
        case malformedOverlay(String)
        case notFAT32(String)
        case invalidName(String)
        case fileNotFound(String)
        case notADirectory(String)
        case duplicateEntry(String)
        case contentTooLarge(file: String, size: Int, capacity: Int)
        case volumeFull(String)
        case malformedVolume(String)
        case missingLine(String)

        var errorDescription: String? {
            switch self {
            case .malformedOverlay(let why):
                return "The write-overlay blob is damaged: \(why)."
            case .notFAT32(let why):
                return "Not a usable FAT32 sockdrive: \(why)."
            case .invalidName(let name):
                return "\"\(name)\" is not an 8.3 DOS path component."
            case .fileNotFound(let path):
                return "\(path) does not exist on the volume."
            case .notADirectory(let path):
                return "\(path) is not a directory."
            case .duplicateEntry(let path):
                return "\(path) already exists on the volume."
            case .contentTooLarge(let file, let size, let capacity):
                return "\(file): new content is \(size) bytes but the file's cluster chain "
                    + "only holds \(capacity) — in-place replacement never grows a file."
            case .volumeFull(let what):
                return "The volume has no free clusters left for \(what)."
            case .malformedVolume(let what):
                return "The FAT32 volume is damaged: \(what)."
            case .missingLine(let line):
                return "The file is missing the expected line \"\(line)\" — refusing to "
                    + "half-apply an edit to an unrecognized configuration."
            }
        }
    }

    // MARK: - State

    /// The overlay blob: the original records verbatim, plus everything this
    /// editor appended, with the leading u32le count kept current. This is the
    /// artifact to persist — hand it to the emulator as the drive's restore
    /// blob and every edit replays in order.
    private(set) var overlay: Data
    /// Raw 516-byte records appended so far (for reporting; each is one sector).
    private(set) var appendedRecords = 0

    /// LBA → current 512-byte sector content, the overlay replayed to its end
    /// state. Later records superseded earlier ones during the parse, and
    /// every write updates this map too, so reads always see the newest data.
    private var overlayMap: [UInt32: Data]
    private var recordCount: UInt32
    private let chunkProvider: (Int) throws -> Data?
    /// Chunk cache: `.some(nil)` records "asked, chunk absent" so missing
    /// chunks (= all zeros) don't re-hit the provider on every sector read.
    private var chunkCache: [Int: Data?]
    private let geo: Geometry
    /// Free-cluster scan cursor. Allocation is first-fit from cluster 2;
    /// the cursor only ever advances because nothing here frees clusters.
    private var freeScanCursor = 2

    // MARK: - Init

    /// `chunkProvider` returns chunk i's 262144 bytes, or nil when the chunk
    /// file does not exist (sockdrive drops all-zero chunks at build time).
    init(overlay: Data, chunkProvider: @escaping (Int) throws -> Data?) throws {
        let (map, count) = try Self.parse(overlay: overlay)
        var cache: [Int: Data?] = [:]
        let geometry = try Self.parseGeometry { lba in
            try Self.compositeRead(lba: lba, map: map, provider: chunkProvider, cache: &cache)
        }
        self.overlay = overlay
        self.overlayMap = map
        self.recordCount = count
        self.chunkProvider = chunkProvider
        self.chunkCache = cache
        self.geo = geometry
    }

    /// The production shape: a directory of `<i>.raw` chunk files as written
    /// by the sockdrive chunker (missing file = zero chunk).
    convenience init(overlay: Data, chunksDirectory: URL) throws {
        try self.init(overlay: overlay) { index in
            let url = chunksDirectory.appendingPathComponent("\(index).raw")
            guard FileManager.default.fileExists(atPath: url.path) else { return nil }
            return try Data(contentsOf: url)
        }
    }

    // MARK: - Composite reads

    /// One sector through the client's exact precedence: overlay record if any,
    /// else the backing chunk, else zeros (missing chunk).
    func readSector(_ lba: Int) throws -> Data {
        try Self.compositeRead(lba: lba, map: overlayMap, provider: chunkProvider,
                               cache: &chunkCache)
    }

    private static func compositeRead(lba: Int, map: [UInt32: Data],
                                      provider: (Int) throws -> Data?,
                                      cache: inout [Int: Data?]) throws -> Data {
        guard lba >= 0, lba <= UInt32.max else {
            throw EditorError.malformedVolume("sector \(lba) is not addressable")
        }
        if let sector = map[UInt32(lba)] { return sector }
        let chunkIndex = lba / sectorsPerChunk
        let chunk: Data?
        if let cached = cache[chunkIndex] {
            chunk = cached
        } else {
            chunk = try provider(chunkIndex)
            if let chunk, chunk.count != chunkBytes {
                throw EditorError.malformedVolume(
                    "chunk \(chunkIndex) is \(chunk.count) bytes, expected \(chunkBytes)")
            }
            cache[chunkIndex] = chunk
        }
        guard let chunk else { return Data(count: sectorSize) }
        let offset = (lba % sectorsPerChunk) * sectorSize
        return chunk.subdata(in: (chunk.startIndex + offset)..<(chunk.startIndex + offset + sectorSize))
    }

    /// A whole file's content, resolved through the composite view.
    func readFile(path: String) throws -> Data {
        let entry = try locateFile(path: path)
        let chain = try clusterChain(from: entry.firstCluster, what: path)
        return try readContent(chain: chain, size: entry.fileSize)
    }

    // MARK: - Overlay append (the only write primitive)

    /// Appends one raw 516-byte record (u32le LBA + sector data) and bumps the
    /// blob's leading count. Later-wins replay makes this a plain overwrite
    /// from the client's point of view; the map is updated so this editor's
    /// own subsequent reads see it too.
    private func writeSector(_ lba: Int, _ sector: [UInt8]) throws {
        precondition(sector.count == Self.sectorSize)
        guard lba >= 0, lba < geo.partitionStart + geo.totalSectors else {
            throw EditorError.malformedVolume("write to sector \(lba) is outside the volume")
        }
        var record = [UInt8](repeating: 0, count: 8)
        put32(&record, 0, 516)
        put32(&record, 4, lba)
        overlay.append(contentsOf: record)
        overlay.append(contentsOf: sector)
        recordCount += 1
        appendedRecords += 1
        var countField = [UInt8](repeating: 0, count: 4)
        put32(&countField, 0, Int(recordCount))
        overlay.replaceSubrange(overlay.startIndex..<(overlay.startIndex + 4), with: countField)
        overlayMap[UInt32(lba)] = Data(sector)
    }

    // MARK: - Public operations

    /// Replaces `path`'s content in place: same directory entry, same cluster
    /// chain, content zero-padded across the chain's full capacity so no bytes
    /// of the old content survive, then the entry's size field updated.
    /// Content larger than the existing chain THROWS by design — growing a
    /// file is `addFile`'s allocation problem, and the one file this op exists
    /// for (SYSTEM.INI, ~1.7 KB in a 4 KiB cluster) never needs it.
    func replaceFile(path: String, transform: (Data) throws -> Data) throws {
        let entry = try locateFile(path: path)
        let chain = try clusterChain(from: entry.firstCluster, what: path)
        let oldContent = try readContent(chain: chain, size: entry.fileSize)
        let newContent = try transform(oldContent)

        let capacity = chain.count * geo.clusterBytes
        guard newContent.count <= capacity else {
            throw EditorError.contentTooLarge(file: path, size: newContent.count,
                                              capacity: capacity)
        }

        // Content sectors in chain order, zero-padded to the chain's end.
        for (index, cluster) in chain.enumerated() {
            for s in 0..<geo.sectorsPerCluster {
                let start = min(index * geo.clusterBytes + s * Self.sectorSize, newContent.count)
                let end = min(start + Self.sectorSize, newContent.count)
                var sector = [UInt8](newContent[(newContent.startIndex + start)..<(newContent.startIndex + end)])
                sector.append(contentsOf: [UInt8](repeating: 0, count: Self.sectorSize - sector.count))
                try writeSector(geo.lba(ofCluster: cluster) + s, sector)
            }
        }

        // Directory entry: only the 32-bit size field changes.
        var dirSector = [UInt8](try readSector(entry.lba))
        put32(&dirSector, entry.offset + 28, newContent.count)
        try writeSector(entry.lba, dirSector)
    }

    /// Adds a new file: clusters allocated first-fit from the FAT (entries
    /// written in BOTH copies), data written sector-by-sector with the final
    /// cluster's slack zeroed (a freed-then-reused cluster may hold stale
    /// bytes in the chunks), an 8.3 entry appended to the parent directory
    /// (growing its chain when full), and FSInfo invalidated.
    func addFile(path: String, data: Data) throws {
        let (parentCluster, name11, _) = try locateParent(path: path)
        guard try find(name11: name11, inChainFrom: parentCluster) == nil else {
            throw EditorError.duplicateEntry(path)
        }

        // Zero-byte files own no clusters at all (first cluster 0), exactly
        // like DOS writes them.
        var firstCluster = 0
        if !data.isEmpty {
            let clusters = try allocateClusters(
                count: (data.count + geo.clusterBytes - 1) / geo.clusterBytes, for: path)
            firstCluster = clusters[0]
            var links: [(cluster: Int, value: UInt32)] = []
            for (i, cluster) in clusters.enumerated() {
                links.append((cluster, i == clusters.count - 1 ? Self.endOfChain
                                                               : UInt32(clusters[i + 1])))
            }
            try writeFATEntries(links)
            for (index, cluster) in clusters.enumerated() {
                for s in 0..<geo.sectorsPerCluster {
                    let start = min(index * geo.clusterBytes + s * Self.sectorSize, data.count)
                    let end = min(start + Self.sectorSize, data.count)
                    var sector = [UInt8](data[(data.startIndex + start)..<(data.startIndex + end)])
                    sector.append(contentsOf: [UInt8](repeating: 0, count: Self.sectorSize - sector.count))
                    try writeSector(geo.lba(ofCluster: cluster) + s, sector)
                }
            }
        }

        try appendDirectoryEntry(
            Self.directoryEntry(name11: name11, attributes: 0x20, // archive, like fresh DOS copies
                                firstCluster: firstCluster, fileSize: data.count),
            toDirectoryAt: parentCluster, path: path)

        if !data.isEmpty { try invalidateFSInfo() }
    }

    /// The dboxmpi.drv mouse fix, exactly as proven in LEG 6: the driver into
    /// WINDOWS and WINDOWS\SYSTEM, plus SYSTEM.INI's three mouse lines. The
    /// SYSTEM.INI patch is validated (and the driver's absence checked) BEFORE
    /// the first write lands, so pointing this at a wrong or already-fixed
    /// image fails loudly with the overlay untouched instead of half-applied.
    func applyMouseFix(driver: Data) throws {
        let iniPath = "WINDOWS/SYSTEM.INI"
        _ = try Self.patchSystemINI(try readFile(path: iniPath))
        for target in ["WINDOWS/DBOXMPI.DRV", "WINDOWS/SYSTEM/DBOXMPI.DRV"] {
            let (parentCluster, name11, _) = try locateParent(path: target)
            guard try find(name11: name11, inChainFrom: parentCluster) == nil else {
                throw EditorError.duplicateEntry(target)
            }
        }

        try replaceFile(path: iniPath, transform: Self.patchSystemINI)
        try addFile(path: "WINDOWS/DBOXMPI.DRV", data: driver)
        try addFile(path: "WINDOWS/SYSTEM/DBOXMPI.DRV", data: driver)
    }

    /// The three SYSTEM.INI line replacements from the known-good June image.
    /// Whole-line exact matches on CRLF boundaries: [boot] mouse.drv switches
    /// to the DOSBox-X integration driver, [boot.description] follows for the
    /// Control Panel's benefit, and [386Enh] mouse= loses `*vmouse,
    /// msmouse.vxd` so the VxD stops fighting the driver for the pointer.
    static let systemINIReplacements: [(from: String, to: String)] = [
        ("mouse.drv=mouse.drv", "mouse.drv=dboxmpi.drv"),
        ("mouse.drv=Standard mouse", "mouse.drv=DOSBox-X Mouse Pointer Integration"),
        ("mouse=*vmouse, msmouse.vxd", "mouse="),
    ]

    /// Applies the replacements line-wise, preserving CRLF endings and every
    /// other byte. Each expected line must appear EXACTLY once — zero means
    /// this is not the SYSTEM.INI the fix was proven against (or the fix
    /// already ran), and silence there would ship a dead mouse.
    static func patchSystemINI(_ content: Data) throws -> Data {
        // Latin-1 is a byte↔scalar bijection, so decode/encode round-trips
        // every byte exactly; the file never leaves single-byte land.
        guard let text = String(data: content, encoding: .isoLatin1) else {
            throw EditorError.malformedVolume("SYSTEM.INI is not decodable text")
        }
        var lines = text.components(separatedBy: "\r\n")
        for (from, to) in systemINIReplacements {
            let hits = lines.indices.filter { lines[$0] == from }
            guard hits.count == 1 else { throw EditorError.missingLine(from) }
            lines[hits[0]] = to
        }
        guard let patched = lines.joined(separator: "\r\n").data(using: .isoLatin1) else {
            throw EditorError.malformedVolume("patched SYSTEM.INI failed to re-encode")
        }
        return patched
    }

    /// Best-effort ScanDisk suppression for the shipped machine: ensures
    /// `AutoScan=0` under [Options] in C:\MSDOS.SYS. Panic-interrupted
    /// install re-runs leave the FAT crash-consistent ("dirty"), and Win98's
    /// next boot then parks on ScanDisk's prompt — a stall on an unattended
    /// boot. MSDOS.SYS is +r+s+h CRLF text with a >1 KB `;x…` comment filler;
    /// attributes and every other byte survive (replaceFile rewrites content
    /// and the size field only), the usual `AutoScan=1` → `=0` flip is
    /// size-neutral, and an insertion adds 12 bytes — replaceFile's chain-
    /// capacity check still guards the ceiling. Unlike applyMouseFix the
    /// CALLER treats a throw here as non-fatal (log-and-ship); like it, an
    /// unrecognized shape throws BEFORE anything is written.
    func applyAutoScanOff() throws {
        let path = "MSDOS.SYS"
        let current = try readFile(path: path)
        let patched = try Self.patchMSDOSSYS(current)
        guard patched != current else { return }   // already AutoScan=0 — write nothing
        try replaceFile(path: path) { _ in patched }
    }

    /// The MSDOS.SYS transform: within the [Options] section only, the
    /// `AutoScan=` line becomes `AutoScan=0` (inserted right under the
    /// section header when absent); every other byte — [Paths], the WinVer
    /// line, the Mxxx `;x…` size filler, CRLF endings — survives verbatim.
    /// Already-0 returns the input unchanged so the caller can skip the
    /// write. No [Options] section (or undecodable content) is not the
    /// MSDOS.SYS shape this was written against: throw, caller decides how
    /// loud to be.
    static func patchMSDOSSYS(_ content: Data) throws -> Data {
        guard let text = String(data: content, encoding: .isoLatin1) else {
            throw EditorError.malformedVolume("MSDOS.SYS is not decodable text")
        }
        var lines = text.components(separatedBy: "\r\n")
        guard let options = lines.firstIndex(where: {
            $0.caseInsensitiveCompare("[Options]") == .orderedSame
        }) else {
            throw EditorError.missingLine("[Options]")
        }
        let sectionEnd = lines[(options + 1)...].firstIndex { $0.hasPrefix("[") } ?? lines.endIndex
        if let hit = lines[(options + 1)..<sectionEnd].firstIndex(where: {
            $0.lowercased().hasPrefix("autoscan=")
        }) {
            if lines[hit] == "AutoScan=0" { return content }
            lines[hit] = "AutoScan=0"
        } else {
            lines.insert("AutoScan=0", at: options + 1)
        }
        guard let patched = lines.joined(separator: "\r\n").data(using: .isoLatin1) else {
            throw EditorError.malformedVolume("patched MSDOS.SYS failed to re-encode")
        }
        return patched
    }

    // MARK: - Overlay blob parsing

    /// Replays the blob into an LBA → sector map. The mini-LZ4 block decoder
    /// is ported from wizard-s0/flatten-writes.js lines 8-30 (itself from
    /// js-dos's mini-lz4, node-lz4 lineage, MIT) — the exact decoder the
    /// production client uses, so what it accepts, this accepts.
    private static func parse(overlay: Data) throws -> (map: [UInt32: Data], count: UInt32) {
        guard overlay.count >= 4 else {
            throw EditorError.malformedOverlay("\(overlay.count) bytes is too short for a record count")
        }
        let count = overlay.u32le(0)
        var map: [UInt32: Data] = [:]
        var offset = 4
        var scratch = [UInt8](repeating: 0, count: 516)
        for index in 0..<Int(count) {
            guard offset + 4 <= overlay.count else {
                throw EditorError.malformedOverlay("record \(index) is truncated")
            }
            let length = Int(overlay.u32le(offset))
            offset += 4
            guard length >= 1, offset + length <= overlay.count else {
                throw EditorError.malformedOverlay("record \(index) claims \(length) bytes")
            }
            let lba: UInt32
            let sector: Data
            if length == 516 {
                lba = overlay.u32le(offset)
                sector = overlay.subdata(
                    in: (overlay.startIndex + offset + 4)..<(overlay.startIndex + offset + 516))
            } else {
                let block = overlay.subdata(
                    in: (overlay.startIndex + offset)..<(overlay.startIndex + offset + length))
                guard lz4BlockDecode(block, into: &scratch) == 516 else {
                    throw EditorError.malformedOverlay("record \(index) failed LZ4 decode")
                }
                lba = UInt32(scratch[0]) | UInt32(scratch[1]) << 8
                    | UInt32(scratch[2]) << 16 | UInt32(scratch[3]) << 24
                sector = Data(scratch[4..<516])
            }
            map[lba] = sector // later records supersede earlier: replay order
            offset += length
        }
        guard offset == overlay.count else {
            throw EditorError.malformedOverlay(
                "\(overlay.count - offset) trailing bytes after the last record")
        }
        return (map, count)
    }

    /// Mini-LZ4 block decode. Faithful port of the JS reference, plus the
    /// bounds checks Swift demands where JS silently reads undefined: any
    /// out-of-range access means a malformed block, reported as nil. Returns
    /// the decoded byte count on success (the caller requires exactly 516).
    private static func lz4BlockDecode(_ input: Data, into output: inout [UInt8]) -> Int? {
        let bytes = [UInt8](input)
        let n = bytes.count
        let capacity = output.count
        var i = 0
        var j = 0
        while i < n {
            let token = Int(bytes[i]); i += 1
            var literals = token >> 4
            if literals > 0 {
                var l = literals + 240
                while l == 255 {
                    guard i < n else { return nil }
                    l = Int(bytes[i]); i += 1
                    literals += l
                }
                guard i + literals <= n, j + literals <= capacity else { return nil }
                for _ in 0..<literals {
                    output[j] = bytes[i]
                    i += 1
                    j += 1
                }
                if i == n { return j } // terminal literals-only sequence
            }
            guard i + 1 < n else { return nil }
            let offset = Int(bytes[i]) | Int(bytes[i + 1]) << 8
            i += 2
            if offset == 0 { return j }
            guard offset <= j else { return nil }
            var matchLength = token & 0xF
            var l = matchLength + 240
            while l == 255 {
                guard i < n else { return nil }
                l = Int(bytes[i]); i += 1
                matchLength += l
            }
            var pos = j - offset
            let end = j + matchLength + 4
            guard end <= capacity else { return nil }
            while j < end {
                output[j] = output[pos]
                pos += 1
                j += 1
            }
        }
        return nil // input exhausted mid-sequence
    }

    // MARK: - FAT32 geometry

    private struct Geometry {
        let partitionStart: Int      // absolute LBA of the volume (MBR entry 0)
        let sectorsPerCluster: Int
        let reservedSectors: Int
        let fatCount: Int
        let fatSectors: Int          // FATSz32
        let totalSectors: Int        // partition-relative
        let rootCluster: Int
        let fsInfoSector: Int        // partition-relative
        let clusterCount: Int

        var fatStart: Int { partitionStart + reservedSectors }
        var dataStart: Int { fatStart + fatCount * fatSectors }
        var clusterBytes: Int { sectorsPerCluster * FAT32OverlayEditor.sectorSize }
        var maxCluster: Int { clusterCount + 1 }
        func lba(ofCluster cluster: Int) -> Int {
            dataStart + (cluster - 2) * sectorsPerCluster
        }
    }

    private static func parseGeometry(read: (Int) throws -> Data) throws -> Geometry {
        // MBR first: the volume's location is the partition table's to declare.
        let mbr = try read(0)
        guard mbr.u8(510) == 0x55, mbr.u8(511) == 0xAA else {
            throw EditorError.notFAT32("MBR is missing its 55AA signature")
        }
        let entry = 0x1BE
        let partitionType = mbr.u8(entry + 4)
        guard partitionType == 0x0B || partitionType == 0x0C else {
            throw EditorError.notFAT32(String(format: "partition type 0x%02X is not FAT32",
                                              partitionType))
        }
        let partitionStart = Int(mbr.u32le(entry + 8))
        guard partitionStart >= 1 else {
            throw EditorError.notFAT32("partition starts at LBA 0")
        }

        let bpb = try read(partitionStart)
        guard bpb.u8(510) == 0x55, bpb.u8(511) == 0xAA else {
            throw EditorError.notFAT32("boot sector is missing its 55AA signature")
        }
        guard Int(bpb.u16le(0x0B)) == sectorSize else {
            throw EditorError.notFAT32("sector size is not 512")
        }
        let sectorsPerCluster = Int(bpb.u8(0x0D))
        guard sectorsPerCluster >= 1, sectorsPerCluster <= 128,
              sectorsPerCluster & (sectorsPerCluster - 1) == 0 else {
            throw EditorError.notFAT32("bad sectors-per-cluster \(sectorsPerCluster)")
        }
        let reserved = Int(bpb.u16le(0x0E))
        let fatCount = Int(bpb.u8(0x10))
        // FAT32's own fingerprints: a 16-bit-era root directory region or FAT
        // size means FAT12/16 — the structures this code would then walk
        // (rootCluster, 32-bit FAT entries) would not exist.
        guard bpb.u16le(0x11) == 0, bpb.u16le(0x16) == 0 else {
            throw EditorError.notFAT32("BPB has FAT12/16 root-directory or FAT-size fields set")
        }
        let totalSectors = Int(bpb.u32le(0x20))
        let fatSectors = Int(bpb.u32le(0x24))
        let rootCluster = Int(bpb.u32le(0x2C))
        let fsInfoSector = Int(bpb.u16le(0x30))
        guard reserved >= 1, fatCount >= 1, fatSectors >= 1, totalSectors > 0,
              fsInfoSector >= 1, fsInfoSector < reserved else {
            throw EditorError.notFAT32("implausible BPB layout fields")
        }

        let dataSectors = totalSectors - reserved - fatCount * fatSectors
        guard dataSectors >= sectorsPerCluster else {
            throw EditorError.notFAT32("no data region after the FAT structures")
        }
        let clusterCount = dataSectors / sectorsPerCluster
        guard rootCluster >= 2, rootCluster <= clusterCount + 1 else {
            throw EditorError.notFAT32("root cluster \(rootCluster) is outside the data region")
        }
        // Every FAT entry we might touch must live inside one FAT copy.
        guard (clusterCount + 2) * 4 <= fatSectors * sectorSize else {
            throw EditorError.notFAT32("FAT too small for its own cluster count")
        }
        return Geometry(partitionStart: partitionStart, sectorsPerCluster: sectorsPerCluster,
                        reservedSectors: reserved, fatCount: fatCount, fatSectors: fatSectors,
                        totalSectors: totalSectors, rootCluster: rootCluster,
                        fsInfoSector: fsInfoSector, clusterCount: clusterCount)
    }

    // MARK: - FAT access

    /// The 28-bit FAT entry for a cluster, read from FAT copy 1 through the
    /// composite view (so pending edits are visible to later ones).
    private func fatEntry(_ cluster: Int) throws -> UInt32 {
        let lba = geo.fatStart + cluster * 4 / Self.sectorSize
        return try readSector(lba).u32le(cluster * 4 % Self.sectorSize) & Self.fatMask
    }

    /// Writes FAT entries into EVERY FAT copy, preserving each entry's
    /// reserved top 4 bits and batching by sector so a chain of updates in one
    /// FAT sector costs one overlay record per copy, not one per entry.
    private func writeFATEntries(_ updates: [(cluster: Int, value: UInt32)]) throws {
        var bySector: [Int: [(cluster: Int, value: UInt32)]] = [:]
        for update in updates {
            bySector[update.cluster * 4 / Self.sectorSize, default: []].append(update)
        }
        for copy in 0..<geo.fatCount {
            for (fatSector, entries) in bySector.sorted(by: { $0.key < $1.key }) {
                let lba = geo.fatStart + copy * geo.fatSectors + fatSector
                var sector = [UInt8](try readSector(lba))
                for (cluster, value) in entries {
                    let offset = cluster * 4 % Self.sectorSize
                    let reserved = (UInt32(sector[offset + 3]) << 24) & ~Self.fatMask
                    put32(&sector, offset, Int(reserved | (value & Self.fatMask)))
                }
                try writeSector(lba, sector)
            }
        }
    }

    /// Walks a cluster chain from `first` to end-of-chain. An empty chain
    /// (first == 0) is a zero-length file. Bad-cluster markers, reserved
    /// values, out-of-range hops and cycles all mean corruption — better to
    /// refuse than to spray writes across a broken volume.
    private func clusterChain(from first: Int, what: String) throws -> [Int] {
        guard first != 0 else { return [] }
        var chain: [Int] = []
        var cluster = first
        while true {
            guard cluster >= 2, cluster <= geo.maxCluster else {
                throw EditorError.malformedVolume("\(what) chain points at cluster \(cluster)")
            }
            chain.append(cluster)
            guard chain.count <= geo.clusterCount else {
                throw EditorError.malformedVolume("\(what) cluster chain cycles")
            }
            let next = try fatEntry(cluster)
            if next >= 0x0FFF_FFF8 { break }
            cluster = Int(next)
        }
        return chain
    }

    /// First-fit scan for `count` free (masked-zero) FAT entries. The cursor
    /// persists across calls within this editor: clusters handed out earlier
    /// in the same session are behind it, so they can't be handed out twice
    /// even before their FAT links are written.
    private func allocateClusters(count: Int, for what: String) throws -> [Int] {
        var found: [Int] = []
        var cluster = freeScanCursor
        while found.count < count {
            guard cluster <= geo.maxCluster else { throw EditorError.volumeFull(what) }
            if try fatEntry(cluster) == 0 { found.append(cluster) }
            cluster += 1
        }
        freeScanCursor = cluster
        return found
    }

    // MARK: - Directory machinery

    /// A located 32-byte directory entry: the sector it lives in, its offset
    /// there, and a snapshot of its bytes.
    private struct EntryRef {
        let lba: Int
        let offset: Int
        let bytes: [UInt8]

        var attributes: UInt8 { bytes[11] }
        var isDirectory: Bool { attributes & 0x10 != 0 }
        var firstCluster: Int { Int(bytes[26]) | Int(bytes[27]) << 8
            | Int(bytes[20]) << 16 | Int(bytes[21]) << 24 }
        var fileSize: Int { Int(bytes[28]) | Int(bytes[29]) << 8
            | Int(bytes[30]) << 16 | Int(bytes[31]) << 24 }
    }

    /// Scans a directory chain for an 8.3 name. 0x00 first byte = end of
    /// directory (nothing after it, in this or later clusters); 0xE5 =
    /// deleted. The VolumeID attribute bit (0x08) is set on both volume
    /// labels and long-filename entries — whose 11 "name" bytes are checksum
    /// and UTF-16 fragments that can collide with a real 8.3 name — so both
    /// are skipped by attribute BEFORE any name comparison.
    private func find(name11: [UInt8], inChainFrom first: Int) throws -> EntryRef? {
        for cluster in try clusterChain(from: first, what: "directory") {
            for s in 0..<geo.sectorsPerCluster {
                let lba = geo.lba(ofCluster: cluster) + s
                let sector = try readSector(lba)
                for offset in stride(from: 0, to: Self.sectorSize, by: 32) {
                    let lead = sector.u8(offset)
                    if lead == 0x00 { return nil }
                    if lead == 0xE5 { continue }
                    let entry = [UInt8](sector[(sector.startIndex + offset)..<(sector.startIndex + offset + 32)])
                    if entry[11] & 0x08 != 0 { continue } // LFN or volume label
                    if Array(entry[0..<11]) == name11 {
                        return EntryRef(lba: lba, offset: offset, bytes: entry)
                    }
                }
            }
        }
        return nil
    }

    /// Splits a path into validated UPPERCASED 8.3 components. Everything the
    /// wizard touches is 8.3 by construction; case-folding here makes
    /// "windows/system.ini" and "WINDOWS/SYSTEM.INI" the same file, exactly
    /// as DOS would see them.
    private static func components(of path: String) throws -> [String] {
        let parts = path.split(whereSeparator: { $0 == "/" || $0 == "\\" })
            .map { $0.uppercased() }
        guard !parts.isEmpty else { throw EditorError.invalidName(path) }
        for part in parts where FAT16ImageBuilder.shortName(part) == nil {
            throw EditorError.invalidName(part)
        }
        return parts
    }

    /// Walks the directory components of `path` (all but the last) from the
    /// root, returning the first cluster of the directory that should hold
    /// the leaf, plus the leaf's on-disk name.
    private func locateParent(path: String) throws
        -> (parentCluster: Int, name11: [UInt8], leaf: String) {
        let parts = try Self.components(of: path)
        var cluster = geo.rootCluster
        for part in parts.dropLast() {
            guard let entry = try find(name11: FAT16ImageBuilder.shortName(part)!,
                                       inChainFrom: cluster) else {
                throw EditorError.fileNotFound(part)
            }
            guard entry.isDirectory else { throw EditorError.notADirectory(part) }
            cluster = entry.firstCluster
        }
        return (cluster, FAT16ImageBuilder.shortName(parts.last!)!, parts.last!)
    }

    /// Locates an existing FILE (directories are not content to read/replace).
    private func locateFile(path: String) throws -> EntryRef {
        let (parentCluster, name11, leaf) = try locateParent(path: path)
        guard let entry = try find(name11: name11, inChainFrom: parentCluster) else {
            throw EditorError.fileNotFound(path)
        }
        guard !entry.isDirectory else { throw EditorError.notADirectory(leaf) }
        return entry
    }

    private func readContent(chain: [Int], size: Int) throws -> Data {
        var content = Data(capacity: chain.count * geo.clusterBytes)
        for cluster in chain {
            for s in 0..<geo.sectorsPerCluster {
                content.append(try readSector(geo.lba(ofCluster: cluster) + s))
            }
        }
        return content.prefix(size)
    }

    /// Drops a 32-byte entry into the first free slot (deleted or end-of-
    /// directory) of a directory chain, extending the chain by one zeroed
    /// cluster when every slot is taken. Zeroing the new cluster is what
    /// keeps its remaining slots reading as end-of-directory.
    private func appendDirectoryEntry(_ entry: [UInt8], toDirectoryAt firstCluster: Int,
                                      path: String) throws {
        let chain = try clusterChain(from: firstCluster, what: path)
        for cluster in chain {
            for s in 0..<geo.sectorsPerCluster {
                let lba = geo.lba(ofCluster: cluster) + s
                var sector = [UInt8](try readSector(lba))
                for offset in stride(from: 0, to: Self.sectorSize, by: 32)
                    where sector[offset] == 0x00 || sector[offset] == 0xE5 {
                    sector.replaceSubrange(offset..<(offset + 32), with: entry)
                    try writeSector(lba, sector)
                    return
                }
            }
        }

        let grown = try allocateClusters(count: 1, for: path)[0]
        try writeFATEntries([(chain.last!, UInt32(grown)), (grown, Self.endOfChain)])
        for s in 0..<geo.sectorsPerCluster {
            var sector = [UInt8](repeating: 0, count: Self.sectorSize)
            if s == 0 { sector.replaceSubrange(0..<32, with: entry) }
            try writeSector(geo.lba(ofCluster: grown) + s, sector)
        }
    }

    private static func directoryEntry(name11: [UInt8], attributes: UInt8,
                                       firstCluster: Int, fileSize: Int) -> [UInt8] {
        var entry = [UInt8](repeating: 0, count: 32)
        entry.replaceSubrange(0..<11, with: name11)
        entry[11] = attributes
        put16(&entry, 14, fixedTime) // created
        put16(&entry, 16, fixedDate)
        put16(&entry, 18, fixedDate) // last access
        put16(&entry, 20, firstCluster >> 16) // first-cluster HIGH word: live on FAT32
        put16(&entry, 22, fixedTime) // last write
        put16(&entry, 24, fixedDate)
        put16(&entry, 26, firstCluster & 0xFFFF)
        put32(&entry, 28, fileSize)
        return entry
    }

    // MARK: - FSInfo

    /// After allocating, FSInfo's free-cluster count and next-free hint are
    /// both set to 0xFFFFFFFF — the spec's explicit "unknown", which every
    /// FAT32 driver must recompute from the FAT itself. The alternative
    /// (decrementing the count in place) would launder a possibly-stale
    /// number as freshly-maintained truth; "unknown" is always correct.
    /// Skipped when both fields already read unknown.
    private func invalidateFSInfo() throws {
        let lba = geo.partitionStart + geo.fsInfoSector
        var sector = [UInt8](try readSector(lba))
        let asData = Data(sector)
        guard asData.u32le(0) == 0x4161_5252, asData.u32le(0x1E4) == 0x6141_7272 else {
            throw EditorError.malformedVolume("FSInfo sector is missing its signatures")
        }
        if asData.u32le(0x1E8) == 0xFFFF_FFFF, asData.u32le(0x1EC) == 0xFFFF_FFFF { return }
        put32(&sector, 0x1E8, Int(UInt32.max)) // free count: unknown
        put32(&sector, 0x1EC, Int(UInt32.max)) // next free: unknown
        try writeSector(lba, sector)
    }
}

// MARK: - Little-endian field access

private extension Data {
    /// Relative to `startIndex`, so slices can't silently shift every read.
    func u8(_ offset: Int) -> UInt8 { self[startIndex + offset] }
    func u16le(_ offset: Int) -> UInt16 { UInt16(u8(offset)) | UInt16(u8(offset + 1)) << 8 }
    func u32le(_ offset: Int) -> UInt32 { UInt32(u16le(offset)) | UInt32(u16le(offset + 2)) << 16 }
}

private func put16(_ buffer: inout [UInt8], _ offset: Int, _ value: Int) {
    buffer[offset] = UInt8(value & 0xFF)
    buffer[offset + 1] = UInt8((value >> 8) & 0xFF)
}

private func put32(_ buffer: inout [UInt8], _ offset: Int, _ value: Int) {
    buffer[offset] = UInt8(value & 0xFF)
    buffer[offset + 1] = UInt8((value >> 8) & 0xFF)
    buffer[offset + 2] = UInt8((value >> 16) & 0xFF)
    buffer[offset + 3] = UInt8((value >> 24) & 0xFF)
}
