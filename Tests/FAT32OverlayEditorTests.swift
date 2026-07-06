import XCTest
@testable import PocketDOS

/// A synthetic-but-valid FAT32 sockdrive, built byte-by-byte so every
/// structure the editor touches has a KNOWN independent layout. Shaped like
/// the production template one size down: MBR partition at LBA 63, BPB with
/// hidden=63, FSInfo at partition sector 1, two FATs, root directory as a
/// cluster chain at cluster 2 — but with 2-sector clusters and 1000 clusters
/// total so the whole disk fits one 256 KiB chunk. Undersized FAT32 is
/// exactly what the editor must accept (its BPB says FAT32; the spec's 65525
/// threshold is a formatter's rule, not a reader's).
///
/// Traps a FAT32 writer must survive, mirroring FAT12FloppyFixture:
///  - README.TXT's chain is NON-contiguous (5 → 9 → 6), so wrong chain walks
///    scramble content order detectably;
///  - the root leads with a volume label, an LFN entry whose 11 "name" bytes
///    SPELL GHOST.TXT, and a deleted entry — all must be skipped by attribute
///    or lead byte, not by luck;
///  - cluster 8 is a free GAP between used clusters, so a lazy "allocate at
///    the end" allocator gives itself away;
///  - WINDOWS\SYSTEM is exactly full (32 entries in its single 2-sector
///    cluster), so any add there must extend the chain;
///  - file slack is poisoned with 0xCC, so missing zero-padding shows up.
enum FAT32Fixture {
    static let sectorSize = 512
    static let partitionStart = 63
    static let reservedSectors = 3
    static let fatCount = 2
    static let fatSectors = 8
    static let sectorsPerCluster = 2
    static let clusterCount = 1000
    static let totalSectors = reservedSectors + fatCount * fatSectors
        + clusterCount * sectorsPerCluster // 2019
    static let clusterBytes = sectorsPerCluster * sectorSize

    static let fsInfoLBA = partitionStart + 1                      // 64
    static let fat1LBA = partitionStart + reservedSectors          // 66
    static let fat2LBA = fat1LBA + fatSectors                      // 74
    static let dataLBA = fat2LBA + fatSectors                      // 82
    static func lba(ofCluster cluster: Int) -> Int { dataLBA + (cluster - 2) * sectorsPerCluster }

    // Cluster map: 2=root, 3=WINDOWS, 4=SYSTEM.INI, 5→9→6=README.TXT,
    // 7=WINDOWS\SYSTEM (full), 8=FREE GAP, 10+ free.
    static let rootCluster = 2
    static let windowsCluster = 3
    static let systemINICluster = 4
    static let readmeChain = [5, 9, 6]
    static let systemDirCluster = 7
    static let freeGapCluster = 8

    static let endOfChain: UInt32 = 0x0FFF_FFFF
    static let fixtureFreeCount: UInt32 = 993
    static let fixtureNextFree: UInt32 = 8

    static let systemINILines = [
        "[boot]",
        "shell=Explorer.exe",
        "mouse.drv=mouse.drv",
        "fonts.fon=vgasys.fon",
        "",
        "[boot.description]",
        "mouse.drv=Standard mouse",
        "system.drv=Standard PC",
        "",
        "[386Enh]",
        "mouse=*vmouse, msmouse.vxd",
        "device=*vshare",
        "",
    ]
    static var systemINI: Data { Data(systemINILines.joined(separator: "\r\n").utf8) }

    static let readmeContent: Data = {
        var bytes = [UInt8]()
        for i in 0..<2500 { bytes.append(UInt8(truncatingIfNeeded: i &* 37 &+ 11)) }
        return Data(bytes)
    }()

    /// The whole disk as one image, padded to five 256 KiB chunks. Everything
    /// nonzero lands in chunk 0; chunks 1-4 stay all-zero so `chunks()` drops
    /// them, giving the missing-chunk-reads-as-zeros case for free.
    static func image(systemINI iniContent: Data = systemINI) -> Data {
        precondition(iniContent.count <= clusterBytes)
        var img = [UInt8](repeating: 0, count: (partitionStart + totalSectors) * sectorSize)

        // MBR: one FAT32-LBA (0x0C) partition — the editor must read this,
        // not assume 63. (Production uses 0x0B; both must be accepted.)
        let pe = 0x1BE
        img[pe] = 0x80
        img[pe + 4] = 0x0C
        put32(&img, pe + 8, partitionStart)
        put32(&img, pe + 12, totalSectors)
        img[510] = 0x55
        img[511] = 0xAA

        // BPB at LBA 63.
        let bpb = partitionStart * sectorSize
        img[bpb] = 0xEB; img[bpb + 1] = 0x58; img[bpb + 2] = 0x90
        replace(&img, at: bpb + 3, with: Array("MSWIN4.1".utf8))
        put16(&img, bpb + 0x0B, sectorSize)
        img[bpb + 0x0D] = UInt8(sectorsPerCluster)
        put16(&img, bpb + 0x0E, reservedSectors)
        img[bpb + 0x10] = UInt8(fatCount)
        // 0x11 (root entries) and 0x16 (FAT size 16) stay 0: FAT32's fingerprint.
        img[bpb + 0x15] = 0xF8
        put16(&img, bpb + 0x18, 63)
        put16(&img, bpb + 0x1A, 16)
        put32(&img, bpb + 0x1C, partitionStart) // hidden sectors
        put32(&img, bpb + 0x20, totalSectors)
        put32(&img, bpb + 0x24, fatSectors)
        put32(&img, bpb + 0x2C, rootCluster)
        put16(&img, bpb + 0x30, 1)              // FSInfo sector
        img[bpb + 0x40] = 0x80
        img[bpb + 0x42] = 0x29
        put32(&img, bpb + 0x43, 0x50444F53)     // serial "PDOS"
        replace(&img, at: bpb + 0x47, with: Array("NO NAME    ".utf8))
        replace(&img, at: bpb + 0x52, with: Array("FAT32   ".utf8))
        img[bpb + 510] = 0x55
        img[bpb + 511] = 0xAA

        // FSInfo at LBA 64, with a KNOWN free count / next-free so tests can
        // watch the editor invalidate them.
        let fsi = fsInfoLBA * sectorSize
        put32(&img, fsi, 0x4161_5252)
        put32(&img, fsi + 0x1E4, 0x6141_7272)
        put32(&img, fsi + 0x1E8, Int(fixtureFreeCount))
        put32(&img, fsi + 0x1EC, Int(fixtureNextFree))
        put32(&img, fsi + 0x1FC, Int(0xAA55_0000 as UInt32))

        // Both FATs, identical: media/EOC markers, then the fixture chains.
        var fat = [UInt32](repeating: 0, count: clusterCount + 2)
        fat[0] = 0x0FFF_FFF8
        fat[1] = endOfChain
        fat[rootCluster] = endOfChain
        fat[windowsCluster] = endOfChain
        fat[systemINICluster] = endOfChain
        fat[5] = 9
        fat[9] = 6
        fat[6] = endOfChain
        fat[systemDirCluster] = endOfChain
        for copy in 0..<fatCount {
            let base = (fat1LBA + copy * fatSectors) * sectorSize
            for (i, value) in fat.enumerated() { put32(&img, base + i * 4, Int(value)) }
        }

        // Root directory (cluster 2): label, LFN decoy spelling GHOST.TXT,
        // a deleted entry (its slot is the first the editor should reuse),
        // then the real WINDOWS and README.TXT entries.
        let root = lba(ofCluster: rootCluster) * sectorSize
        replace(&img, at: root, with: entry(name11: name11("PDOSTEST"), attr: 0x08,
                                            cluster: 0, size: 0))
        replace(&img, at: root + 32, with: entry(name11: name11("GHOST   TXT"), attr: 0x0F,
                                                 cluster: 0, size: 0))
        var deleted = entry(name11: name11("XELETED TXT"), attr: 0x20, cluster: 0, size: 0)
        deleted[0] = 0xE5
        replace(&img, at: root + 64, with: deleted)
        replace(&img, at: root + 96, with: entry(name11: name11("WINDOWS    "), attr: 0x10,
                                                 cluster: windowsCluster, size: 0))
        replace(&img, at: root + 128, with: entry(name11: name11("README  TXT"), attr: 0x20,
                                                  cluster: 5, size: readmeContent.count))

        // WINDOWS (cluster 3): dot entries, SYSTEM.INI, SYSTEM.
        let win = lba(ofCluster: windowsCluster) * sectorSize
        replace(&img, at: win, with: entry(name11: name11(".          "), attr: 0x10,
                                           cluster: windowsCluster, size: 0))
        replace(&img, at: win + 32, with: entry(name11: name11("..         "), attr: 0x10,
                                                cluster: 0, size: 0))
        replace(&img, at: win + 64, with: entry(name11: name11("SYSTEM  INI"), attr: 0x20,
                                                cluster: systemINICluster,
                                                size: iniContent.count))
        replace(&img, at: win + 96, with: entry(name11: name11("SYSTEM     "), attr: 0x10,
                                                cluster: systemDirCluster, size: 0))

        // SYSTEM.INI content (cluster 4), slack poisoned with 0xCC.
        let ini = lba(ofCluster: systemINICluster) * sectorSize
        for i in 0..<clusterBytes { img[ini + i] = 0xCC }
        replace(&img, at: ini, with: [UInt8](iniContent))

        // README.TXT across its fragmented chain, in CHAIN order 5 → 9 → 6,
        // with the final cluster's slack poisoned.
        for (index, cluster) in readmeChain.enumerated() {
            let at = lba(ofCluster: cluster) * sectorSize
            for i in 0..<clusterBytes { img[at + i] = 0xCC }
            let start = index * clusterBytes
            let end = min(start + clusterBytes, readmeContent.count)
            replace(&img, at: at, with: [UInt8](readmeContent[start..<end]))
        }

        // WINDOWS\SYSTEM (cluster 7): exactly full — dot entries plus 30
        // zero-length FILLnn.DAT files = 32 entries in a 1024-byte cluster.
        let sys = lba(ofCluster: systemDirCluster) * sectorSize
        replace(&img, at: sys, with: entry(name11: name11(".          "), attr: 0x10,
                                           cluster: systemDirCluster, size: 0))
        replace(&img, at: sys + 32, with: entry(name11: name11("..         "), attr: 0x10,
                                                cluster: windowsCluster, size: 0))
        for i in 0..<30 {
            let name = String(format: "FILL%02d  DAT", i)
            replace(&img, at: sys + 64 + i * 32, with: entry(name11: name11(name), attr: 0x20,
                                                             cluster: 0, size: 0))
        }

        img += [UInt8](repeating: 0, count: 5 * FAT32OverlayEditor.chunkBytes - img.count)
        return Data(img)
    }

    /// Splits an image into 256 KiB sockdrive chunks, dropping all-zero ones
    /// (exactly what the chunker does — that's why missing chunk = zeros).
    static func chunks(image: Data) -> [Int: Data] {
        var chunks: [Int: Data] = [:]
        let size = FAT32OverlayEditor.chunkBytes
        for index in 0..<(image.count / size) {
            let chunk = image.subdata(in: (index * size)..<((index + 1) * size))
            if chunk.contains(where: { $0 != 0 }) { chunks[index] = chunk }
        }
        return chunks
    }

    // MARK: Overlay blob construction

    static let emptyOverlay = Data([0, 0, 0, 0])

    static func overlay(records: [Data]) -> Data {
        var count = [UInt8](repeating: 0, count: 4)
        put32(&count, 0, records.count)
        return records.reduce(Data(count)) { $0 + $1 }
    }

    static func rawRecord(lba: UInt32, sector: [UInt8]) -> Data {
        precondition(sector.count == 512)
        var record = [UInt8](repeating: 0, count: 8)
        put32(&record, 0, 516)
        put32(&record, 4, Int(lba))
        return Data(record) + Data(sector)
    }

    /// A hand-crafted mini-LZ4 block decoding to LBA `lba` + 512 × 0xAB:
    /// token 0x5F = 5 literals (the 4 LBA bytes + one 0xAB) with match length
    /// 15+; offset 1 (RLE off the just-written 0xAB); extension bytes 255+236
    /// stretch the match to 506 (+4 implicit = 510 copied, j = 515); final
    /// token 0x10 emits one closing literal, ending exactly at 516 with the
    /// input exhausted — the decoder's terminal literals-only path.
    static func lz4Record(lba: UInt32) -> (record: Data, sector: [UInt8]) {
        let block: [UInt8] = [0x5F,
                              UInt8(lba & 0xFF), UInt8((lba >> 8) & 0xFF),
                              UInt8((lba >> 16) & 0xFF), UInt8((lba >> 24) & 0xFF),
                              0xAB, 0x01, 0x00, 0xFF, 0xEC, 0x10, 0xAB]
        var record = [UInt8](repeating: 0, count: 4)
        put32(&record, 0, block.count)
        return (Data(record) + Data(block), [UInt8](repeating: 0xAB, count: 512))
    }

    // MARK: Byte-level helpers

    static func name11(_ s: String) -> [UInt8] {
        var bytes = [UInt8](repeating: 0x20, count: 11)
        for (i, char) in s.utf8.enumerated() where i < 11 { bytes[i] = char }
        return bytes
    }

    static func entry(name11: [UInt8], attr: UInt8, cluster: Int, size: Int) -> [UInt8] {
        var e = [UInt8](repeating: 0, count: 32)
        e.replaceSubrange(0..<11, with: name11)
        e[11] = attr
        put16(&e, 20, cluster >> 16)
        put16(&e, 26, cluster & 0xFFFF)
        put32(&e, 28, size)
        return e
    }

    static func put16(_ buffer: inout [UInt8], _ offset: Int, _ value: Int) {
        buffer[offset] = UInt8(value & 0xFF)
        buffer[offset + 1] = UInt8((value >> 8) & 0xFF)
    }

    static func put32(_ buffer: inout [UInt8], _ offset: Int, _ value: Int) {
        buffer[offset] = UInt8(value & 0xFF)
        buffer[offset + 1] = UInt8((value >> 8) & 0xFF)
        buffer[offset + 2] = UInt8((value >> 16) & 0xFF)
        buffer[offset + 3] = UInt8((value >> 24) & 0xFF)
    }

    private static func replace(_ buffer: inout [UInt8], at offset: Int, with bytes: [UInt8]) {
        buffer.replaceSubrange(offset..<(offset + bytes.count), with: bytes)
    }
}

final class FAT32OverlayEditorTests: XCTestCase {

    private func makeEditor(overlay: Data = FAT32Fixture.emptyOverlay,
                            systemINI: Data = FAT32Fixture.systemINI) throws -> FAT32OverlayEditor {
        let chunks = FAT32Fixture.chunks(image: FAT32Fixture.image(systemINI: systemINI))
        return try FAT32OverlayEditor(overlay: overlay) { chunks[$0] }
    }

    /// Every record this editor appended, decoded straight off the blob bytes
    /// (independent of the editor's own map), verifying the raw-516 format.
    private func appendedRecords(of editor: FAT32OverlayEditor,
                                 originalLength: Int) -> [(lba: UInt32, sector: [UInt8])] {
        let blob = editor.overlay
        var records: [(UInt32, [UInt8])] = []
        var offset = originalLength
        while offset < blob.count {
            guard offset + 520 <= blob.count else {
                XCTFail("appended region ends mid-record at \(offset)")
                break
            }
            XCTAssertEqual(u32(blob, offset), 516, "appended records must be raw 516-byte form")
            let lba = u32(blob, offset + 4)
            let sector = [UInt8](blob[(blob.startIndex + offset + 8)..<(blob.startIndex + offset + 8 + 512)])
            records.append((lba, sector))
            offset += 8 + 512
        }
        return records
    }

    private func u32(_ data: Data, _ offset: Int) -> UInt32 {
        UInt32(data[data.startIndex + offset])
            | UInt32(data[data.startIndex + offset + 1]) << 8
            | UInt32(data[data.startIndex + offset + 2]) << 16
            | UInt32(data[data.startIndex + offset + 3]) << 24
    }

    private func sector(_ fill: UInt8) -> [UInt8] { [UInt8](repeating: fill, count: 512) }

    // MARK: - Overlay parsing + composite reads

    func testOverlayParsesRawAndLZ4RecordsWithLaterRecordsWinning() throws {
        let free = FAT32Fixture.lba(ofCluster: FAT32Fixture.freeGapCluster)
        let lz4 = FAT32Fixture.lz4Record(lba: UInt32(FAT32Fixture.lba(ofCluster: 10)))
        let blob = FAT32Fixture.overlay(records: [
            FAT32Fixture.rawRecord(lba: UInt32(free), sector: sector(0x11)),
            lz4.record,
            FAT32Fixture.rawRecord(lba: UInt32(free + 1), sector: sector(0x22)),
            FAT32Fixture.rawRecord(lba: UInt32(free + 1), sector: sector(0x33)),
        ])
        let editor = try makeEditor(overlay: blob)

        XCTAssertEqual([UInt8](try editor.readSector(free)), sector(0x11))
        XCTAssertEqual([UInt8](try editor.readSector(FAT32Fixture.lba(ofCluster: 10))), lz4.sector,
                       "the LZ4 record must decode through the ported block decoder")
        XCTAssertEqual([UInt8](try editor.readSector(free + 1)), sector(0x33),
                       "later records for the same LBA supersede earlier ones (replay order)")
    }

    func testCompositeReadPrefersOverlayThenChunksThenZeros() throws {
        let iniLBA = FAT32Fixture.lba(ofCluster: FAT32Fixture.systemINICluster)
        let blob = FAT32Fixture.overlay(records: [
            FAT32Fixture.rawRecord(lba: UInt32(iniLBA), sector: sector(0x77)),
        ])
        let editor = try makeEditor(overlay: blob)

        // Overlay beats the chunk that DOES hold different data here.
        XCTAssertEqual([UInt8](try editor.readSector(iniLBA)), sector(0x77))
        // No overlay record: the chunk's own bytes come through.
        let fromChunk = try editor.readSector(iniLBA + 1)
        XCTAssertEqual([UInt8](fromChunk.prefix(4)), [0xCC, 0xCC, 0xCC, 0xCC],
                       "second SYSTEM.INI sector is fixture slack poison from the chunk")
        // Sector 600 lives in chunk 1, which is all-zero and therefore absent.
        XCTAssertEqual([UInt8](try editor.readSector(600)), sector(0x00))
    }

    func testMalformedOverlayBlobsThrow() {
        let cases: [(String, Data)] = [
            ("shorter than its count field", Data([1, 0])),
            ("count promises a record the bytes don't hold", Data([1, 0, 0, 0])),
            ("record length overruns the blob", Data([1, 0, 0, 0, 4, 2, 0, 0, 9])),
            ("trailing bytes after the last record",
             FAT32Fixture.overlay(records: [
                FAT32Fixture.rawRecord(lba: 600, sector: sector(1)),
             ]) + Data([0xDE])),
            ("undecodable LZ4 block", FAT32Fixture.overlay(records: [Data([1, 0, 0, 0, 0x00])])),
        ]
        for (what, blob) in cases {
            XCTAssertThrowsError(try makeEditor(overlay: blob), what) { error in
                guard case FAT32OverlayEditor.EditorError.malformedOverlay = error else {
                    return XCTFail("\(what): expected malformedOverlay, got \(error)")
                }
            }
        }
    }

    // MARK: - replaceFile

    func testReplaceFileRewritesContentZeroPadsSlackAndUpdatesDirEntrySize() throws {
        let editor = try makeEditor()
        let replacement = Data("mouse fixed\r\n".utf8)
        try editor.replaceFile(path: "WINDOWS/SYSTEM.INI") { old in
            XCTAssertEqual(old, FAT32Fixture.systemINI, "transform must see the current content")
            return replacement
        }

        XCTAssertEqual(try editor.readFile(path: "WINDOWS/SYSTEM.INI"), replacement)

        // The chain's slack — including the poisoned 0xCC tail — is zeroed.
        let iniLBA = FAT32Fixture.lba(ofCluster: FAT32Fixture.systemINICluster)
        let first = [UInt8](try editor.readSector(iniLBA))
        XCTAssertEqual(Array(first[0..<replacement.count]), [UInt8](replacement))
        XCTAssertEqual(Array(first[replacement.count...]),
                       [UInt8](repeating: 0, count: 512 - replacement.count))
        XCTAssertEqual([UInt8](try editor.readSector(iniLBA + 1)), sector(0x00))

        // Directory entry: size updated in place, name and cluster untouched.
        let winSector = try editor.readSector(FAT32Fixture.lba(ofCluster: FAT32Fixture.windowsCluster))
        XCTAssertEqual(u32(winSector, 64 + 28), UInt32(replacement.count))
        XCTAssertEqual([UInt8](winSector[(winSector.startIndex + 64)..<(winSector.startIndex + 75)]),
                       FAT32Fixture.name11("SYSTEM  INI"))
        XCTAssertEqual(Int(winSector[winSector.startIndex + 64 + 26]),
                       FAT32Fixture.systemINICluster, "first cluster must not change")
    }

    func testReplaceFileFollowsNonContiguousChainInOrderAndLeavesFATAlone() throws {
        let editor = try makeEditor()
        var replacement = [UInt8]()
        for i in 0..<2600 { replacement.append(UInt8(truncatingIfNeeded: i &* 13 &+ 5)) }
        try editor.replaceFile(path: "README.TXT") { _ in Data(replacement) }

        XCTAssertEqual(try editor.readFile(path: "README.TXT"), Data(replacement))

        // Chain order 5 → 9 → 6: each cluster gets its slice, not its neighbor's.
        for (index, cluster) in FAT32Fixture.readmeChain.enumerated() {
            let got = [UInt8](try editor.readSector(FAT32Fixture.lba(ofCluster: cluster)))
            let start = index * FAT32Fixture.clusterBytes
            XCTAssertEqual(Array(got[0..<64]), Array(replacement[start..<(start + 64)]),
                           "cluster \(cluster) must hold chain slice \(index)")
        }

        // No appended record may touch either FAT: replacement never reallocates.
        let fatRange = FAT32Fixture.fat1LBA..<FAT32Fixture.dataLBA
        for record in appendedRecords(of: editor, originalLength: 4) {
            XCTAssertFalse(fatRange.contains(Int(record.lba)),
                           "replaceFile wrote FAT sector \(record.lba)")
        }
    }

    func testReplaceFileBeyondChainCapacityThrowsWithoutWriting() throws {
        let editor = try makeEditor()
        let capacity = FAT32Fixture.readmeChain.count * FAT32Fixture.clusterBytes
        XCTAssertThrowsError(try editor.replaceFile(path: "README.TXT",
                                                    transform: { _ in Data(count: capacity + 1) })) { error in
            XCTAssertEqual(error as? FAT32OverlayEditor.EditorError,
                           .contentTooLarge(file: "README.TXT", size: capacity + 1,
                                            capacity: capacity))
        }
        XCTAssertEqual(editor.appendedRecords, 0)
        XCTAssertEqual(editor.overlay, FAT32Fixture.emptyOverlay,
                       "a refused replacement must leave the overlay untouched")
    }

    func testReplaceFileMissingFileThrows() throws {
        let editor = try makeEditor()
        XCTAssertThrowsError(try editor.replaceFile(path: "WINDOWS/NOPE.INI",
                                                    transform: { $0 })) { error in
            XCTAssertEqual(error as? FAT32OverlayEditor.EditorError,
                           .fileNotFound("WINDOWS/NOPE.INI"))
        }
    }

    func testLFNDecoyIsNotMatched() throws {
        // GHOST.TXT exists ONLY as the 11 name bytes of an LFN entry (attribute
        // 0x0F). Matching it would mean the attribute check happened after the
        // name comparison — the exact bug class the fixture exists to catch.
        let editor = try makeEditor()
        XCTAssertThrowsError(try editor.replaceFile(path: "GHOST.TXT", transform: { $0 })) { error in
            XCTAssertEqual(error as? FAT32OverlayEditor.EditorError, .fileNotFound("GHOST.TXT"))
        }
    }

    // MARK: - addFile

    func testAddFileToRootReusesDeletedSlotAllocatesGapClusterAndChainsBothFATs() throws {
        let editor = try makeEditor()
        var content = [UInt8]()
        for i in 0..<1536 { content.append(UInt8(truncatingIfNeeded: i &+ 3)) }
        try editor.addFile(path: "TEST.BIN", data: Data(content))

        XCTAssertEqual(try editor.readFile(path: "TEST.BIN"), Data(content))

        // First-fit allocation: the GAP at cluster 8 first, then cluster 10.
        for fatLBA in [FAT32Fixture.fat1LBA, FAT32Fixture.fat2LBA] {
            let fat = try editor.readSector(fatLBA)
            XCTAssertEqual(u32(fat, 8 * 4), 10, "FAT@\(fatLBA): cluster 8 must chain to 10")
            XCTAssertEqual(u32(fat, 10 * 4), FAT32Fixture.endOfChain,
                           "FAT@\(fatLBA): cluster 10 must terminate the chain")
        }

        // Data lands in the gap cluster, zero-padded through the last cluster.
        let gap = FAT32Fixture.lba(ofCluster: FAT32Fixture.freeGapCluster)
        XCTAssertEqual([UInt8](try editor.readSector(gap)), Array(content[0..<512]))
        XCTAssertEqual([UInt8](try editor.readSector(gap + 1)), Array(content[512..<1024]))
        let tail = FAT32Fixture.lba(ofCluster: 10)
        XCTAssertEqual([UInt8](try editor.readSector(tail)), Array(content[1024..<1536]))
        XCTAssertEqual([UInt8](try editor.readSector(tail + 1)), sector(0x00))

        // The entry reuses the DELETED slot (root offset 64), 8.3 + archive,
        // with the FAT32 high cluster word written (zero here, but written).
        let root = try editor.readSector(FAT32Fixture.lba(ofCluster: FAT32Fixture.rootCluster))
        let e = [UInt8](root[(root.startIndex + 64)..<(root.startIndex + 96)])
        XCTAssertEqual(Array(e[0..<11]), FAT32Fixture.name11("TEST    BIN"))
        XCTAssertEqual(e[11], 0x20)
        XCTAssertEqual(Int(e[26]) | Int(e[27]) << 8, 8)
        XCTAssertEqual(Int(e[20]) | Int(e[21]) << 8, 0)
        XCTAssertEqual(u32(Data(e), 28), 1536)
    }

    func testAddFileIntoSubdirectoryRoundTrips() throws {
        let editor = try makeEditor()
        let driver = Data((0..<700).map { UInt8(truncatingIfNeeded: $0 &* 7) })
        try editor.addFile(path: "WINDOWS/DBOXMPI.DRV", data: driver)
        XCTAssertEqual(try editor.readFile(path: "windows/dboxmpi.drv"), driver,
                       "path matching is case-insensitive, like DOS")

        // The entry landed in WINDOWS' free slot (after SYSTEM), not the root.
        let win = try editor.readSector(FAT32Fixture.lba(ofCluster: FAT32Fixture.windowsCluster))
        XCTAssertEqual([UInt8](win[(win.startIndex + 128)..<(win.startIndex + 139)]),
                       FAT32Fixture.name11("DBOXMPI DRV"))
    }

    func testAddFileZeroLengthOwnsNoClustersAndSkipsFSInfo() throws {
        let editor = try makeEditor()
        try editor.addFile(path: "EMPTY.TXT", data: Data())
        XCTAssertEqual(try editor.readFile(path: "EMPTY.TXT"), Data())

        // Exactly one sector changed: the root directory. No FAT, no FSInfo.
        let records = appendedRecords(of: editor, originalLength: 4)
        XCTAssertEqual(records.map { $0.lba },
                       [UInt32(FAT32Fixture.lba(ofCluster: FAT32Fixture.rootCluster))])
        let e = Array(records[0].sector[64..<96])
        XCTAssertEqual(Array(e[0..<11]), FAT32Fixture.name11("EMPTY   TXT"))
        XCTAssertEqual(Int(e[26]) | Int(e[27]) << 8, 0, "zero-length files own no clusters")
    }

    func testAddFileIntoFullDirectoryExtendsItsChain() throws {
        let editor = try makeEditor()
        let content = Data(repeating: 0x42, count: 100)
        try editor.addFile(path: "WINDOWS/SYSTEM/NEW.BIN", data: content)

        XCTAssertEqual(try editor.readFile(path: "WINDOWS/SYSTEM/NEW.BIN"), content)

        // File data took the gap (8); the directory grew into cluster 10.
        for fatLBA in [FAT32Fixture.fat1LBA, FAT32Fixture.fat2LBA] {
            let fat = try editor.readSector(fatLBA)
            XCTAssertEqual(u32(fat, 8 * 4), FAT32Fixture.endOfChain, "file cluster")
            XCTAssertEqual(u32(fat, FAT32Fixture.systemDirCluster * 4), 10,
                           "FAT@\(fatLBA): the full directory's old tail must relink")
            XCTAssertEqual(u32(fat, 10 * 4), FAT32Fixture.endOfChain)
        }

        // The grown cluster: entry at its head, the REST zeroed so slot 2
        // onward still reads as end-of-directory.
        let grown = try editor.readSector(FAT32Fixture.lba(ofCluster: 10))
        XCTAssertEqual([UInt8](grown[grown.startIndex..<(grown.startIndex + 11)]),
                       FAT32Fixture.name11("NEW     BIN"))
        XCTAssertEqual([UInt8](grown[(grown.startIndex + 32)...]),
                       [UInt8](repeating: 0, count: 480))
        XCTAssertEqual([UInt8](try editor.readSector(FAT32Fixture.lba(ofCluster: 10) + 1)),
                       sector(0x00))
    }

    func testAddFileDuplicateMissingParentAndInvalidNameThrow() throws {
        let editor = try makeEditor()
        XCTAssertThrowsError(try editor.addFile(path: "WINDOWS/SYSTEM.INI", data: Data([1]))) {
            XCTAssertEqual($0 as? FAT32OverlayEditor.EditorError,
                           .duplicateEntry("WINDOWS/SYSTEM.INI"))
        }
        XCTAssertThrowsError(try editor.addFile(path: "NOWHERE/FILE.BIN", data: Data([1]))) {
            XCTAssertEqual($0 as? FAT32OverlayEditor.EditorError, .fileNotFound("NOWHERE"))
        }
        XCTAssertThrowsError(try editor.addFile(path: "WINDOWS/SYSTEM.INI/X.BIN",
                                                data: Data([1]))) {
            XCTAssertEqual($0 as? FAT32OverlayEditor.EditorError, .notADirectory("SYSTEM.INI"))
        }
        XCTAssertThrowsError(try editor.addFile(path: "TOOLONGNAME.BIN", data: Data([1]))) {
            XCTAssertEqual($0 as? FAT32OverlayEditor.EditorError, .invalidName("TOOLONGNAME.BIN"))
        }
        XCTAssertEqual(editor.appendedRecords, 0)
    }

    func testAddFileInvalidatesFSInfo() throws {
        let editor = try makeEditor()

        // Fixture FSInfo starts with believable numbers...
        let before = try editor.readSector(FAT32Fixture.fsInfoLBA)
        XCTAssertEqual(u32(before, 0x1E8), FAT32Fixture.fixtureFreeCount)
        XCTAssertEqual(u32(before, 0x1EC), FAT32Fixture.fixtureNextFree)

        try editor.addFile(path: "TEST.BIN", data: Data(repeating: 1, count: 10))

        // ...and allocation flips both to the spec's "unknown", forcing every
        // FAT32 driver to recount from the FAT instead of trusting a number
        // this editor would otherwise have to promise is still true.
        let after = try editor.readSector(FAT32Fixture.fsInfoLBA)
        XCTAssertEqual(u32(after, 0x1E8), 0xFFFF_FFFF)
        XCTAssertEqual(u32(after, 0x1EC), 0xFFFF_FFFF)
        XCTAssertEqual(u32(after, 0), 0x4161_5252, "signatures survive")
        XCTAssertEqual(u32(after, 0x1E4), 0x6141_7272)
        XCTAssertEqual(u32(after, 0x1FC), 0xAA55_0000)
    }

    // MARK: - applyMouseFix

    func testApplyMouseFixInstallsDriverTwiceAndPatchesSystemINI() throws {
        let editor = try makeEditor()
        let driver = Data((0..<700).map { UInt8(truncatingIfNeeded: $0 &* 31 &+ 1) })
        try editor.applyMouseFix(driver: driver)

        XCTAssertEqual(try editor.readFile(path: "WINDOWS/DBOXMPI.DRV"), driver)
        XCTAssertEqual(try editor.readFile(path: "WINDOWS/SYSTEM/DBOXMPI.DRV"), driver)

        var expected = FAT32Fixture.systemINILines
        expected[2] = "mouse.drv=dboxmpi.drv"
        expected[6] = "mouse.drv=DOSBox-X Mouse Pointer Integration"
        expected[10] = "mouse="
        XCTAssertEqual(try editor.readFile(path: "WINDOWS/SYSTEM.INI"),
                       Data(expected.joined(separator: "\r\n").utf8),
                       "exactly three lines change; CRLF endings and all else survive")

        // Applying the proven fix to an already-fixed image is a LOUD error,
        // never a silent second pass.
        XCTAssertThrowsError(try editor.applyMouseFix(driver: driver)) {
            XCTAssertEqual($0 as? FAT32OverlayEditor.EditorError,
                           .missingLine("mouse.drv=mouse.drv"))
        }
    }

    func testApplyMouseFixThrowsLoudlyAndWritesNothingWhenALineIsMissing() throws {
        // A SYSTEM.INI missing its [386Enh] mouse line is not the
        // configuration the fix was proven against — refuse it whole.
        var lines = FAT32Fixture.systemINILines
        lines.removeAll { $0 == "mouse=*vmouse, msmouse.vxd" }
        let editor = try makeEditor(systemINI: Data(lines.joined(separator: "\r\n").utf8))

        XCTAssertThrowsError(try editor.applyMouseFix(driver: Data([1, 2, 3]))) {
            XCTAssertEqual($0 as? FAT32OverlayEditor.EditorError,
                           .missingLine("mouse=*vmouse, msmouse.vxd"))
        }
        XCTAssertEqual(editor.appendedRecords, 0)
        XCTAssertEqual(editor.overlay, FAT32Fixture.emptyOverlay,
                       "validation happens before the first write: no partial fix")
    }

    // MARK: - Overlay append format

    func testAppendedRecordsAreRawWithBumpedCountAndReplayInAFreshEditor() throws {
        let free = FAT32Fixture.lba(ofCluster: FAT32Fixture.freeGapCluster)
        let original = FAT32Fixture.overlay(records: [
            FAT32Fixture.rawRecord(lba: UInt32(free), sector: sector(0x99)),
        ])
        let editor = try makeEditor(overlay: original)
        let replacement = Data("patched\r\n".utf8)
        try editor.replaceFile(path: "WINDOWS/SYSTEM.INI") { _ in replacement }

        // Count bumped by exactly the appended records; original bytes intact.
        let blob = editor.overlay
        let appended = appendedRecords(of: editor, originalLength: original.count)
        XCTAssertEqual(u32(blob, 0), UInt32(1 + appended.count))
        XCTAssertEqual(editor.appendedRecords, appended.count)
        XCTAssertEqual(blob.subdata(in: (blob.startIndex + 4)..<(blob.startIndex + original.count)),
                       original.subdata(in: (original.startIndex + 4)..<(original.startIndex + original.count)),
                       "append-only: every original record byte survives verbatim")

        // The blob REPLAYS: a fresh editor over the same chunks sees the edit
        // purely through record supersession — the client's exact view.
        let chunks = FAT32Fixture.chunks(image: FAT32Fixture.image())
        let replayed = try FAT32OverlayEditor(overlay: blob) { chunks[$0] }
        XCTAssertEqual(try replayed.readFile(path: "WINDOWS/SYSTEM.INI"), replacement)
        XCTAssertEqual([UInt8](try replayed.readSector(free)), sector(0x99),
                       "untouched original records still apply")
    }
}
