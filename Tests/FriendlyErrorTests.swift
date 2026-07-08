import XCTest
@testable import PocketDOS

/// `friendlyEmulatorError` is the sole transform between a raw js-dos crash string
/// and the plain-English message shown to the user — pure, zero-setup to test.
final class FriendlyErrorTests: XCTestCase {
    func testDosboxConfNotFound() {
        XCTAssertTrue(friendlyEmulatorError("dosbox.conf not found").contains("js-dos game bundle"))
    }

    func testBrokenBundle() {
        XCTAssertTrue(friendlyEmulatorError("broken bundle").contains("js-dos game bundle"))
    }

    func testCompressionMethodNotSupported() {
        XCTAssertTrue(friendlyEmulatorError("compression method not supported").contains("standard ZIP"))
    }

    func testCrashMarker() {
        XCTAssertTrue(friendlyEmulatorError("__crash__").contains("stopped unexpectedly"))
    }

    func testOutOfMemory() {
        XCTAssertTrue(friendlyEmulatorError("out of memory").contains("stopped unexpectedly"))
    }

    func testCaseInsensitiveMatch() {
        XCTAssertTrue(friendlyEmulatorError("DOSBOX.CONF NOT FOUND").contains("js-dos game bundle"))
    }

    func testUnknownErrorPassesThrough() {
        let raw = "totally novel failure 0x42"
        XCTAssertTrue(friendlyEmulatorError(raw).contains(raw))
    }
}
