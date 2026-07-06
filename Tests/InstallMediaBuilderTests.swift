import XCTest
import ZIPFoundation
@testable import PocketDOS

/// End-to-end coverage of the install-media pipeline against SYNTHETIC inputs
/// only: a minimal Win98-shaped ISO whose El Torito boot image is the
/// FAT12FloppyFixture (so the floppy patch can be verified cluster-by-cluster
/// with independent layout knowledge), plus a tiny blank-target template zip.
/// No byte of anyone's real Windows CD or product key enters the repo — the
/// key fixture is the all-As dummy.
final class InstallMediaBuilderTests: XCTestCase {

    private static let dummyKey = "AAAAA-AAAAA-AAAAA-AAAAA-AAAAA"

    // MARK: - Synthetic Win98 ISO (FixtureISO's little sibling)

    /// Sector map: 16 PVD · 17 El Torito boot record · 18 terminator ·
    /// 19 boot catalog · 20 root dir · 21 WIN98 dir · 22 SETUP.EXE/CAB extent ·
    /// 23+ the FAT12 boot floppy (720 CD sectors).
    private struct MiniWin98ISO {
        var cabCount = 10
        let bootImage: Data

        static let catalogLBA = 19, rootLBA = 20, win98LBA = 21, setupLBA = 22, bootLBA = 23
        static let setupContent = Data("MZ-fixture".utf8)

        func build() -> Data {
            var image = Data(count: 16 * 2048)
            image += pvdSector()
            image += bootRecordSector()
            image += terminatorSector()
            image += catalogSector()
            image += Self.dirSector([
                Self.record(name: ".", lba: Self.rootLBA, size: 2048, isDirectory: true),
                Self.record(name: "..", lba: Self.rootLBA, size: 2048, isDirectory: true),
                Self.record(name: "WIN98", lba: Self.win98LBA, size: 2048, isDirectory: true),
            ])
            var win98 = [
                Self.record(name: ".", lba: Self.win98LBA, size: 2048, isDirectory: true),
                Self.record(name: "..", lba: Self.rootLBA, size: 2048, isDirectory: true),
                Self.record(name: "SETUP.EXE;1", lba: Self.setupLBA,
                            size: Self.setupContent.count, isDirectory: false),
            ]
            for index in 0..<cabCount {
                // CABs share SETUP.EXE's extent — legal, and keeps the ISO tiny.
                win98.append(Self.record(name: String(format: "BASE%02d.CAB;1", index + 1),
                                         lba: Self.setupLBA,
                                         size: Self.setupContent.count, isDirectory: false))
            }
            image += Self.dirSector(win98)
            var setup = Self.setupContent
            setup += Data(count: 2048 - setup.count)
            image += setup
            precondition(bootImage.count == 1_474_560)
            image += bootImage
            return image
        }

        private func pvdSector() -> Data {
            var sector = Data(count: 2048)
            sector[0] = 1
            Self.put(&sector, 1, Data("CD001".utf8))
            sector[6] = 1
            Self.putU16LE(&sector, 128, 2048)
            Self.putU16BE(&sector, 130, 2048)
            let root = Self.record(name: ".", lba: Self.rootLBA, size: 2048, isDirectory: true)
            sector.replaceSubrange(156..<(156 + root.count), with: root)
            return sector
        }

        private func bootRecordSector() -> Data {
            var sector = Data(count: 2048)
            sector[0] = 0
            Self.put(&sector, 1, Data("CD001".utf8))
            sector[6] = 1
            Self.put(&sector, 7, Data("EL TORITO SPECIFICATION".utf8))
            Self.putU32LE(&sector, 0x47, UInt32(Self.catalogLBA))
            return sector
        }

        private func terminatorSector() -> Data {
            var sector = Data(count: 2048)
            sector[0] = 255
            Self.put(&sector, 1, Data("CD001".utf8))
            sector[6] = 1
            return sector
        }

        private func catalogSector() -> Data {
            var sector = Data(count: 2048)
            sector[0] = 0x01
            sector[0x1E] = 0x55
            sector[0x1F] = 0xAA
            var sum: UInt32 = 0
            for word in 0..<16 {
                sum &+= UInt32(UInt16(sector[word * 2]) | UInt16(sector[word * 2 + 1]) << 8)
            }
            Self.putU16LE(&sector, 0x1C, UInt16((0x10000 - (sum & 0xFFFF)) & 0xFFFF))
            sector[32] = 0x88
            sector[33] = 0x02 // 1.44 MB floppy emulation
            Self.putU16LE(&sector, 32 + 6, 1)
            Self.putU32LE(&sector, 32 + 8, UInt32(Self.bootLBA))
            return sector
        }

        static func record(name: String, lba: Int, size: Int, isDirectory: Bool) -> Data {
            let nameBytes: [UInt8]
            switch name {
            case ".": nameBytes = [0x00]
            case "..": nameBytes = [0x01]
            default: nameBytes = Array(name.utf8)
            }
            let length = 33 + nameBytes.count + (nameBytes.count % 2 == 0 ? 1 : 0)
            var record = Data(count: length)
            record[0] = UInt8(length)
            putU32LE(&record, 2, UInt32(lba)); putU32BE(&record, 6, UInt32(lba))
            putU32LE(&record, 10, UInt32(size)); putU32BE(&record, 14, UInt32(size))
            record[25] = isDirectory ? 0x02 : 0x00
            putU16LE(&record, 28, 1); putU16BE(&record, 30, 1)
            record[32] = UInt8(nameBytes.count)
            record.replaceSubrange(33..<(33 + nameBytes.count), with: nameBytes)
            return record
        }

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

        static func put(_ data: inout Data, _ offset: Int, _ bytes: Data) {
            data.replaceSubrange(offset..<(offset + bytes.count), with: bytes)
        }
        static func putU16LE(_ data: inout Data, _ offset: Int, _ value: UInt16) {
            data[offset] = UInt8(value & 0xFF); data[offset + 1] = UInt8(value >> 8)
        }
        static func putU16BE(_ data: inout Data, _ offset: Int, _ value: UInt16) {
            data[offset] = UInt8(value >> 8); data[offset + 1] = UInt8(value & 0xFF)
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

    // MARK: - Fixture plumbing

    private func makeTempDir() throws -> URL {
        let url = FileManager.default.temporaryDirectory
            .appendingPathComponent("install-media-tests-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
        addTeardownBlock { try? FileManager.default.removeItem(at: url) }
        return url
    }

    private func writeISO(cabCount: Int = 10, in dir: URL) throws -> URL {
        let url = dir.appendingPathComponent("fixture.iso")
        try MiniWin98ISO(cabCount: cabCount, bootImage: FAT12FloppyFixture().build())
            .build().write(to: url)
        return url
    }

    private static let templateRaw = Data(repeating: 0xAB, count: 4096)
    private static let templateMetaj = Data(#"{"name":"fat32-2gb","size":2097152}"#.utf8)

    /// A miniature win98-blank-c.zip: same drive/ top-level folder shape.
    private func writeTemplateZip(in dir: URL, includeMetaj: Bool = true) throws -> URL {
        let url = dir.appendingPathComponent(includeMetaj ? "template.zip" : "template-broken.zip")
        let archive = try Archive(url: url, accessMode: .create)
        let raw = Self.templateRaw
        try archive.addEntry(with: "drive/0.raw", type: .file,
                             uncompressedSize: Int64(raw.count),
                             compressionMethod: .deflate) { position, size in
            let start = Int(position)
            return raw.subdata(in: start..<min(start + size, raw.count))
        }
        if includeMetaj {
            let metaj = Self.templateMetaj
            try archive.addEntry(with: "drive/sockdrive.metaj", type: .file,
                                 uncompressedSize: Int64(metaj.count),
                                 compressionMethod: .deflate) { position, size in
                let start = Int(position)
                return metaj.subdata(in: start..<min(start + size, metaj.count))
            }
        }
        return url
    }

    // MARK: - The pipeline

    func testBuildProducesCompleteInstallMediaTree() throws {
        let dir = try makeTempDir()
        let dest = dir.appendingPathComponent("game")
        var seen: [InstallMediaBuilder.Progress] = []
        try InstallMediaBuilder.build(isoAt: try writeISO(in: dir), productKey: Self.dummyKey,
                                      into: dest,
                                      blankTargetTemplate: try writeTemplateZip(in: dir)) {
            seen.append($0)
        }

        // --- boot-floppy.zip: exactly one entry, `boot.img`, patched in place.
        let archive = try Archive(url: dest.appendingPathComponent("boot-floppy.zip"),
                                  accessMode: .read)
        let entries = archive.map { $0 }
        XCTAssertEqual(entries.map(\.path), ["boot.img"])
        var floppy = Data()
        _ = try archive.extract(entries[0]) { floppy.append($0) }
        XCTAssertEqual(floppy.count, 1_474_560)

        // AUTOEXEC.BAT: the unattended content, laid over the fixture's known
        // fragmented chain, with the explicit-INF Setup line; size updated.
        let autoexec = InstallMediaBuilder.unattendedAutoexec
        XCTAssertEqual(FAT12FloppyFixture.readFile(floppy, chain: FAT12FloppyFixture.autoexecChain,
                                                   size: autoexec.count), autoexec)
        let autoexecText = String(decoding: autoexec, as: UTF8.self)
        XCTAssertTrue(autoexecText.contains("D:\\WIN98\\SETUP.EXE D:\\MSBATCH.INF /IS\r\n"))
        XCTAssertFalse(autoexecText.contains("setramd"),
                       "EBD ramdrive plumbing must not be on the CDBOOT floppy")
        let entry = FAT12FloppyFixture.rootOffset + 3 * 32
        XCTAssertEqual(Int(floppy[entry + 28]) | Int(floppy[entry + 29]) << 8, autoexec.count)

        // CONFIG.SYS: menu-free replacement; boot sector untouched.
        let config = InstallMediaBuilder.menulessConfigSys
        XCTAssertEqual(FAT12FloppyFixture.readFile(floppy, chain: FAT12FloppyFixture.configChain,
                                                   size: config.count), config)
        XCTAssertFalse(String(decoding: config, as: UTF8.self).contains("[menu]"))
        let fixtureFloppy = FAT12FloppyFixture().build()
        XCTAssertEqual(floppy[0..<512], fixtureFloppy[0..<512])

        // JO.SYS — the CD-boot chooser whose hard-disk default crashes the
        // guest — is renamed out of IO.SYS's sight, content intact.
        let joEntry = FAT12FloppyFixture.rootOffset + 6 * 32
        XCTAssertEqual(Data(floppy[joEntry..<(joEntry + 11)]), Data("JO      OFF".utf8))
        XCTAssertEqual(FAT12FloppyFixture.readFile(floppy, chain: FAT12FloppyFixture.joChain,
                                                   size: FAT12FloppyFixture.joContent.count),
                       FAT12FloppyFixture.joContent)

        // --- src-drive/drive: a chunked fat16-256m sockdrive with a manifest.
        let metajURL = dest.appendingPathComponent("src-drive/drive/sockdrive.metaj")
        let manifest = try JSONDecoder().decode(SockdriveChunker.Metaj.self,
                                                from: Data(contentsOf: metajURL))
        XCTAssertEqual(manifest.name, "fat16-256m")
        XCTAssertEqual(manifest.range_count, 963) // 246456 KiB / 256 KiB, rounded up
        XCTAssertTrue(FileManager.default.fileExists(
            atPath: dest.appendingPathComponent("src-drive/drive/0.raw").path),
            "the MBR range must exist as a chunk")
        // The temp raw image must not survive the build.
        XCTAssertFalse(FileManager.default.fileExists(
            atPath: dest.appendingPathComponent("src-drive.tmp.raw").path))

        // --- target-drive/drive: the template, unpacked verbatim.
        XCTAssertEqual(try Data(contentsOf: dest.appendingPathComponent("target-drive/drive/0.raw")),
                       Self.templateRaw)
        XCTAssertEqual(try Data(contentsOf: dest.appendingPathComponent("target-drive/drive/sockdrive.metaj")),
                       Self.templateMetaj)

        // --- progress: floppy first, then a monotonic source percentage to
        // 100, then chunking, then done last.
        XCTAssertEqual(seen.first, .floppyReady)
        XCTAssertEqual(seen.last, .done)
        let percents: [Int] = seen.compactMap {
            if case .buildingSource(let p) = $0 { return p } else { return nil }
        }
        XCTAssertEqual(percents.last, 100)
        XCTAssertEqual(percents, percents.sorted(), "source progress must not go backwards")
        XCTAssertNotNil(seen.firstIndex(of: .chunking))
    }

    func testBuildRejectsNonWin98ISO() throws {
        let dir = try makeTempDir()
        XCTAssertThrowsError(try InstallMediaBuilder.build(
            isoAt: try writeISO(cabCount: 3, in: dir), productKey: Self.dummyKey,
            into: dir.appendingPathComponent("game"),
            blankTargetTemplate: try writeTemplateZip(in: dir))) { error in
            XCTAssertEqual(error as? InstallMediaBuilder.BuildError, .notAWin98CD)
        }
    }

    func testBuildRejectsTemplateWithoutManifest() throws {
        let dir = try makeTempDir()
        XCTAssertThrowsError(try InstallMediaBuilder.build(
            isoAt: try writeISO(in: dir), productKey: Self.dummyKey,
            into: dir.appendingPathComponent("game"),
            blankTargetTemplate: try writeTemplateZip(in: dir, includeMetaj: false))) { error in
            guard case InstallMediaBuilder.BuildError.templateInvalid = error else {
                return XCTFail("wrong error: \(error)")
            }
        }
    }
}
