import Foundation

/// Builds the D: install-source disk image the Win98 wizard hands to Setup —
/// an MBR-partitioned FAT16 volume holding the user's \WIN98 CAB tree plus the
/// generated MSBATCH.INF unattended-answer file.
///
/// Why hand-rolled: iOS has no API for fabricating DOS disk images, and the
/// layout is not negotiable — it replicates the mtools-built image from
/// tools/make-win98-install-media.sh that real MS-DOS 7.1 IO.SYS proved
/// bootable against in Chrome (LEG 1-8). The load-bearing details, each of
/// which cost a debug cycle to learn:
///  - MBR partition at LBA 63, type 0x06 (FAT16 >32MB). IO.SYS assigns drive
///    letters by reading fixed-disk MBRs itself; a partitionless "superfloppy"
///    volume gets no letter at all.
///  - BPB hidden-sectors = 63. IO.SYS locates every filesystem structure via
///    hidden-sectors + relative offsets; a 0 there shifts the whole FS by 63
///    sectors and faults the guest.
///  - Geometry 489/16/63 → 246456 KiB total, matching sockdrive's fat16-256m
///    template exactly, or the chunker (Rust and ours) refuses the image by size.
///
/// Write pattern: the image file is created sparse (truncated to full size, no
/// zero-fill I/O), file data streams in as it is added, and the FAT copies plus
/// directories are flushed once in `close()`. Nothing holds more than ~250 KB
/// of metadata plus one ≤4 MiB data chunk in memory, so a ~240 MB image builds
/// comfortably on-device.
///
/// Names are 8.3 UPPERCASE only, by design: everything the wizard copies comes
/// from ISO9660 primary volume descriptors, which are 8.3 by construction, so
/// long-filename support would be dead code here. Anything else throws.
///
/// A class, not a struct: the builder owns a FileHandle and mutates allocation
/// state on every add; value semantics would be a lie.
final class FAT16ImageBuilder {

    // MARK: - Geometry

    /// CHS disk geometry. Everything else about the image — total size, MBR
    /// partition bounds, BPB fields, FAT sizing — is derived from these three
    /// numbers, so one Geometry value fully determines the layout.
    struct Geometry: Equatable {
        let cylinders: Int
        let heads: Int
        let sectorsPerTrack: Int

        /// The production geometry: 489/16/63 = 246456 KiB, the exact size of
        /// sockdrive's fat16-256m drive template. Do not "round up" — the
        /// chunker matches templates by byte size.
        static let win98InstallSource = Geometry(cylinders: 489, heads: 16, sectorsPerTrack: 63)

        var totalSectors: Int { cylinders * heads * sectorsPerTrack }
        var totalBytes: Int { totalSectors * FAT16ImageBuilder.sectorSize }
        /// The partition starts one track in — LBA 63 for real geometries —
        /// exactly like mpartition lays it out. The gap holds only the MBR.
        var partitionFirstLBA: Int { sectorsPerTrack }
        var partitionSectors: Int { totalSectors - partitionFirstLBA }
    }

    // MARK: - Errors

    enum BuilderError: Error, LocalizedError, Equatable {
        case invalidName(String)
        case duplicateEntry(String)
        case missingParentDirectory(String)
        case rootDirectoryFull
        case volumeFull(String)
        case unsupportedVolume(String)
        case shortRead(path: String, expected: Int, got: Int)
        case alreadyClosed
        case ioFailure(String)

        var errorDescription: String? {
            switch self {
            case .invalidName(let name):
                return "\"\(name)\" is not an 8.3 UPPERCASE DOS name."
            case .duplicateEntry(let path): return "\(path) already exists in the image."
            case .missingParentDirectory(let path):
                return "The parent directory of \(path) does not exist in the image."
            case .rootDirectoryFull: return "The image's root directory is full (512 entries)."
            case .volumeFull(let what): return "The image is out of space while adding \(what)."
            case .unsupportedVolume(let why): return "Unsupported volume geometry: \(why)."
            case .shortRead(let path, let expected, let got):
                return "Reading \(path): expected \(expected) bytes, got \(got)."
            case .alreadyClosed: return "The image builder has already been closed."
            case .ioFailure(let why): return "Couldn't write the disk image: \(why)"
            }
        }
    }

    // MARK: - Layout constants

    static let sectorSize = 512
    private static let dirEntrySize = 32
    private static let rootEntryCount = 512 // matches mformat; 32 sectors of root directory
    private static let reservedSectors = 1  // boot sector only, mformat's FAT16 default
    private static let fatCount = 2
    /// End-of-chain marker. mtools and DOS FORMAT both write 0xFFFF (not the
    /// minimal 0xFFF8), so match them.
    private static let endOfChain: UInt16 = 0xFFFF
    /// Streaming granularity for `addFile(path:size:reader:)`: large CABs move
    /// ISO→image through a bounded buffer instead of materializing whole.
    private static let streamChunkBytes = 4 << 20

    /// All directory entries carry one fixed timestamp: builds must be
    /// deterministic (byte-identical images chunk to byte-identical sockdrives,
    /// which is what the tests and oracles compare). 2026-07-05 12:00:00 — the
    /// same date the MSBATCH.INF template carries in SaveDate.
    private static let fixedDate = ((2026 - 1980) << 9) | (7 << 5) | 5 // 0x5CE5
    private static let fixedTime = 12 << 11                            // 0x6000

    // MARK: - Derived FAT layout (fixed at init)

    let geometry: Geometry
    /// Data-region cluster size in sectors: the smallest power of two that
    /// keeps the cluster count within FAT16's 4085...65524 window (8 for the
    /// production geometry, i.e. 4 KiB clusters — same as mformat chose).
    let sectorsPerCluster: Int
    /// Sectors per FAT copy (241 for the production geometry — verified against
    /// the mformat-built image this builder replicates).
    let fatSectors: Int
    /// Number of data clusters. Valid cluster numbers are 2...clusterCount+1.
    let clusterCount: Int

    private var clusterBytes: Int { sectorsPerCluster * Self.sectorSize }
    private var entriesPerCluster: Int { clusterBytes / Self.dirEntrySize }
    /// Partition-relative sector where the data region (cluster 2) begins.
    private var firstDataSector: Int {
        Self.reservedSectors + Self.fatCount * fatSectors
            + Self.rootEntryCount * Self.dirEntrySize / Self.sectorSize
    }

    // MARK: - Mutable build state

    private let handle: FileHandle
    /// The FAT, kept in memory until `close()` — ~123 KB for the production
    /// image. Index = cluster number; [0] and [1] are the media/EOC markers.
    private var fat: [UInt16]
    /// Bump allocator: clusters are handed out strictly sequentially and never
    /// freed (nothing is ever deleted from an install image), which guarantees
    /// each FILE occupies one contiguous run — so its data can stream in with
    /// plain sequential writes. Directory chains may fragment (they grow after
    /// later allocations); FAT chains handle that fine.
    private var nextFreeCluster = 2
    /// Directories by normalized path ("" = root, "WIN98", "WIN98/OLS", ...).
    private var directories: [String: Directory]
    private var closed = false

    /// One directory being assembled: its serialized 32-byte entries (including
    /// "." and ".." for subdirectories) and its cluster chain. The root is the
    /// fixed 512-entry region, not a chain — firstCluster 0, no clusters.
    private final class Directory {
        let firstCluster: Int
        var clusters: [Int]
        var entries: [[UInt8]] = []
        var childNames: Set<String> = []

        init(firstCluster: Int, clusters: [Int]) {
            self.firstCluster = firstCluster
            self.clusters = clusters
        }
    }

    // MARK: - Init: create the image shell

    /// Creates (or replaces) the image file at `url`, sized and partitioned per
    /// `geometry`, with the MBR and FAT16 boot sector already written. The
    /// volume is not valid until `close()` flushes the FATs and directories.
    ///
    /// `volumeLabel`, when given, lands in both the BPB and a root entry the
    /// way mformat -v would; the proven image has none, so the default is none.
    init(creatingImageAt url: URL, geometry: Geometry = .win98InstallSource,
         volumeLabel: String? = nil) throws {
        self.geometry = geometry

        // Cluster sizing per the FAT spec: pick the smallest power-of-two
        // sectors-per-cluster whose cluster count fits FAT16, then fix-point
        // the FAT size (FAT sectors eat into the data region, which shrinks
        // the cluster count, which can shrink the FAT...). mformat converges
        // the same way — the production geometry lands on 8 sectors/cluster,
        // 241-sector FATs, 61541 clusters, matching the proven image exactly.
        let rootSectors = Self.rootEntryCount * Self.dirEntrySize / Self.sectorSize
        let nonData = Self.reservedSectors + rootSectors
        var spc = 1
        while spc <= 128, (geometry.partitionSectors - nonData) / spc > 65524 {
            spc *= 2
        }
        var fatLen = 0
        while true {
            let clusters = (geometry.partitionSectors - nonData - Self.fatCount * fatLen) / spc
            let needed = ((clusters + 2) * 2 + Self.sectorSize - 1) / Self.sectorSize
            if needed == fatLen { break }
            fatLen = needed
        }
        self.sectorsPerCluster = spc
        self.fatSectors = fatLen
        self.clusterCount = (geometry.partitionSectors - nonData - Self.fatCount * fatLen) / spc
        guard clusterCount >= 4085, clusterCount <= 65524 else {
            // Below 4085 clusters DOS would treat the volume as FAT12, above
            // 65524 as FAT32 — either way not the filesystem we are writing.
            throw BuilderError.unsupportedVolume(
                "\(clusterCount) clusters is outside FAT16's 4085...65524 range")
        }

        var label = [UInt8](repeating: 0x20, count: 11) // "NO NAME    " when absent
        for (i, byte) in "NO NAME".utf8.enumerated() { label[i] = byte }
        if let volumeLabel {
            guard let bytes = Self.labelBytes(volumeLabel) else {
                throw BuilderError.invalidName(volumeLabel)
            }
            label = bytes
        }

        // Create sparse: APFS materializes no blocks for the truncated tail,
        // so a 240 MB image costs only what actually gets written to it.
        FileManager.default.createFile(atPath: url.path, contents: nil)
        do {
            self.handle = try FileHandle(forWritingTo: url)
            try handle.truncate(atOffset: UInt64(geometry.totalBytes))
        } catch {
            throw BuilderError.ioFailure(error.localizedDescription)
        }

        self.fat = [UInt16](repeating: 0, count: clusterCount + 2)
        fat[0] = 0xFF00 | 0x00F8 // media descriptor F8, upper bits set
        fat[1] = Self.endOfChain
        self.directories = ["": Directory(firstCluster: 0, clusters: [])]

        try write(Data(mbrSector()), atByteOffset: 0)
        try write(Data(bootSector(label: label)),
                  atByteOffset: UInt64(geometry.partitionFirstLBA * Self.sectorSize))
        if volumeLabel != nil {
            // The label's root entry: attribute 0x08, no cluster, no size.
            directories[""]!.entries.append(
                Self.directoryEntry(name11: label, attributes: 0x08, firstCluster: 0, fileSize: 0))
        }
    }

    deinit {
        if !closed { try? handle.close() }
    }

    // MARK: - Public API

    /// Creates a subdirectory (parents must already exist — this is a builder,
    /// not mkdir -p; the wizard's copy loop always creates parents first).
    func addDirectory(path: String) throws {
        guard !closed else { throw BuilderError.alreadyClosed }
        let (parent, name, key) = try locate(path)

        // A directory starts life with one cluster holding "." and "..";
        // more clusters chain on automatically if its entry count outgrows it.
        let cluster = try allocateClusters(count: 1, for: path)
        let dir = Directory(firstCluster: cluster, clusters: [cluster])
        dir.entries.append(Self.directoryEntry(
            name11: Self.dotName(1), attributes: 0x10, firstCluster: cluster, fileSize: 0))
        dir.entries.append(Self.directoryEntry(
            name11: Self.dotName(2), attributes: 0x10,
            firstCluster: parent.firstCluster, fileSize: 0)) // 0 = root, per FAT spec
        directories[key] = dir

        try appendEntry(Self.directoryEntry(name11: Self.shortName(name)!,
                                            attributes: 0x10, firstCluster: cluster, fileSize: 0),
                        to: parent, childName: name, path: path)
    }

    /// Adds a file whose content is already in memory (MSBATCH.INF-sized
    /// things). Large files should use the streaming variant instead.
    func addFile(path: String, data: Data) throws {
        try addFile(path: path, size: data.count) { offset, count in
            data.subdata(in: (data.startIndex + offset)..<(data.startIndex + offset + count))
        }
    }

    /// Adds a file by pulling its content through `reader(offset, count)` in
    /// chunks of at most 4 MiB — how CAB files stream from the user's ISO into
    /// the image without ever being fully buffered. The reader must return
    /// exactly `count` bytes; anything short is treated as a truncated source.
    func addFile(path: String, size: Int,
                 reader: (_ offset: Int, _ count: Int) throws -> Data) throws {
        guard !closed else { throw BuilderError.alreadyClosed }
        guard size >= 0 else { throw BuilderError.shortRead(path: path, expected: 0, got: size) }
        let (parent, name, _) = try locate(path)

        // Zero-byte files own no clusters at all (first cluster 0), exactly
        // like DOS writes them.
        var firstCluster = 0
        if size > 0 {
            let clusters = (size + clusterBytes - 1) / clusterBytes
            firstCluster = try allocateClusters(count: clusters, for: path)

            // The bump allocator makes the run contiguous, so the file's bytes
            // land with sequential writes from the run's start; the last
            // cluster's tail stays zero courtesy of the sparse file.
            let base = byteOffset(ofCluster: firstCluster)
            var offset = 0
            while offset < size {
                let count = min(Self.streamChunkBytes, size - offset)
                let chunk = try reader(offset, count)
                guard chunk.count == count else {
                    throw BuilderError.shortRead(path: path, expected: count, got: chunk.count)
                }
                try write(chunk, atByteOffset: base + UInt64(offset))
                offset += count
            }
        }

        try appendEntry(Self.directoryEntry(name11: Self.shortName(name)!,
                                            attributes: 0x20, // archive, like fresh DOS copies
                                            firstCluster: firstCluster, fileSize: size),
                        to: parent, childName: name, path: path)
    }

    /// Flushes both FAT copies, the root directory, and every subdirectory
    /// cluster, then closes the file. The image is not a valid filesystem
    /// until this returns. Single-shot: the builder is unusable afterwards.
    func close() throws {
        guard !closed else { throw BuilderError.alreadyClosed }

        // FATs: serialize the in-memory table little-endian; both copies are
        // identical. The buffer is fatSectors*512 with a zero tail (the table
        // is sized to the cluster count, the FAT region to whole sectors).
        var fatBytes = [UInt8](repeating: 0, count: fatSectors * Self.sectorSize)
        for (i, value) in fat.enumerated() {
            fatBytes[2 * i] = UInt8(value & 0xFF)
            fatBytes[2 * i + 1] = UInt8(value >> 8)
        }
        let fatData = Data(fatBytes)
        for copy in 0..<Self.fatCount {
            let sector = geometry.partitionFirstLBA + Self.reservedSectors + copy * fatSectors
            try write(fatData, atByteOffset: UInt64(sector * Self.sectorSize))
        }

        // Root directory: a fixed 512-entry region right after the FATs.
        let root = directories[""]!
        var rootBytes = [UInt8](repeating: 0, count: Self.rootEntryCount * Self.dirEntrySize)
        for (i, entry) in root.entries.enumerated() {
            rootBytes.replaceSubrange(i * Self.dirEntrySize..<(i + 1) * Self.dirEntrySize,
                                      with: entry)
        }
        let rootSector = geometry.partitionFirstLBA + Self.reservedSectors
            + Self.fatCount * fatSectors
        try write(Data(rootBytes), atByteOffset: UInt64(rootSector * Self.sectorSize))

        // Subdirectories: lay each directory's entries across its cluster
        // chain, zero-padding the final cluster.
        for (path, dir) in directories where path != "" {
            for (index, cluster) in dir.clusters.enumerated() {
                var clusterContent = [UInt8](repeating: 0, count: clusterBytes)
                let start = index * entriesPerCluster
                let end = min(dir.entries.count, start + entriesPerCluster)
                if start < end {
                    for i in start..<end {
                        clusterContent.replaceSubrange(
                            (i - start) * Self.dirEntrySize..<(i - start + 1) * Self.dirEntrySize,
                            with: dir.entries[i])
                    }
                }
                try write(Data(clusterContent), atByteOffset: byteOffset(ofCluster: cluster))
            }
        }

        do {
            try handle.close()
        } catch {
            throw BuilderError.ioFailure(error.localizedDescription)
        }
        closed = true
    }

    // MARK: - Path / allocation internals

    /// Splits "WIN98/OLS/FOO.CAB" (either slash direction) into its parent
    /// Directory, validated leaf name, and normalized map key — the shared
    /// front half of every add.
    private func locate(_ path: String) throws -> (parent: Directory, name: String, key: String) {
        let components = path.split(whereSeparator: { $0 == "/" || $0 == "\\" }).map(String.init)
        guard let name = components.last, Self.shortName(name) != nil else {
            throw BuilderError.invalidName(path)
        }
        let parentKey = components.dropLast().joined(separator: "/")
        let key = components.joined(separator: "/")
        guard let parent = directories[parentKey] else {
            throw BuilderError.missingParentDirectory(path)
        }
        guard !parent.childNames.contains(name), directories[key] == nil else {
            throw BuilderError.duplicateEntry(path)
        }
        return (parent, name, key)
    }

    /// Hands out `count` sequential clusters chained in the FAT, returning the
    /// first. Sequential allocation is what keeps file data contiguous.
    private func allocateClusters(count: Int, for what: String) throws -> Int {
        let first = nextFreeCluster
        guard first + count - 1 <= clusterCount + 1 else {
            throw BuilderError.volumeFull(what)
        }
        for cluster in first..<(first + count) {
            fat[cluster] = cluster == first + count - 1 ? Self.endOfChain : UInt16(cluster + 1)
        }
        nextFreeCluster = first + count
        return first
    }

    /// Appends a 32-byte entry to a directory, growing subdirectory chains by
    /// one cluster when they fill. The root cannot grow — its 512 entries are
    /// a hard FAT16 limit.
    private func appendEntry(_ entry: [UInt8], to dir: Directory,
                             childName: String, path: String) throws {
        if dir.firstCluster == 0 {
            guard dir.entries.count < Self.rootEntryCount else {
                throw BuilderError.rootDirectoryFull
            }
        } else if dir.entries.count == dir.clusters.count * entriesPerCluster {
            let grown = try allocateClusters(count: 1, for: path)
            fat[dir.clusters.last!] = UInt16(grown) // re-link the old tail
            dir.clusters.append(grown)
        }
        dir.entries.append(entry)
        dir.childNames.insert(childName)
    }

    private func byteOffset(ofCluster cluster: Int) -> UInt64 {
        UInt64(geometry.partitionFirstLBA + firstDataSector
            + (cluster - 2) * sectorsPerCluster) * UInt64(Self.sectorSize)
    }

    private func write(_ data: Data, atByteOffset offset: UInt64) throws {
        do {
            try handle.seek(toOffset: offset)
            try handle.write(contentsOf: data)
        } catch {
            throw BuilderError.ioFailure(error.localizedDescription)
        }
    }

    // MARK: - On-disk structures

    /// The MBR: one partition entry replicating mpartition's output on the
    /// proven image byte-for-byte (offset 0x1BE: 80 01 01 00 06 0F 7F E8,
    /// then LBA start 63 and the sector count). CHS fields are best-effort —
    /// filled correctly for these geometries, clamped like every tool does
    /// when a value overflows — but IO.SYS and DOSBox read the LBA fields.
    private func mbrSector() -> [UInt8] {
        var mbr = [UInt8](repeating: 0, count: Self.sectorSize)
        let entry = 0x1BE
        mbr[entry] = 0x80 // "active", matching mpartition (harmless on a data disk)
        putCHS(&mbr, at: entry + 1, lba: geometry.partitionFirstLBA)
        mbr[entry + 4] = 0x06 // FAT16 >32MB, CHS-addressed — what IO.SYS expects here
        putCHS(&mbr, at: entry + 5, lba: geometry.totalSectors - 1)
        put32(&mbr, entry + 8, geometry.partitionFirstLBA)
        put32(&mbr, entry + 12, geometry.partitionSectors)
        mbr[0x1FE] = 0x55
        mbr[0x1FF] = 0xAA
        return mbr
    }

    /// The FAT16 boot sector (BPB), field-for-field what mformat -H 63 wrote
    /// on the proven image — minus the boot code, which stays zero: this
    /// volume is D:, data-only, and its VBR is never executed.
    private func bootSector(label: [UInt8]) -> [UInt8] {
        var boot = [UInt8](repeating: 0, count: Self.sectorSize)
        boot.replaceSubrange(0..<3, with: [0xEB, 0x3C, 0x90]) // conventional jump
        boot.replaceSubrange(3..<11, with: Array("MSWIN4.1".utf8)) // safest-known OEM label
        put16(&boot, 0x0B, Self.sectorSize)
        boot[0x0D] = UInt8(sectorsPerCluster)
        put16(&boot, 0x0E, Self.reservedSectors)
        boot[0x10] = UInt8(Self.fatCount)
        put16(&boot, 0x11, Self.rootEntryCount)
        put16(&boot, 0x13, 0) // >65535 total sectors live in the 32-bit field
        boot[0x15] = 0xF8     // media descriptor: fixed disk
        put16(&boot, 0x16, fatSectors)
        put16(&boot, 0x18, geometry.sectorsPerTrack)
        put16(&boot, 0x1A, geometry.heads)
        put32(&boot, 0x1C, geometry.partitionFirstLBA) // hidden sectors — THE field
        put32(&boot, 0x20, geometry.partitionSectors)
        boot[0x24] = 0x80 // BIOS drive number: first fixed disk
        boot[0x26] = 0x29 // extended boot signature: serial+label+type follow
        put32(&boot, 0x27, 0x504B_4453) // fixed serial ("PKDS"): deterministic builds
        boot.replaceSubrange(0x2B..<0x36, with: label)
        boot.replaceSubrange(0x36..<0x3E, with: Array("FAT16   ".utf8))
        boot[0x1FE] = 0x55
        boot[0x1FF] = 0xAA
        return boot
    }

    private static func directoryEntry(name11: [UInt8], attributes: UInt8,
                                       firstCluster: Int, fileSize: Int) -> [UInt8] {
        var entry = [UInt8](repeating: 0, count: dirEntrySize)
        entry.replaceSubrange(0..<11, with: name11)
        entry[11] = attributes
        put16(&entry, 14, fixedTime) // created
        put16(&entry, 16, fixedDate)
        put16(&entry, 18, fixedDate) // last access
        put16(&entry, 20, 0)         // first-cluster high word: always 0 on FAT16
        put16(&entry, 22, fixedTime) // last write
        put16(&entry, 24, fixedDate)
        put16(&entry, 26, firstCluster)
        put32(&entry, 28, fileSize)
        return entry
    }

    // MARK: - 8.3 names

    /// The characters DOS allows in short names. Deliberately no space (legal
    /// but a landmine) and no lowercase — see the type comment.
    private static let shortNameChars: Set<UInt8> = {
        var chars = Set("!#$%&'()-@^_`{}~".utf8)
        chars.formUnion(UInt8(ascii: "A")...UInt8(ascii: "Z"))
        chars.formUnion(UInt8(ascii: "0")...UInt8(ascii: "9"))
        return chars
    }()

    /// Validates NAME[.EXT] (1-8 name, 0-3 ext, uppercase charset above) and
    /// returns the space-padded 11-byte on-disk form, or nil if invalid.
    static func shortName(_ name: String) -> [UInt8]? {
        let parts = name.split(separator: ".", omittingEmptySubsequences: false)
        guard parts.count <= 2, let base = parts.first,
              (1...8).contains(base.count),
              parts.count == 1 || (1...3).contains(parts[1].count) else { return nil }
        var name11 = [UInt8](repeating: 0x20, count: 11)
        for (i, char) in base.utf8.enumerated() {
            guard shortNameChars.contains(char) else { return nil }
            name11[i] = char
        }
        if parts.count == 2 {
            for (i, char) in parts[1].utf8.enumerated() {
                guard shortNameChars.contains(char) else { return nil }
                name11[8 + i] = char
            }
        }
        return name11
    }

    /// "." and ".." padded to 11 bytes, for a subdirectory's first two entries.
    private static func dotName(_ dots: Int) -> [UInt8] {
        var name11 = [UInt8](repeating: 0x20, count: 11)
        for i in 0..<dots { name11[i] = UInt8(ascii: ".") }
        return name11
    }

    /// Volume labels share the short-name charset but are a single 11-byte
    /// field with no dot structure.
    private static func labelBytes(_ label: String) -> [UInt8]? {
        guard (1...11).contains(label.count) else { return nil }
        var bytes = [UInt8](repeating: 0x20, count: 11)
        for (i, char) in label.utf8.enumerated() {
            guard shortNameChars.contains(char) else { return nil }
            bytes[i] = char
        }
        return bytes
    }
}

// MARK: - Little-endian byte poking

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

// MARK: - Win98 install-source assembly

extension FAT16ImageBuilder {

    /// The complete D: install-source image in one call: the ISO's \WIN98 tree
    /// (SETUP.EXE + CABs, subdirectories included) under \WIN98, plus the
    /// generated MSBATCH.INF at the root — where the boot floppy's AUTOEXEC
    /// points Setup at it (`D:\WIN98\SETUP.EXE D:\MSBATCH.INF /IS`).
    ///
    /// `productKey` is the user's own credential. It is burned into
    /// MSBATCH.INF inside the image and goes NOWHERE else — never logged,
    /// never interpolated into an error message.
    static func buildInstallSource(from iso: ISO9660Image, productKey: String,
                                   at url: URL) throws {
        let builder = try FAT16ImageBuilder(creatingImageAt: url)
        try builder.copyTree(from: iso, isoPath: "WIN98", imagePath: "WIN98")
        try builder.addFile(path: "MSBATCH.INF", data: msbatchINF(productKey: productKey))
        try builder.close()
    }

    /// Recursively copies an ISO directory into the image, preserving on-disc
    /// order and streaming file bytes in the builder's ≤4 MiB chunks so a
    /// 600 MB ISO's CABs never sit in memory whole.
    private func copyTree(from iso: ISO9660Image, isoPath: String, imagePath: String) throws {
        try addDirectory(path: imagePath)
        for entry in try iso.list(directory: isoPath) {
            // PVD identifiers are uppercase 8.3 by construction, but a few
            // mastering tools bent the spec with lowercase — uppercase here
            // (where CD names enter the image) rather than teach the strict
            // builder to accept them.
            let childISO = isoPath + "/" + entry.name
            let childImage = imagePath + "/" + entry.name.uppercased()
            if entry.isDirectory {
                try copyTree(from: iso, isoPath: childISO, imagePath: childImage)
            } else {
                try addFile(path: childImage, size: entry.size) { offset, count in
                    try iso.readFile(atPath: childISO, offset: offset, count: count)
                }
            }
        }
    }

    /// MSBATCH.INF — the answer file that runs Setup's entire interactive
    /// phase hands-free. Ported EXACTLY from the Chrome-proven generator
    /// (wizard-s0/build-unattend-floppy.js); any drift here re-opens prompts
    /// that took LEG 7 to close. Express=1 is the linchpin (Setup stops for
    /// nothing), ShowEula=0 skips the license page, ProductKey pre-fills the
    /// five key boxes, [NameAndOrg] Display=0 skips User Info, EBD=0 skips
    /// the startup-floppy offer, and the [OptionalComponents] block trims
    /// networking to the bone — fewer components, fewer files copied.
    ///
    /// CRLF line endings and Latin-1 bytes: DOS INF parsers need both.
    static func msbatchINF(productKey: String) -> Data {
        let lines = [
            "[BatchSetup]",
            "Version=3.0 (32-bit)",
            "SaveDate=07/05/2026",
            "",
            "[Version]",
            "Signature = \"$CHICAGO$\"",
            "",
            "[Setup]",
            "Express=1",
            "InstallDir=\"C:\\WINDOWS\"",
            "InstallType=1",
            "ProductKey=\"" + productKey + "\"",
            "EBD=0",
            "ShowEula=0",
            "ChangeDir=0",
            "OptionalComponents=1",
            "Network=0",
            "System=0",
            "CCP=0",
            "CleanBoot=0",
            "Display=0",
            "PenWinWarning=0",
            "InstallDirCheck=0",
            "NoDirWarn=1",
            "TimeZone=\"Pacific\"",
            "Uninstall=0",
            "VRC=0",
            "NoPrompt2Boot=1",
            "",
            "[NameAndOrg]",
            "Name=\"PocketDOS\"",
            "Org=\"PocketDOS\"",
            "Display=0",
            "",
            "[InstallLocationsMRU]",
            "",
            "[OptionalComponents]",
            "\"Dial-Up Networking\"=0",
            "\"Dial-Up Server\"=0",
            "\"Direct Cable Connection\"=0",
            "\"Phone Dialer\"=0",
            "\"Microsoft NetMeeting\"=0",
            "\"Web-Based Enterprise Mgmt\"=0",
            "\"Web TV for Windows\"=0",
            "\"Online Services\"=0",
            "\"Microsoft Wallet\"=0",
            "",
            "[Network]",
            "ComputerName=POCKETDOS",
            "Workgroup=WORKGROUP",
            "Display=0",
            "",
        ]
        let text = lines.joined(separator: "\r\n") + "\r\n"
        // Keys and every literal above are ASCII, so Latin-1 encoding cannot
        // actually fail; the lossy flag keeps this total instead of trusting
        // that with a force-unwrap.
        return text.data(using: .isoLatin1, allowLossyConversion: true) ?? Data(text.utf8)
    }
}

extension FAT16ImageBuilder {
    /// Encodes an LBA as the 3-byte CHS field of an MBR partition entry
    /// (head, sector-with-cylinder-high-bits, cylinder-low) under this image's
    /// geometry, clamping to the conventional FE FF FF when the cylinder
    /// overflows its 10-bit field.
    fileprivate func putCHS(_ buffer: inout [UInt8], at offset: Int, lba: Int) {
        let spt = geometry.sectorsPerTrack
        let cylinder = lba / (geometry.heads * spt)
        if cylinder > 1023 {
            buffer[offset] = 0xFE
            buffer[offset + 1] = 0xFF
            buffer[offset + 2] = 0xFF
            return
        }
        buffer[offset] = UInt8((lba / spt) % geometry.heads)
        buffer[offset + 1] = UInt8((lba % spt) + 1) | UInt8((cylinder >> 8) << 6)
        buffer[offset + 2] = UInt8(cylinder & 0xFF)
    }
}
