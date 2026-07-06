import XCTest
@testable import PocketDOS

/// Exercises the FAT16 install-source builder against SYNTHETIC content only —
/// the real ISO's CABs never enter the repo. Structure checks parse the
/// builder's own output back at byte level (MBR, BPB, FAT chains, directory
/// entries) rather than trusting the builder about itself; the mtools oracle
/// run against the real ISO lives outside the test suite.
///
/// Most tests use a deliberately small geometry (17/16/63 ≈ 8.4 MB, 512-byte
/// clusters) that still lands in FAT16's valid cluster range, so a full image
/// round-trips through Data comfortably. One test builds the full-size
/// production layout — sparse, so it stays cheap — and pins every field that
/// the PROVEN mtools-built image had, byte for byte where it matters.
final class FAT16ImageBuilderTests: XCTestCase {

    /// Small-but-valid FAT16 geometry: 17136 sectors total, 16906 clusters
    /// (>4085, so genuinely FAT16), one sector per cluster.
    private static let smallGeometry = FAT16ImageBuilder.Geometry(
        cylinders: 17, heads: 16, sectorsPerTrack: 63)

    private func makeTempDir() throws -> URL {
        let url = FileManager.default.temporaryDirectory
            .appendingPathComponent("fat16-builder-tests-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
        addTeardownBlock { try? FileManager.default.removeItem(at: url) }
        return url
    }

    /// Deterministic non-trivial bytes so content mix-ups can't cancel out.
    private func pattern(_ count: Int, seed: Int = 1) -> Data {
        var bytes = [UInt8](repeating: 0, count: count)
        for i in 0..<count {
            bytes[i] = UInt8(truncatingIfNeeded: i &* 131 &+ seed &+ (i >> 9))
        }
        return Data(bytes)
    }

    // MARK: - Read-back parser (the test's independent view of the image)

    /// A minimal FAT16 reader: parses the MBR + BPB and walks FAT chains and
    /// directories from the raw bytes. Kept intentionally separate from the
    /// builder's own bookkeeping so a shared bug can't vouch for itself.
    private struct ParsedImage {
        let bytes: [UInt8]
        let partitionStart: Int  // byte offset (hidden sectors * 512)
        let sectorsPerCluster: Int
        let reservedSectors: Int
        let fatCount: Int
        let rootEntries: Int
        let fatSectors: Int
        let hiddenSectors: Int
        let totalSectors32: Int

        init(_ data: Data) {
            bytes = [UInt8](data)
            let lbaStart = Self.u32(bytes, 0x1BE + 8)
            partitionStart = lbaStart * 512
            let bpb = partitionStart
            sectorsPerCluster = Int(bytes[bpb + 0x0D])
            reservedSectors = Self.u16(bytes, bpb + 0x0E)
            fatCount = Int(bytes[bpb + 0x10])
            rootEntries = Self.u16(bytes, bpb + 0x11)
            fatSectors = Self.u16(bytes, bpb + 0x16)
            hiddenSectors = Self.u32(bytes, bpb + 0x1C)
            totalSectors32 = Self.u32(bytes, bpb + 0x20)
        }

        static func u16(_ b: [UInt8], _ o: Int) -> Int { Int(b[o]) | Int(b[o + 1]) << 8 }
        static func u32(_ b: [UInt8], _ o: Int) -> Int {
            u16(b, o) | u16(b, o + 2) << 16
        }

        var fatOffset: Int { partitionStart + reservedSectors * 512 }
        var rootOffset: Int { fatOffset + fatCount * fatSectors * 512 }
        var dataOffset: Int { rootOffset + rootEntries * 32 }

        func fatEntry(_ cluster: Int, copy: Int = 0) -> Int {
            Self.u16(bytes, fatOffset + copy * fatSectors * 512 + cluster * 2)
        }

        /// Follows a cluster chain to its end-of-chain marker.
        func chain(from first: Int) -> [Int] {
            var clusters = [first]
            while true {
                let next = fatEntry(clusters.last!)
                if next >= 0xFFF8 { return clusters }
                precondition(next >= 2 && clusters.count < 70000, "corrupt chain")
                clusters.append(next)
            }
        }

        struct Entry: Equatable {
            let name: String
            let attributes: UInt8
            let firstCluster: Int
            let size: Int
        }

        /// Parses consecutive 32-byte records until the 0x00 end marker.
        func entries(atByteOffset offset: Int, capacity: Int) -> [Entry] {
            var result: [Entry] = []
            for i in 0..<capacity {
                let e = offset + i * 32
                if bytes[e] == 0 { break }
                let base = String(decoding: bytes[e..<(e + 8)], as: UTF8.self)
                    .trimmingCharacters(in: .whitespaces)
                let ext = String(decoding: bytes[(e + 8)..<(e + 11)], as: UTF8.self)
                    .trimmingCharacters(in: .whitespaces)
                result.append(Entry(
                    name: ext.isEmpty ? base : base + "." + ext,
                    attributes: bytes[e + 11],
                    firstCluster: Self.u16(bytes, e + 26),
                    size: Self.u32(bytes, e + 28)))
            }
            return result
        }

        func rootDirectory() -> [Entry] {
            entries(atByteOffset: rootOffset, capacity: rootEntries)
        }

        /// Reads a subdirectory by walking its cluster chain.
        func directory(firstCluster: Int) -> [Entry] {
            var all: [Entry] = []
            for cluster in chain(from: firstCluster) {
                let capacity = sectorsPerCluster * 512 / 32
                let parsed = entries(atByteOffset: clusterOffset(cluster), capacity: capacity)
                all.append(contentsOf: parsed)
                if parsed.count < capacity { break } // hit the end marker mid-cluster
            }
            return all
        }

        func clusterOffset(_ cluster: Int) -> Int {
            dataOffset + (cluster - 2) * sectorsPerCluster * 512
        }

        func content(of entry: Entry) -> Data {
            guard entry.size > 0 else { return Data() }
            var data = Data()
            for cluster in chain(from: entry.firstCluster) {
                let start = clusterOffset(cluster)
                data.append(contentsOf: bytes[start..<(start + sectorsPerCluster * 512)])
            }
            return data.prefix(entry.size)
        }
    }

    private func buildAndParse(
        _ populate: (FAT16ImageBuilder) throws -> Void
    ) throws -> ParsedImage {
        let url = try makeTempDir().appendingPathComponent("image.raw")
        let builder = try FAT16ImageBuilder(creatingImageAt: url, geometry: Self.smallGeometry)
        try populate(builder)
        try builder.close()
        return ParsedImage(try Data(contentsOf: url))
    }

    // MARK: - Production geometry vs the proven image

    /// The full-size layout must reproduce the mtools-built image this design
    /// is anchored to: every MBR/BPB field below was read straight out of
    /// wizard-s0's proven install-source drive. If any assertion here fires,
    /// the image would no longer be the thing IO.SYS was proven against.
    func testWin98GeometryMatchesProvenImage() throws {
        let url = try makeTempDir().appendingPathComponent("full.raw")
        let builder = try FAT16ImageBuilder(creatingImageAt: url) // default geometry
        XCTAssertEqual(builder.sectorsPerCluster, 8)
        XCTAssertEqual(builder.fatSectors, 241)
        XCTAssertEqual(builder.clusterCount, 61541)
        try builder.close()

        let size = try XCTUnwrap(FileManager.default
            .attributesOfItem(atPath: url.path)[.size] as? Int)
        XCTAssertEqual(size, 246_456 * 1024, "must match sockdrive's fat16-256m template size")

        // The structures all live in the first MB; no need to load 240 MB.
        let handle = try FileHandle(forReadingFrom: url)
        defer { try? handle.close() }
        let head = try XCTUnwrap(handle.read(upToCount: 1 << 20))
        let parsed = ParsedImage(head)

        // MBR partition entry, byte-for-byte what mpartition wrote:
        // active, CHS 0/1/1 → 488/15/63, type 06, LBA 63, 492849 sectors.
        XCTAssertEqual([UInt8](head[0x1BE..<0x1CE]),
                       [0x80, 0x01, 0x01, 0x00, 0x06, 0x0F, 0x7F, 0xE8,
                        0x3F, 0x00, 0x00, 0x00, 0x31, 0x85, 0x07, 0x00])
        XCTAssertEqual([UInt8](head[0x1FE..<0x200]), [0x55, 0xAA])

        // BPB, field-for-field per the proven image (incl. hidden = 63).
        XCTAssertEqual(parsed.partitionStart, 63 * 512)
        XCTAssertEqual(parsed.sectorsPerCluster, 8)
        XCTAssertEqual(parsed.reservedSectors, 1)
        XCTAssertEqual(parsed.fatCount, 2)
        XCTAssertEqual(parsed.rootEntries, 512)
        XCTAssertEqual(parsed.fatSectors, 241)
        XCTAssertEqual(parsed.hiddenSectors, 63)
        XCTAssertEqual(parsed.totalSectors32, 492_849)
        let bpb = parsed.partitionStart
        XCTAssertEqual(ParsedImage.u16(parsed.bytes, bpb + 0x0B), 512)
        XCTAssertEqual(ParsedImage.u16(parsed.bytes, bpb + 0x13), 0, "small-total unused")
        XCTAssertEqual(parsed.bytes[bpb + 0x15], 0xF8)
        XCTAssertEqual(ParsedImage.u16(parsed.bytes, bpb + 0x18), 63)
        XCTAssertEqual(ParsedImage.u16(parsed.bytes, bpb + 0x1A), 16)
        XCTAssertEqual(parsed.bytes[bpb + 0x1FE], 0x55)
        XCTAssertEqual(parsed.bytes[bpb + 0x1FF], 0xAA)

        // FAT bootstrap entries, in both copies.
        XCTAssertEqual(parsed.fatEntry(0), 0xFFF8)
        XCTAssertEqual(parsed.fatEntry(1), 0xFFFF)
        XCTAssertEqual(parsed.fatEntry(0, copy: 1), 0xFFF8)
        XCTAssertEqual(parsed.fatEntry(1, copy: 1), 0xFFFF)
    }

    // MARK: - Structure round-trips (small geometry)

    func testEmptyVolumeHasCleanFATsAndRoot() throws {
        let parsed = try buildAndParse { _ in }
        XCTAssertEqual(parsed.fatEntry(0), 0xFFF8)
        XCTAssertEqual(parsed.fatEntry(1), 0xFFFF)
        XCTAssertEqual(parsed.fatEntry(2), 0, "no clusters allocated on an empty volume")
        XCTAssertEqual(parsed.fatEntry(2, copy: 1), 0)
        XCTAssertTrue(parsed.rootDirectory().isEmpty)
        // Both FAT copies must be identical.
        let fat0 = parsed.bytes[parsed.fatOffset..<(parsed.fatOffset + parsed.fatSectors * 512)]
        let fat1Start = parsed.fatOffset + parsed.fatSectors * 512
        XCTAssertEqual(fat0, parsed.bytes[fat1Start..<(fat1Start + parsed.fatSectors * 512)])
    }

    func testFilesAndDirectoriesRoundTrip() throws {
        let msbatch = pattern(200, seed: 7)
        let bigCab = pattern(1800, seed: 3)   // > 3 clusters at 512 B/cluster
        let setupExe = pattern(100, seed: 5)
        let deep = pattern(40, seed: 9)

        let parsed = try buildAndParse { builder in
            try builder.addFile(path: "MSBATCH.INF", data: msbatch)
            try builder.addDirectory(path: "WIN98")
            try builder.addFile(path: "WIN98/BIG.CAB", data: bigCab)
            try builder.addFile(path: "WIN98\\SETUP.EXE", data: setupExe) // DOS slashes too
            try builder.addFile(path: "WIN98/EMPTY.DAT", data: Data())
            try builder.addDirectory(path: "WIN98/OLS")
            try builder.addFile(path: "WIN98/OLS/DEEP.TXT", data: deep)
        }

        // Root: the answer file and the WIN98 tree, in add order.
        let root = parsed.rootDirectory()
        XCTAssertEqual(root.map(\.name), ["MSBATCH.INF", "WIN98"])
        XCTAssertEqual(root[0].attributes, 0x20)
        XCTAssertEqual(root[0].size, 200)
        XCTAssertEqual(parsed.content(of: root[0]), msbatch)
        XCTAssertEqual(root[1].attributes, 0x10)
        XCTAssertEqual(root[1].size, 0)

        // WIN98: dot entries first, wired to itself and to root (0).
        let win98 = parsed.directory(firstCluster: root[1].firstCluster)
        XCTAssertEqual(win98.map(\.name), [".", "..", "BIG.CAB", "SETUP.EXE", "EMPTY.DAT", "OLS"])
        XCTAssertEqual(win98[0].firstCluster, root[1].firstCluster)
        XCTAssertEqual(win98[1].firstCluster, 0, "parent of a root child is cluster 0")

        // The multi-cluster file: a contiguous chain (the bump allocator's
        // guarantee) whose content survives the trip.
        let big = win98[2]
        XCTAssertEqual(big.size, 1800)
        let bigChain = parsed.chain(from: big.firstCluster)
        XCTAssertEqual(bigChain.count, 4)
        XCTAssertEqual(bigChain, Array(big.firstCluster..<(big.firstCluster + 4)))
        XCTAssertEqual(parsed.content(of: big), bigCab)

        XCTAssertEqual(parsed.content(of: win98[3]), setupExe)

        // Zero-byte files own no clusters at all.
        XCTAssertEqual(win98[4].firstCluster, 0)
        XCTAssertEqual(win98[4].size, 0)

        // The nested directory points back at WIN98, and its file reads back.
        let ols = parsed.directory(firstCluster: win98[5].firstCluster)
        XCTAssertEqual(ols.map(\.name), [".", "..", "DEEP.TXT"])
        XCTAssertEqual(ols[1].firstCluster, root[1].firstCluster)
        XCTAssertEqual(parsed.content(of: ols[2]), deep)
    }

    /// 512-byte clusters hold 16 entries, so 20 files force the directory to
    /// grow a second (non-adjacent, since file data intervenes) FAT-chained
    /// cluster — the path the production \WIN98 dir would take past 126 files.
    func testDirectoryGrowsAcrossClusters() throws {
        let parsed = try buildAndParse { builder in
            try builder.addDirectory(path: "WIN98")
            for i in 0..<20 {
                try builder.addFile(path: "WIN98/F\(i).DAT", data: Data([UInt8(i + 1)]))
            }
        }
        let dirCluster = parsed.rootDirectory()[0].firstCluster
        XCTAssertEqual(parsed.chain(from: dirCluster).count, 2)
        let listing = parsed.directory(firstCluster: dirCluster)
        XCTAssertEqual(listing.count, 22) // . + .. + 20 files
        for i in 0..<20 {
            let entry = listing[i + 2]
            XCTAssertEqual(entry.name, "F\(i).DAT")
            XCTAssertEqual(parsed.content(of: entry), Data([UInt8(i + 1)]))
        }
    }

    func testVolumeLabelLandsInBPBAndRoot() throws {
        let url = try makeTempDir().appendingPathComponent("labeled.raw")
        let builder = try FAT16ImageBuilder(creatingImageAt: url, geometry: Self.smallGeometry,
                                            volumeLabel: "POCKETDOS")
        try builder.close()
        let parsed = ParsedImage(try Data(contentsOf: url))
        let labelField = parsed.bytes[(parsed.partitionStart + 0x2B)..<(parsed.partitionStart + 0x36)]
        XCTAssertEqual(String(decoding: labelField, as: UTF8.self), "POCKETDOS  ")
        let root = parsed.rootDirectory()
        XCTAssertEqual(root.count, 1)
        XCTAssertEqual(root[0].attributes, 0x08)
        XCTAssertEqual(root[0].firstCluster, 0)
    }

    // MARK: - Streaming

    func testStreamingReaderIsChunkedAtFourMiB() throws {
        let size = 5 * 1024 * 1024 // two chunks: 4 MiB + 1 MiB
        let content = pattern(size, seed: 11)
        var calls: [(offset: Int, count: Int)] = []

        let parsed = try buildAndParse { builder in
            try builder.addFile(path: "BIG.BIN", size: size) { offset, count in
                calls.append((offset, count))
                return content.subdata(in: offset..<(offset + count))
            }
        }
        XCTAssertEqual(calls.map(\.offset), [0, 4 << 20])
        XCTAssertEqual(calls.map(\.count), [4 << 20, 1 << 20])
        let entry = parsed.rootDirectory()[0]
        XCTAssertEqual(entry.size, size)
        XCTAssertEqual(parsed.content(of: entry), content)
    }

    func testShortReaderThrows() throws {
        let url = try makeTempDir().appendingPathComponent("short.raw")
        let builder = try FAT16ImageBuilder(creatingImageAt: url, geometry: Self.smallGeometry)
        XCTAssertThrowsError(try builder.addFile(path: "TRUNC.BIN", size: 1000) { _, _ in
            Data(count: 999) // one byte short — a truncated source must not pass
        }) { error in
            XCTAssertEqual(error as? FAT16ImageBuilder.BuilderError,
                           .shortRead(path: "TRUNC.BIN", expected: 1000, got: 999))
        }
    }

    // MARK: - Validation and failure modes

    func testRejectsNon83Names() throws {
        let url = try makeTempDir().appendingPathComponent("names.raw")
        let builder = try FAT16ImageBuilder(creatingImageAt: url, geometry: Self.smallGeometry)
        for bad in ["readme.txt",       // lowercase — deliberately unsupported
                    "TOOLONGNAME.CAB",  // 11-char base
                    "A.EXTS",           // 4-char extension
                    "BAD NAME.TXT",     // space
                    "A..B",             // double dot
                    ".DOT",             // empty base
                    "ÜBER.TXT",         // non-ASCII
                    "NAME."] {          // empty extension
            XCTAssertThrowsError(try builder.addFile(path: bad, data: Data([1])),
                                 "\(bad) should be rejected") { error in
                XCTAssertEqual(error as? FAT16ImageBuilder.BuilderError, .invalidName(bad))
            }
        }
        // Same gate on directories.
        XCTAssertThrowsError(try builder.addDirectory(path: "win98"))
        try builder.close()
    }

    func testDuplicateAndMissingParentThrow() throws {
        let url = try makeTempDir().appendingPathComponent("dups.raw")
        let builder = try FAT16ImageBuilder(creatingImageAt: url, geometry: Self.smallGeometry)
        try builder.addDirectory(path: "WIN98")
        XCTAssertThrowsError(try builder.addDirectory(path: "WIN98")) { error in
            XCTAssertEqual(error as? FAT16ImageBuilder.BuilderError, .duplicateEntry("WIN98"))
        }
        XCTAssertThrowsError(try builder.addFile(path: "WIN98", data: Data([1]))) { error in
            XCTAssertEqual(error as? FAT16ImageBuilder.BuilderError, .duplicateEntry("WIN98"))
        }
        XCTAssertThrowsError(try builder.addFile(path: "NOPE/X.TXT", data: Data([1]))) { error in
            XCTAssertEqual(error as? FAT16ImageBuilder.BuilderError,
                           .missingParentDirectory("NOPE/X.TXT"))
        }
        try builder.close()
    }

    /// A volume too small for FAT16 (cluster count under 4085 would make DOS
    /// read it as FAT12) must be refused outright, not built wrong.
    func testTooSmallGeometryIsRejected() throws {
        let url = try makeTempDir().appendingPathComponent("tiny.raw")
        let tiny = FAT16ImageBuilder.Geometry(cylinders: 2, heads: 16, sectorsPerTrack: 63)
        XCTAssertThrowsError(
            try FAT16ImageBuilder(creatingImageAt: url, geometry: tiny)) { error in
            guard case .unsupportedVolume = error as? FAT16ImageBuilder.BuilderError else {
                return XCTFail("expected unsupportedVolume, got \(error)")
            }
        }
    }

    func testUseAfterCloseThrows() throws {
        let url = try makeTempDir().appendingPathComponent("closed.raw")
        let builder = try FAT16ImageBuilder(creatingImageAt: url, geometry: Self.smallGeometry)
        try builder.close()
        XCTAssertThrowsError(try builder.addDirectory(path: "WIN98")) { error in
            XCTAssertEqual(error as? FAT16ImageBuilder.BuilderError, .alreadyClosed)
        }
        XCTAssertThrowsError(try builder.close()) { error in
            XCTAssertEqual(error as? FAT16ImageBuilder.BuilderError, .alreadyClosed)
        }
    }

    // MARK: - MSBATCH.INF

    /// The answer file is a byte-exact port of the Chrome-proven generator —
    /// so pin ALL the bytes, not just spot values. The key below is a dummy
    /// fixture (all A's); real keys exist only in user sessions.
    func testMSBATCHContentIsExact() throws {
        let data = FAT16ImageBuilder.msbatchINF(productKey: "AAAAA-AAAAA-AAAAA-AAAAA-AAAAA")
        let expected = [
            "[BatchSetup]", "Version=3.0 (32-bit)", "SaveDate=07/05/2026", "",
            "[Version]", "Signature = \"$CHICAGO$\"", "",
            "[Setup]", "Express=1", "InstallDir=\"C:\\WINDOWS\"", "InstallType=1",
            "ProductKey=\"AAAAA-AAAAA-AAAAA-AAAAA-AAAAA\"", "EBD=0", "ShowEula=0",
            "ChangeDir=0", "OptionalComponents=1", "Network=0", "System=0", "CCP=0",
            "CleanBoot=0", "Display=0", "PenWinWarning=0", "InstallDirCheck=0",
            "NoDirWarn=1", "TimeZone=\"Pacific\"", "Uninstall=0", "VRC=0",
            "NoPrompt2Boot=1", "",
            "[NameAndOrg]", "Name=\"PocketDOS\"", "Org=\"PocketDOS\"", "Display=0", "",
            "[InstallLocationsMRU]", "",
            "[OptionalComponents]", "\"Dial-Up Networking\"=0", "\"Dial-Up Server\"=0",
            "\"Direct Cable Connection\"=0", "\"Phone Dialer\"=0",
            "\"Microsoft NetMeeting\"=0", "\"Web-Based Enterprise Mgmt\"=0",
            "\"Web TV for Windows\"=0", "\"Online Services\"=0", "\"Microsoft Wallet\"=0", "",
            "[Network]", "ComputerName=POCKETDOS", "Workgroup=WORKGROUP", "Display=0", "",
        ].joined(separator: "\r\n") + "\r\n"
        XCTAssertEqual(data, expected.data(using: .isoLatin1))

        // Every newline must be CRLF — a bare LF breaks DOS INF parsing.
        let text = String(decoding: data, as: UTF8.self)
        XCTAssertFalse(text.replacingOccurrences(of: "\r\n", with: "").contains("\n"))
        XCTAssertFalse(text.replacingOccurrences(of: "\r\n", with: "").contains("\r"))
    }
}
