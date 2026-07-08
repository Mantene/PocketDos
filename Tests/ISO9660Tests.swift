import XCTest
@testable import PocketDOS

/// Exercises the ISO9660 reader against a SYNTHETIC image assembled in memory —
/// never against anyone's real Windows CD (which must never enter the repo).
/// The fixture is deliberately shaped like a Win98 SE disc: PVD + El Torito boot
/// record + terminator, a \WIN98 directory whose records straddle a sector
/// boundary (the classic parser bug), and a 1.44 MB floppy-emulation boot image
/// with position-dependent markers so extraction proves the right RANGE was read,
/// not just the right length.
final class ISO9660Tests: XCTestCase {

    // MARK: - Fixture

    /// Builds a minimal-but-honest ISO9660 + El Torito image. Sector map:
    ///   16 PVD · 17 boot record · 18 terminator · 19 boot catalog · 20 root dir
    ///   21–22 WIN98 dir (two sectors) · 23 README.TXT · 24 SETUP.EXE · 25+ boot image
    private struct FixtureISO {
        var cabCount = 11
        var includeWIN98 = true
        var includeSetupEXE = true
        var corruptBootChecksum = false
        var bootIndicator: UInt8 = 0x88 // 0x00 → "not bootable" variant
        var bootMediaType: UInt8 = 0x02 // 0 = no-emulation, 4 = HDD variants
        var includeKeyBytes = true      // false → 55AA omitted (checksum stays valid)

        static let readmeContent = Data("Hello from the synthetic CD!\r\n".utf8)
        static let setupContent: Data = {
            var content = Data("MZ".utf8) // EXE magic, then filler
            content.append(Data(repeating: 0x90, count: 62))
            return content
        }()
        static let bootMarker = Data("POCKETDOS-BOOT-FIXTURE".utf8)
        static let bootMarkerOffset = 4096
        static let bootTail = Data("BOOT-IMAGE-TAIL".utf8)
        static let bootImageSize = 1_474_560

        static let catalogLBA = 19, rootLBA = 20, win98LBA = 21
        static let readmeLBA = 23, setupLBA = 24, bootLBA = 25

        func build() -> Data {
            var image = Data(count: 16 * 2048) // system area (sectors 0–15) is unused
            image += pvdSector()
            image += bootRecordSector()
            image += terminatorSector()
            image += catalogSector()
            image += Self.dirSector(rootRecords())
            image += win98Extent()
            image += Self.padded(Self.readmeContent)
            image += Self.padded(Self.setupContent)
            image += bootImage()
            return image
        }

        // MARK: Volume descriptors

        private func pvdSector() -> Data {
            var sector = Data(count: 2048)
            sector[0] = 1 // type: PVD
            Self.putASCII(&sector, 1, "CD001")
            sector[6] = 1 // version
            Self.putU16LE(&sector, 128, 2048) // logical block size, both-endian
            Self.putU16BE(&sector, 130, 2048)
            let root = Self.record(name: ".", lba: Self.rootLBA, size: 2048, isDirectory: true)
            sector.replaceSubrange(156..<(156 + root.count), with: root)
            return sector
        }

        private func bootRecordSector() -> Data {
            var sector = Data(count: 2048)
            sector[0] = 0 // type: boot record
            Self.putASCII(&sector, 1, "CD001")
            sector[6] = 1
            Self.putASCII(&sector, 7, "EL TORITO SPECIFICATION") // NUL padding pre-exists
            Self.putU32LE(&sector, 0x47, UInt32(Self.catalogLBA))
            return sector
        }

        private func terminatorSector() -> Data {
            var sector = Data(count: 2048)
            sector[0] = 255
            Self.putASCII(&sector, 1, "CD001")
            sector[6] = 1
            return sector
        }

        // MARK: El Torito catalog

        private func catalogSector() -> Data {
            var sector = Data(count: 2048)
            // Validation entry: header 01, platform 80x86, key bytes 55 AA, and a
            // checksum making all sixteen u16le words sum to 0 mod 0x10000.
            sector[0] = 0x01
            if includeKeyBytes {
                sector[0x1E] = 0x55
                sector[0x1F] = 0xAA
            }
            // Checksum is computed AFTER the variant tweaks above, so e.g. the
            // missing-key-bytes fixture still sums to zero — only the specific
            // guard under test can reject it (deleting that guard fails the test).
            var sum: UInt32 = 0
            for word in 0..<16 {
                sum &+= UInt32(UInt16(sector[word * 2]) | UInt16(sector[word * 2 + 1]) << 8)
            }
            Self.putU16LE(&sector, 0x1C, UInt16((0x10000 - (sum & 0xFFFF)) & 0xFFFF))
            if corruptBootChecksum {
                sector[0x1C] &+= 1 // one-off checksum → catalog must be rejected
            }
            // Initial/default entry (boot indicator and media type are variant
            // knobs, both OUTSIDE the checksummed validation entry).
            sector[32] = bootIndicator
            sector[33] = bootMediaType
            Self.putU16LE(&sector, 32 + 6, 1) // BIOS load count — deliberately NOT the size
            Self.putU32LE(&sector, 32 + 8, UInt32(Self.bootLBA))
            return sector
        }

        // MARK: Directories

        private func rootRecords() -> [Data] {
            var records = [
                Self.record(name: ".", lba: Self.rootLBA, size: 2048, isDirectory: true),
                Self.record(name: "..", lba: Self.rootLBA, size: 2048, isDirectory: true),
                Self.record(name: "README.TXT;1", lba: Self.readmeLBA,
                            size: Self.readmeContent.count, isDirectory: false),
            ]
            if includeWIN98 {
                records.append(Self.record(name: "WIN98", lba: Self.win98LBA,
                                           size: 2 * 2048, isDirectory: true))
            }
            return records
        }

        /// Two-sector WIN98 extent: a handful of records in sector one, zero fill,
        /// then the rest in sector two — records never span a sector boundary, so
        /// the reader must skip the padding, not stop at it.
        private func win98Extent() -> Data {
            guard includeWIN98 else { return Data(count: 2 * 2048) } // keep LBAs stable
            var first = [
                Self.record(name: ".", lba: Self.win98LBA, size: 2 * 2048, isDirectory: true),
                Self.record(name: "..", lba: Self.rootLBA, size: 2048, isDirectory: true),
            ]
            if includeSetupEXE {
                first.append(Self.record(name: "SETUP.EXE;1", lba: Self.setupLBA,
                                         size: Self.setupContent.count, isDirectory: false))
            }
            var second: [Data] = []
            for index in 1...max(cabCount, 1) where cabCount > 0 {
                // All CABs share the SETUP.EXE extent — legal in ISO9660 and keeps
                // the fixture small; the tests only care about names and counts.
                let record = Self.record(name: String(format: "BASE%02d.CAB;1", index),
                                         lba: Self.setupLBA,
                                         size: Self.setupContent.count, isDirectory: false)
                if first.count < 7 { first.append(record) } else { second.append(record) }
            }
            return Self.dirSector(first) + Self.dirSector(second)
        }

        // MARK: Boot image

        private func bootImage() -> Data {
            var image = Data(count: Self.bootImageSize)
            image[0] = 0xEB; image[1] = 0x3C; image[2] = 0x90 // x86 jump, like a real VBR
            Self.put(&image, 3, Data("MSDOS5.0".utf8)) // OEM label
            image[510] = 0x55; image[511] = 0xAA
            Self.put(&image, Self.bootMarkerOffset, Self.bootMarker)
            Self.put(&image, Self.bootImageSize - Self.bootTail.count, Self.bootTail)
            return image
        }

        // MARK: Byte-level builders

        /// One on-disc directory record. Both halves of the both-endian LBA/size
        /// fields are written, like a real mastering tool, so a reader that grabs
        /// the wrong half cannot accidentally pass.
        static func record(name: String, lba: Int, size: Int, isDirectory: Bool) -> Data {
            let nameBytes: [UInt8]
            switch name {
            case ".": nameBytes = [0x00]
            case "..": nameBytes = [0x01]
            default: nameBytes = Array(name.utf8)
            }
            // Records are padded to even length: one pad byte iff the name length is even.
            let length = 33 + nameBytes.count + (nameBytes.count % 2 == 0 ? 1 : 0)
            var record = Data(count: length)
            record[0] = UInt8(length)
            putU32LE(&record, 2, UInt32(lba)); putU32BE(&record, 6, UInt32(lba))
            putU32LE(&record, 10, UInt32(size)); putU32BE(&record, 14, UInt32(size))
            record[25] = isDirectory ? 0x02 : 0x00
            putU16LE(&record, 28, 1); putU16BE(&record, 30, 1) // volume sequence number
            record[32] = UInt8(nameBytes.count)
            record.replaceSubrange(33..<(33 + nameBytes.count), with: nameBytes)
            return record
        }

        /// Packs records into exactly one 2048-byte sector (zero-filled tail).
        static func dirSector(_ records: [Data]) -> Data {
            var sector = Data(count: 2048)
            var position = 0
            for record in records {
                precondition(position + record.count <= 2048, "fixture sector overflow")
                sector.replaceSubrange(position..<(position + record.count), with: record)
                position += record.count
            }
            return sector
        }

        static func padded(_ data: Data) -> Data {
            let remainder = data.count % 2048
            return remainder == 0 ? data : data + Data(count: 2048 - remainder)
        }

        static func put(_ data: inout Data, _ offset: Int, _ bytes: Data) {
            data.replaceSubrange(offset..<(offset + bytes.count), with: bytes)
        }

        static func putASCII(_ data: inout Data, _ offset: Int, _ string: String) {
            put(&data, offset, Data(string.utf8))
        }

        static func putU16LE(_ data: inout Data, _ offset: Int, _ value: UInt16) {
            data[offset] = UInt8(value & 0xFF)
            data[offset + 1] = UInt8(value >> 8)
        }

        static func putU16BE(_ data: inout Data, _ offset: Int, _ value: UInt16) {
            data[offset] = UInt8(value >> 8)
            data[offset + 1] = UInt8(value & 0xFF)
        }

        static func putU32LE(_ data: inout Data, _ offset: Int, _ value: UInt32) {
            putU16LE(&data, offset, UInt16(value & 0xFFFF))
            putU16LE(&data, offset + 2, UInt16(value >> 16))
        }

        static func putU32BE(_ data: inout Data, _ offset: Int, _ value: UInt32) {
            putU16BE(&data, offset, UInt16(value >> 16))
            putU16BE(&data, offset + 2, UInt16(value & 0xFFFF))
        }
    }

    /// The reader needs a real file (it reads via FileHandle), so fixtures land in
    /// the test sandbox's tmp and are removed when each test ends.
    private func writeImage(_ data: Data) throws -> URL {
        let url = FileManager.default.temporaryDirectory
            .appendingPathComponent("iso9660-fixture-\(UUID().uuidString).iso")
        try data.write(to: url)
        addTeardownBlock { try? FileManager.default.removeItem(at: url) }
        return url
    }

    private func openFixture(_ fixture: FixtureISO = FixtureISO()) throws -> ISO9660Image {
        try ISO9660Image(url: try writeImage(fixture.build()))
    }

    /// Corrupt-a-copy: builds `fixture`, lets `mutate` patch raw image bytes, then
    /// opens the result — so each negative test breaks exactly one format invariant.
    private func openMutated(_ fixture: FixtureISO = FixtureISO(),
                             mutate: (inout Data) -> Void) throws -> ISO9660Image {
        var data = fixture.build()
        mutate(&data)
        return try ISO9660Image(url: try writeImage(data))
    }

    /// Absolute image offset of the record whose ON-DISC name is `rawName` inside
    /// the directory sector at `lba` (fixture directories keep their patched
    /// records in the first sector). Lets corruption tests hit exact record fields
    /// without hardcoding record layouts that would rot if the fixture reorders.
    private func recordOffset(in image: Data, lba: Int, rawName: Data) -> Int {
        var pos = lba * 2048
        while image[pos] != 0 {
            let nameLength = Int(image[pos + 32])
            if Data(image[(pos + 33)..<(pos + 33 + nameLength)]) == rawName { return pos }
            pos += Int(image[pos])
        }
        XCTFail("record \(rawName as NSData) not found in fixture sector \(lba)")
        return 0
    }

    // MARK: - PVD validation

    func testGarbageImageThrows() throws {
        // Big enough to contain "sector 16", but no CD001 anywhere.
        let url = try writeImage(Data(repeating: 0xAB, count: 200 * 1024))
        XCTAssertThrowsError(try ISO9660Image(url: url)) { error in
            guard case ISO9660Image.ISOError.notISO9660 = error else {
                return XCTFail("wrong error: \(error)")
            }
        }
    }

    func testTinyFileThrows() throws {
        // Ends before sector 16 even exists.
        let url = try writeImage(Data(count: 1024))
        XCTAssertThrowsError(try ISO9660Image(url: url))
    }

    func testOpensSyntheticImage() throws {
        XCTAssertNoThrow(try openFixture())
    }

    // MARK: - Path resolution

    func testPathResolutionIsCaseInsensitiveAndStripsVersion() throws {
        let iso = try openFixture()
        XCTAssertTrue(iso.fileExists(atPath: "WIN98"))
        XCTAssertTrue(iso.fileExists(atPath: "WIN98/SETUP.EXE")) // stored as "SETUP.EXE;1"
        XCTAssertTrue(iso.fileExists(atPath: "win98/setup.exe"))
        XCTAssertTrue(iso.fileExists(atPath: "/WIN98/SETUP.EXE")) // leading slash tolerated
        XCTAssertTrue(iso.fileExists(atPath: "WIN98\\SETUP.EXE")) // DOS-style separator
        XCTAssertTrue(iso.fileExists(atPath: "readme.txt"))
        XCTAssertFalse(iso.fileExists(atPath: "WIN98/MISSING.EXE"))
        XCTAssertFalse(iso.fileExists(atPath: "NOPE/SETUP.EXE"))
        // A file used as a directory must not resolve.
        XCTAssertFalse(iso.fileExists(atPath: "README.TXT/ANYTHING"))
    }

    // MARK: - Directory listing

    func testListRoot() throws {
        let iso = try openFixture()
        let entries = try iso.list(directory: "")
        XCTAssertEqual(entries.count, 2) // "." and ".." are omitted
        XCTAssertTrue(entries.contains(ISO9660Image.Entry(name: "WIN98", isDirectory: true,
                                                          size: 2 * 2048)))
        // ";1" must be stripped from listed names.
        XCTAssertTrue(entries.contains(ISO9660Image.Entry(name: "README.TXT", isDirectory: false,
                                                          size: FixtureISO.readmeContent.count)))
    }

    func testListWIN98CrossesSectorBoundary() throws {
        let iso = try openFixture()
        let names = try iso.list(directory: "WIN98").map(\.name)
        XCTAssertEqual(names.count, 12) // SETUP.EXE + 11 CABs
        XCTAssertTrue(names.contains("SETUP.EXE"))
        // BASE05..11 live in the extent's SECOND sector, after zero padding —
        // seeing them proves the skip-to-next-sector rule works.
        XCTAssertTrue(names.contains("BASE05.CAB"))
        XCTAssertTrue(names.contains("BASE11.CAB"))
    }

    func testListOnFileThrows() throws {
        let iso = try openFixture()
        XCTAssertThrowsError(try iso.list(directory: "README.TXT")) { error in
            guard case ISO9660Image.ISOError.notADirectory = error else {
                return XCTFail("wrong error: \(error)")
            }
        }
    }

    // MARK: - File reading

    func testReadFileRoundTrip() throws {
        let iso = try openFixture()
        let data = try iso.readFile(atPath: "README.TXT", maxBytes: 1 << 20)
        XCTAssertEqual(data, FixtureISO.readmeContent)
        // Exact-limit read is allowed: the guard is "too large", not "this large".
        XCTAssertEqual(try iso.readFile(atPath: "README.TXT",
                                        maxBytes: FixtureISO.readmeContent.count),
                       FixtureISO.readmeContent)
    }

    func testReadFileEnforcesMaxBytes() throws {
        let iso = try openFixture()
        XCTAssertThrowsError(try iso.readFile(atPath: "README.TXT",
                                              maxBytes: FixtureISO.readmeContent.count - 1)) { error in
            guard case ISO9660Image.ISOError.fileTooLarge = error else {
                return XCTFail("wrong error: \(error)")
            }
        }
    }

    func testReadFileOnDirectoryThrows() throws {
        let iso = try openFixture()
        XCTAssertThrowsError(try iso.readFile(atPath: "WIN98", maxBytes: 1 << 20)) { error in
            guard case ISO9660Image.ISOError.notAFile = error else {
                return XCTFail("wrong error: \(error)")
            }
        }
    }

    func testReadFileRejectsNonPositiveMaxBytes() throws {
        // A zero/negative cap is a caller bug — it must fail loudly, not report
        // a nonsensical "over the -1-byte limit".
        let iso = try openFixture()
        for badLimit in [0, -1] {
            XCTAssertThrowsError(try iso.readFile(atPath: "README.TXT", maxBytes: badLimit)) { error in
                guard case ISO9660Image.ISOError.invalidArgument = error else {
                    return XCTFail("wrong error: \(error)")
                }
            }
        }
    }

    // MARK: - Win98 heuristic

    func testLooksLikeWin98CDOnFullFixture() throws {
        XCTAssertTrue(try openFixture().looksLikeWin98CD())
    }

    func testLooksLikeWin98CDNeedsTenCABs() throws {
        XCTAssertFalse(try openFixture(FixtureISO(cabCount: 9)).looksLikeWin98CD())
        XCTAssertTrue(try openFixture(FixtureISO(cabCount: 10)).looksLikeWin98CD())
    }

    func testLooksLikeWin98CDNeedsSetupAndDirectory() throws {
        XCTAssertFalse(try openFixture(FixtureISO(includeWIN98: false)).looksLikeWin98CD())
        XCTAssertFalse(try openFixture(FixtureISO(includeSetupEXE: false)).looksLikeWin98CD())
    }

    // MARK: - El Torito

    func testElToritoExtractsFullFloppyImage() throws {
        let image = try openFixture().extractElToritoBootImage()
        XCTAssertEqual(image.count, FixtureISO.bootImageSize) // implied by media type 2,
                                                              // NOT by the entry's sector count
        XCTAssertEqual(image[0], 0xEB) // x86 jump
        XCTAssertEqual(Data(image[3..<11]), Data("MSDOS5.0".utf8))
        XCTAssertEqual(image[510], 0x55)
        XCTAssertEqual(image[511], 0xAA)
        // Markers at a known interior offset AND the final bytes prove the whole
        // 1,474,560-byte range was read from the right starting sector.
        let markerRange = FixtureISO.bootMarkerOffset..<(FixtureISO.bootMarkerOffset + FixtureISO.bootMarker.count)
        XCTAssertEqual(Data(image[markerRange]), FixtureISO.bootMarker)
        XCTAssertEqual(Data(image.suffix(FixtureISO.bootTail.count)), FixtureISO.bootTail)
    }

    func testElToritoRejectsBadValidationChecksum() throws {
        let iso = try openFixture(FixtureISO(corruptBootChecksum: true))
        XCTAssertThrowsError(try iso.extractElToritoBootImage()) { error in
            guard case ISO9660Image.ISOError.badBootCatalog = error else {
                return XCTFail("wrong error: \(error)")
            }
        }
    }

    func testElToritoRejectsTruncatedBootImage() throws {
        var data = FixtureISO().build()
        data.removeLast(4096) // boot image now ends early
        let iso = try ISO9660Image(url: try writeImage(data))
        XCTAssertThrowsError(try iso.extractElToritoBootImage()) { error in
            guard case ISO9660Image.ISOError.truncated = error else {
                return XCTFail("wrong error: \(error)")
            }
        }
    }

    func testElToritoRejectsNotBootableEntry() throws {
        // 0x00 = "not bootable". The indicator lives OUTSIDE the checksummed
        // validation entry, so only the boot-indicator guard can reject this.
        let iso = try openFixture(FixtureISO(bootIndicator: 0x00))
        XCTAssertThrowsError(try iso.extractElToritoBootImage()) { error in
            guard case ISO9660Image.ISOError.badBootCatalog(let why) = error,
                  why.contains("not marked bootable") else {
                return XCTFail("wrong error: \(error)")
            }
        }
    }

    func testElToritoRejectsMissingKeyBytes() throws {
        // Key bytes are zeroed BEFORE the fixture computes its checksum, so the
        // words still sum clean — if the 55AA guard were deleted, validation
        // would pass and extraction would succeed, failing this test.
        let iso = try openFixture(FixtureISO(includeKeyBytes: false))
        XCTAssertThrowsError(try iso.extractElToritoBootImage()) { error in
            guard case ISO9660Image.ISOError.badBootCatalog(let why) = error,
                  why.contains("55AA") else {
                return XCTFail("wrong error: \(error)")
            }
        }
    }

    func testElToritoRejectsNoEmulationAndHDDMedia() throws {
        // Media types 0 (no-emulation) and 4 (HDD) are not floppy-bootable Win98
        // media; each must surface its own descriptive unsupported error.
        for badType: UInt8 in [0, 4] {
            let iso = try openFixture(FixtureISO(bootMediaType: badType))
            XCTAssertThrowsError(try iso.extractElToritoBootImage()) { error in
                guard case ISO9660Image.ISOError.unsupportedBootMedia(let type, _) = error else {
                    return XCTFail("wrong error: \(error)")
                }
                XCTAssertEqual(type, badType)
            }
        }
    }

    // MARK: - Corruption bounds guards (negative paths)
    //
    // Each test breaks exactly one on-disc invariant in a copy of the good
    // fixture and asserts the SPECIFIC error, so deleting any single bounds
    // guard in the parser makes at least one of these fail.

    func testShortDirectoryRecordThrows() throws {
        // Lengths 1–33 can't hold the 33-byte fixed header plus a name.
        let iso = try openMutated { image in
            let dot = self.recordOffset(in: image, lba: FixtureISO.rootLBA, rawName: Data([0x00]))
            image[dot] = 20
        }
        XCTAssertThrowsError(try iso.list(directory: "")) { error in
            guard case ISO9660Image.ISOError.malformed(let why) = error,
                  why.contains("too short") else {
                return XCTFail("wrong error: \(error)")
            }
        }
    }

    func testNameLengthOverrunningRecordThrows() throws {
        let iso = try openMutated { image in
            let dot = self.recordOffset(in: image, lba: FixtureISO.rootLBA, rawName: Data([0x00]))
            image[dot + 32] = 200 // name would extend far past the 34-byte record
        }
        XCTAssertThrowsError(try iso.list(directory: "")) { error in
            guard case ISO9660Image.ISOError.malformed(let why) = error,
                  why.contains("name overruns") else {
                return XCTFail("wrong error: \(error)")
            }
        }
    }

    func testRecordOverrunningExtentThrows() throws {
        // Shrink WIN98's dataLength to 40: the first record (34 B) fits, the
        // second one's 34 bytes cross the extent end — the reader must throw
        // rather than read past what the directory owns. (Only the LE half is
        // patched; the parser reads the LE half of both-endian fields.)
        let iso = try openMutated { image in
            let win98 = self.recordOffset(in: image, lba: FixtureISO.rootLBA,
                                          rawName: Data("WIN98".utf8))
            FixtureISO.putU32LE(&image, win98 + 10, 40)
        }
        XCTAssertThrowsError(try iso.list(directory: "WIN98")) { error in
            guard case ISO9660Image.ISOError.malformed(let why) = error,
                  why.contains("overruns its extent") else {
                return XCTFail("wrong error: \(error)")
            }
        }
    }

    func testDirectoryExtentOverCapThrows() throws {
        // A directory claiming 5 MiB is corruption, not a real Win98 directory.
        // The cap must fire BEFORE any read: the fixture is only ~1.5 MB, so if
        // the guard were deleted this would surface as `truncated` instead and
        // the malformed-case assertion below would fail.
        let iso = try openMutated { image in
            let win98 = self.recordOffset(in: image, lba: FixtureISO.rootLBA,
                                          rawName: Data("WIN98".utf8))
            FixtureISO.putU32LE(&image, win98 + 10, UInt32(5 << 20))
        }
        XCTAssertThrowsError(try iso.list(directory: "WIN98")) { error in
            guard case ISO9660Image.ISOError.malformed(let why) = error,
                  why.contains("extent claims") else {
                return XCTFail("wrong error: \(error)")
            }
        }
    }

    func testNon2048LogicalBlockSizeThrows() throws {
        // The whole reader assumes 2048-byte logical blocks; a PVD advertising
        // 512 must be rejected at open, not misparsed later.
        XCTAssertThrowsError(try openMutated { image in
            FixtureISO.putU16LE(&image, 16 * 2048 + 128, 512)
        }) { error in
            guard case ISO9660Image.ISOError.notISO9660 = error else {
                return XCTFail("wrong error: \(error)")
            }
        }
    }

    func testRootRecordNotDirectoryThrows() throws {
        // Clear the directory flag (+25, bit 1) on the PVD's root record: a root
        // that isn't a directory can't anchor path walks.
        XCTAssertThrowsError(try openMutated { image in
            image[16 * 2048 + 156 + 25] = 0x00
        }) { error in
            guard case ISO9660Image.ISOError.notISO9660 = error else {
                return XCTFail("wrong error: \(error)")
            }
        }
    }
}
