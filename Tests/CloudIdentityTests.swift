import XCTest
@testable import PocketDOS

/// The pure, iCloud-independent pieces of the save-sync layer: the content-hash
/// identity and the size-cap gate. (The ubiquity-container plumbing itself needs a
/// real iCloud account + container and is verified on device, not here.)
final class CloudIdentityTests: XCTestCase {

    func testSizeCapGate() {
        XCTAssertTrue(CloudSaveSync.withinSizeCap(0))
        XCTAssertTrue(CloudSaveSync.withinSizeCap(CloudSaveSync.sizeCapBytes))
        XCTAssertFalse(CloudSaveSync.withinSizeCap(CloudSaveSync.sizeCapBytes + 1),
                       "saves over the cap (large Win9x deltas) must stay local")
    }

    func testSha256HexStableAndDistinct() throws {
        let dir = URL(fileURLWithPath: NSTemporaryDirectory()).appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: dir) }

        let a = dir.appendingPathComponent("a.bin")
        let b = dir.appendingPathComponent("b.bin")
        try Data(repeating: 0xAB, count: 4096).write(to: a)
        try Data(repeating: 0xCD, count: 4096).write(to: b)

        let ha1 = sha256Hex(ofFileAt: a)
        let ha2 = sha256Hex(ofFileAt: a)
        let hb = sha256Hex(ofFileAt: b)

        XCTAssertNotNil(ha1)
        XCTAssertEqual(ha1?.count, 64, "SHA256 hex is 64 chars")
        XCTAssertEqual(ha1, ha2, "same bytes → same identity (stable across devices/imports)")
        XCTAssertNotEqual(ha1, hb, "different bundles → different identity")
    }

    func testSha256HexNilForMissingFile() {
        XCTAssertNil(sha256Hex(ofFileAt: URL(fileURLWithPath: "/nope/\(UUID().uuidString).bin")))
    }
}
