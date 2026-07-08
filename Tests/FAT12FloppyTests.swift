import XCTest
@testable import PocketDOS

/// A synthetic-but-valid 1.44 MB FAT12 floppy, built byte-by-byte so every
/// structure the writer touches has a KNOWN independent layout. Deliberately
/// shaped like the retail Win98 CDBOOT floppy (512 B/sector, 1 sector/cluster,
/// 1 reserved sector, 2 × 9-sector FATs, 224 root entries), with the traps a
/// FAT12 writer must survive:
///  - AUTOEXEC.BAT's chain is NON-contiguous and hits both entry parities
///    (2 → 7 → 4 → 9 → 3), so a wrong 12-bit unpack scrambles the walk order;
///  - the root directory leads with a volume label, an LFN entry whose 11
///    "name" bytes SPELL AUTOEXEC.BAT, and a deleted entry — all of which must
///    be skipped for the wrong reasons to stay wrong;
///  - a bystander file (OTHER.TXT) sits in the clusters BETWEEN the chain's
///    hops, so any off-target write corrupts it detectably.
///
/// `internal` on purpose: InstallMediaBuilderTests boots this same fixture as
/// the El Torito image inside its synthetic ISO.
struct FAT12FloppyFixture {
    static let sectorSize = 512
    static let fatSectors = 9
    static let rootEntryCount = 224
    static let fatOffset = sectorSize                              // 1 reserved sector
    static let fat2Offset = fatOffset + fatSectors * sectorSize
    static let rootOffset = (1 + 2 * fatSectors) * sectorSize      // 9728
    static let dataOffset = rootOffset + rootEntryCount * 32       // 16896; cluster 2

    /// Chains: AUTOEXEC.BAT fragmented across parities; OTHER.TXT and
    /// CONFIG.SYS in the gaps it jumps over; JO.SYS (the CD-boot chooser the
    /// builder renames) contiguous after them.
    static let autoexecChain = [2, 7, 4, 9, 3]
    static let otherChain = [5, 6]
    static let configChain = [8]
    static let joChain = [10, 11, 12, 13]

    static let autoexecSize = 2100          // 5 clusters hold 2560
    static let configContent = Data("device=himem.sys /testmem:off\r\nlastdrive=z\r\n".utf8)
    static let otherContent: Data = {
        var bytes = [UInt8]()
        for i in 0..<900 { bytes.append(UInt8(truncatingIfNeeded: i &* 37 &+ 11)) }
        return Data(bytes)
    }()
    static let joContent: Data = {
        var bytes = [UInt8]()
        for i in 0..<2048 { bytes.append(UInt8(truncatingIfNeeded: i &* 53 &+ 5)) }
        return Data(bytes)
    }()

    /// AUTOEXEC.BAT's original content, laid across `autoexecChain` in chain
    /// order — position-dependent bytes so a wrong-order walk can't cancel out.
    static let autoexecContent: Data = {
        var bytes = [UInt8]()
        for i in 0..<autoexecSize { bytes.append(UInt8(truncatingIfNeeded: i &* 131 &+ 7)) }
        return Data(bytes)
    }()

    static func clusterRange(_ cluster: Int) -> Range<Int> {
        (dataOffset + (cluster - 2) * sectorSize)..<(dataOffset + (cluster - 1) * sectorSize)
    }

    func build() -> Data {
        var image = Data(count: FAT12Floppy.imageBytes)

        // Boot sector: the BPB fields FAT12Floppy reads, plus the 55AA it checks.
        image[0] = 0xEB; image[1] = 0x3C; image[2] = 0x90
        Self.put(&image, 3, Data("MSWIN4.1".utf8))
        Self.putU16(&image, 0x0B, 512)
        image[0x0D] = 1                       // sectors per cluster
        Self.putU16(&image, 0x0E, 1)          // reserved
        image[0x10] = 2                       // FAT copies
        Self.putU16(&image, 0x11, Self.rootEntryCount)
        Self.putU16(&image, 0x13, 2880)       // total sectors (1.44 MB)
        image[0x15] = 0xF0                    // media descriptor: floppy
        Self.putU16(&image, 0x16, Self.fatSectors)
        Self.putU16(&image, 0x18, 18)         // sectors/track, heads: cosmetic
        Self.putU16(&image, 0x1A, 2)
        image[0x26] = 0x29
        Self.put(&image, 0x2B, Data("FIXTURE    ".utf8))
        Self.put(&image, 0x36, Data("FAT12   ".utf8))
        image[510] = 0x55; image[511] = 0xAA

        // FATs: media/EOC reserved entries, then the three chains — written
        // with an independent nibble-packer, into BOTH copies.
        var fat = [(0, 0xFF0), (1, 0xFFF)]
        for chain in [Self.autoexecChain, Self.otherChain, Self.configChain, Self.joChain] {
            for (i, cluster) in chain.enumerated() {
                fat.append((cluster, i + 1 < chain.count ? chain[i + 1] : 0xFFF))
            }
        }
        for (cluster, value) in fat {
            Self.setFAT12(&image, Self.fatOffset, cluster, value)
            Self.setFAT12(&image, Self.fat2Offset, cluster, value)
        }

        // Root directory: label + LFN decoy + deleted entry BEFORE the real
        // files, so the scanner has to skip all three kinds.
        var entries: [Data] = []
        entries.append(Self.dirEntry(name11: "FIXTURE    ", attributes: 0x08,
                                     firstCluster: 0, size: 0))
        entries.append(Self.dirEntry(name11: "AUTOEXECBAT", attributes: 0x0F, // LFN decoy
                                     firstCluster: 0, size: 0))
        var deleted = Self.dirEntry(name11: "GONE    TXT", attributes: 0x20,
                                    firstCluster: 5, size: 1)
        deleted[0] = 0xE5
        entries.append(deleted)
        entries.append(Self.dirEntry(name11: "AUTOEXECBAT", attributes: 0x20,
                                     firstCluster: Self.autoexecChain[0],
                                     size: Self.autoexecSize))
        entries.append(Self.dirEntry(name11: "CONFIG  SYS", attributes: 0x20,
                                     firstCluster: Self.configChain[0],
                                     size: Self.configContent.count))
        entries.append(Self.dirEntry(name11: "OTHER   TXT", attributes: 0x20,
                                     firstCluster: Self.otherChain[0],
                                     size: Self.otherContent.count))
        entries.append(Self.dirEntry(name11: "JO      SYS", attributes: 0x20,
                                     firstCluster: Self.joChain[0],
                                     size: Self.joContent.count))
        for (i, entry) in entries.enumerated() {
            Self.put(&image, Self.rootOffset + i * 32, entry)
        }

        // File content, cluster by cluster in chain order.
        Self.lay(&image, Self.autoexecContent, over: Self.autoexecChain)
        Self.lay(&image, Self.configContent, over: Self.configChain)
        Self.lay(&image, Self.otherContent, over: Self.otherChain)
        Self.lay(&image, Self.joContent, over: Self.joChain)
        return image
    }

    /// Reads a file's bytes back by chain + size — the tests' independent view.
    static func readFile(_ image: Data, chain: [Int], size: Int) -> Data {
        var out = Data()
        for cluster in chain {
            out += image[clusterRange(cluster)]
        }
        return out.prefix(size)
    }

    // MARK: byte-level helpers

    /// One 12-bit FAT entry, packed the FAT12 way: entry n starts at byte
    /// 3n/2; even n = low 12 bits of that u16, odd n = high 12 bits.
    static func setFAT12(_ image: inout Data, _ fatBase: Int, _ n: Int, _ value: Int) {
        let off = fatBase + 3 * n / 2
        if n % 2 == 0 {
            image[off] = UInt8(value & 0xFF)
            image[off + 1] = (image[off + 1] & 0xF0) | UInt8((value >> 8) & 0x0F)
        } else {
            image[off] = (image[off] & 0x0F) | UInt8((value & 0x0F) << 4)
            image[off + 1] = UInt8((value >> 4) & 0xFF)
        }
    }

    static func dirEntry(name11: String, attributes: UInt8, firstCluster: Int, size: Int) -> Data {
        precondition(name11.utf8.count == 11)
        var entry = Data(count: 32)
        put(&entry, 0, Data(name11.utf8))
        entry[11] = attributes
        putU16(&entry, 22, 0x6000)            // arbitrary fixed time/date
        putU16(&entry, 24, 0x5CE5)
        putU16(&entry, 26, firstCluster)
        putU16(&entry, 28, size & 0xFFFF)
        putU16(&entry, 30, (size >> 16) & 0xFFFF)
        return entry
    }

    static func lay(_ image: inout Data, _ content: Data, over chain: [Int]) {
        for (i, cluster) in chain.enumerated() {
            let slice = content.dropFirst(i * sectorSize).prefix(sectorSize)
            if slice.isEmpty { break }
            put(&image, clusterRange(cluster).lowerBound, Data(slice))
        }
    }

    static func put(_ image: inout Data, _ offset: Int, _ bytes: Data) {
        image.replaceSubrange(offset..<(offset + bytes.count), with: bytes)
    }

    static func putU16(_ image: inout Data, _ offset: Int, _ value: Int) {
        image[offset] = UInt8(value & 0xFF)
        image[offset + 1] = UInt8((value >> 8) & 0xFF)
    }
}

final class FAT12FloppyTests: XCTestCase {

    private let fixture = FAT12FloppyFixture().build()

    /// Deterministic replacement bytes, distinct from the fixture's pattern.
    private func replacement(_ count: Int) -> Data {
        var bytes = [UInt8]()
        for i in 0..<count { bytes.append(UInt8(truncatingIfNeeded: i &* 197 &+ 3)) }
        return Data(bytes)
    }

    // MARK: - The happy path

    func testReplaceWritesContentInChainOrderZeroPadsAndUpdatesSize() throws {
        var image = fixture
        let content = replacement(700) // spans clusters 2 (full) + 7 (partial)
        try FAT12Floppy.replaceRootFile(in: &image, name: "AUTOEXEC.BAT", content: content)

        // Content lands across the FRAGMENTED chain in chain order...
        XCTAssertEqual(FAT12FloppyFixture.readFile(image, chain: FAT12FloppyFixture.autoexecChain,
                                                   size: 700), content)
        // ...cluster 7's tail past byte 700 and ALL of trailing clusters 4, 9, 3
        // are zeroed (no stale bytes of the old 2100-byte content survive).
        let cluster7 = image[FAT12FloppyFixture.clusterRange(7)]
        XCTAssertTrue(cluster7.dropFirst(700 - 512).allSatisfy { $0 == 0 })
        for cluster in [4, 9, 3] {
            XCTAssertTrue(image[FAT12FloppyFixture.clusterRange(cluster)].allSatisfy { $0 == 0 },
                          "trailing cluster \(cluster) not zeroed")
        }
        // The directory entry's size field follows the new content.
        let entry = FAT12FloppyFixture.rootOffset + 3 * 32 // label, LFN, deleted, then this
        XCTAssertEqual(Int(image[entry + 28]) | Int(image[entry + 29]) << 8, 700)
        XCTAssertEqual(image[entry + 30], 0)
        XCTAssertEqual(image[entry + 31], 0)
    }

    func testReplaceTouchesNothingOutsideTheChainAndSizeField() throws {
        var image = fixture
        try FAT12Floppy.replaceRootFile(in: &image, name: "AUTOEXEC.BAT",
                                        content: replacement(700))

        // Both FAT copies byte-identical to before: in-place replace never
        // reallocates, so the FAT must be READ-only to it.
        let fatRegion = FAT12FloppyFixture.fatOffset..<FAT12FloppyFixture.rootOffset
        XCTAssertEqual(image[fatRegion], fixture[fatRegion])
        // Bystanders in the clusters BETWEEN the chain's hops are untouched.
        XCTAssertEqual(FAT12FloppyFixture.readFile(image, chain: FAT12FloppyFixture.otherChain,
                                                   size: FAT12FloppyFixture.otherContent.count),
                       FAT12FloppyFixture.otherContent)
        XCTAssertEqual(FAT12FloppyFixture.readFile(image, chain: FAT12FloppyFixture.configChain,
                                                   size: FAT12FloppyFixture.configContent.count),
                       FAT12FloppyFixture.configContent)
        // The strongest form: EVERY byte outside the chain's clusters and the
        // 4-byte size field is identical.
        var expected = fixture
        for cluster in FAT12FloppyFixture.autoexecChain {
            let range = FAT12FloppyFixture.clusterRange(cluster)
            expected.replaceSubrange(range, with: image[range])
        }
        let sizeField = FAT12FloppyFixture.rootOffset + 3 * 32 + 28
        expected.replaceSubrange(sizeField..<(sizeField + 4), with: image[sizeField..<(sizeField + 4)])
        XCTAssertEqual(image, expected)
    }

    func testReplaceAtExactChainCapacityFillsEveryCluster() throws {
        var image = fixture
        let capacity = FAT12FloppyFixture.autoexecChain.count * 512
        let content = replacement(capacity)
        try FAT12Floppy.replaceRootFile(in: &image, name: "AUTOEXEC.BAT", content: content)
        // Each cluster carries exactly its chain-order slice — this is the
        // odd/even 12-bit unpack test: entries 2/4 are even (low 12 bits),
        // 7/9/3 odd (high 12 bits); any parity mix-up reorders the hops.
        for (i, cluster) in FAT12FloppyFixture.autoexecChain.enumerated() {
            XCTAssertEqual(image[FAT12FloppyFixture.clusterRange(cluster)],
                           content[(i * 512)..<((i + 1) * 512)],
                           "cluster \(cluster) holds the wrong slice")
        }
    }

    // MARK: - Refusals

    func testContentBeyondChainCapacityThrows() {
        var image = fixture
        let capacity = FAT12FloppyFixture.autoexecChain.count * 512
        XCTAssertThrowsError(try FAT12Floppy.replaceRootFile(
            in: &image, name: "AUTOEXEC.BAT", content: replacement(capacity + 1))) { error in
            guard case FAT12Floppy.FloppyError.contentTooLarge(_, let size, let cap) = error else {
                return XCTFail("wrong error: \(error)")
            }
            XCTAssertEqual(size, capacity + 1)
            XCTAssertEqual(cap, capacity)
        }
        // A refused replace must leave the image byte-identical.
        XCTAssertEqual(image, fixture)
    }

    func testMissingFileThrows() {
        var image = fixture
        XCTAssertThrowsError(try FAT12Floppy.replaceRootFile(
            in: &image, name: "NOPE.TXT", content: Data("x".utf8))) { error in
            guard case FAT12Floppy.FloppyError.fileNotFound(let name) = error else {
                return XCTFail("wrong error: \(error)")
            }
            XCTAssertEqual(name, "NOPE.TXT")
        }
    }

    func testLFNDecoyAndDeletedEntryAreNotMatched() throws {
        // The fixture's LFN entry SPELLS AUTOEXEC.BAT in its name bytes and sits
        // FIRST; if attribute filtering were dropped, the scanner would match it
        // (firstCluster 0 → capacity 0) and this replace would throw. The
        // deleted GONE.TXT likewise must stay invisible.
        var image = fixture
        XCTAssertNoThrow(try FAT12Floppy.replaceRootFile(in: &image, name: "AUTOEXEC.BAT",
                                                         content: replacement(100)))
        XCTAssertThrowsError(try FAT12Floppy.replaceRootFile(in: &image, name: "GONE.TXT",
                                                             content: Data()))
    }

    func testWrongSizeImageThrows() {
        var tooSmall = Data(count: 720 * 1024)
        XCTAssertThrowsError(try FAT12Floppy.replaceRootFile(
            in: &tooSmall, name: "AUTOEXEC.BAT", content: Data())) { error in
            guard case FAT12Floppy.FloppyError.notAFloppyImage = error else {
                return XCTFail("wrong error: \(error)")
            }
        }
    }

    func testCorruptBPBIsRefused() {
        // sectors-per-cluster 0 breaks the power-of-two guard — representative
        // of the BPB sanity net (every geometry field is read, not assumed).
        var image = fixture
        image[0x0D] = 0
        XCTAssertThrowsError(try FAT12Floppy.replaceRootFile(
            in: &image, name: "AUTOEXEC.BAT", content: Data())) { error in
            guard case FAT12Floppy.FloppyError.notAFloppyImage = error else {
                return XCTFail("wrong error: \(error)")
            }
        }
    }

    // MARK: - Rename

    func testRenameRewritesOnlyTheNameBytes() throws {
        var image = fixture
        try FAT12Floppy.renameRootFile(in: &image, from: "JO.SYS", to: "JO.OFF")
        // The 11 name bytes changed; EVERY other byte of the image is
        // identical — content, chain, size, attributes, timestamps.
        let entry = FAT12FloppyFixture.rootOffset + 6 * 32 // 7th entry: JO.SYS
        XCTAssertEqual(Data(image[entry..<(entry + 11)]), Data("JO      OFF".utf8))
        var expected = fixture
        expected.replaceSubrange(entry..<(entry + 11), with: Data("JO      OFF".utf8))
        XCTAssertEqual(image, expected)
        // The old name resolves no more; the new one does (round-trip rename).
        XCTAssertThrowsError(try FAT12Floppy.replaceRootFile(in: &image, name: "JO.SYS",
                                                             content: Data()))
        XCTAssertNoThrow(try FAT12Floppy.renameRootFile(in: &image, from: "JO.OFF", to: "JO.SYS"))
        XCTAssertEqual(image, fixture)
    }

    func testRenameMissingSourceThrows() {
        var image = fixture
        XCTAssertThrowsError(try FAT12Floppy.renameRootFile(in: &image, from: "NOPE.SYS",
                                                            to: "ANY.SYS")) { error in
            guard case FAT12Floppy.FloppyError.fileNotFound(let name) = error else {
                return XCTFail("wrong error: \(error)")
            }
            XCTAssertEqual(name, "NOPE.SYS")
        }
    }

    func testRenameOntoExistingNameThrows() {
        var image = fixture
        XCTAssertThrowsError(try FAT12Floppy.renameRootFile(in: &image, from: "JO.SYS",
                                                            to: "OTHER.TXT")) { error in
            guard case FAT12Floppy.FloppyError.duplicateName(let name) = error else {
                return XCTFail("wrong error: \(error)")
            }
            XCTAssertEqual(name, "OTHER.TXT")
        }
        XCTAssertEqual(image, fixture) // refused rename leaves the image untouched
    }

    func testCorruptChainCycleThrows() {
        // Point AUTOEXEC.BAT's last cluster back at its first: the walk must
        // detect the cycle (chain longer than the volume has clusters) rather
        // than spin forever.
        var image = fixture
        FAT12FloppyFixture.setFAT12(&image, FAT12FloppyFixture.fatOffset, 3, 2)
        XCTAssertThrowsError(try FAT12Floppy.replaceRootFile(
            in: &image, name: "AUTOEXEC.BAT", content: Data("x".utf8))) { error in
            guard case FAT12Floppy.FloppyError.malformed(let why) = error else {
                return XCTFail("wrong error: \(error)")
            }
            XCTAssertTrue(why.contains("cycle"), why)
        }
    }
}
