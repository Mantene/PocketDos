import XCTest
@testable import PocketDOS

/// Tests the two pure, security-relevant helpers in the custom scheme handler:
/// MIME mapping (the `wasm` case is load-bearing for the WebKit WASM JIT) and the
/// path-containment boundary that blocks traversal out of the served roots.
final class BundleSchemeHandlerTests: XCTestCase {

    // MARK: - MIME types

    func testMimeWasm() {
        XCTAssertEqual(BundleSchemeHandler.mimeType(forPathExtension: "wasm"), "application/wasm")
    }

    func testMimeWasmIsCaseInsensitive() {
        XCTAssertEqual(BundleSchemeHandler.mimeType(forPathExtension: "WASM"), "application/wasm")
    }

    func testMimeJavaScript() {
        XCTAssertEqual(BundleSchemeHandler.mimeType(forPathExtension: "js"), "text/javascript; charset=utf-8")
    }

    func testMimeJsdosAndZipAreZip() {
        XCTAssertEqual(BundleSchemeHandler.mimeType(forPathExtension: "jsdos"), "application/zip")
        XCTAssertEqual(BundleSchemeHandler.mimeType(forPathExtension: "zip"), "application/zip")
    }

    func testMimeUnknownIsNonEmpty() {
        XCTAssertFalse(BundleSchemeHandler.mimeType(forPathExtension: "zzznotreal").isEmpty)
    }

    // MARK: - Path containment (the A4 traversal boundary)

    func testContainsAcceptsChild() {
        let base = URL(fileURLWithPath: "/var/Games")
        XCTAssertTrue(BundleSchemeHandler.contains(base, base.appendingPathComponent("abc/game.jsdos")))
    }

    func testContainsAcceptsBaseItself() {
        let base = URL(fileURLWithPath: "/var/Games")
        XCTAssertTrue(BundleSchemeHandler.contains(base, base))
    }

    func testContainsRejectsSiblingSharingPrefix() {
        // The bug a plain `hasPrefix` would miss: "/var/Games" must NOT contain
        // "/var/GamesEvil/...".
        let base = URL(fileURLWithPath: "/var/Games")
        XCTAssertFalse(BundleSchemeHandler.contains(base, URL(fileURLWithPath: "/var/GamesEvil/loot")))
    }

    func testContainsRejectsParentEscape() {
        let base = URL(fileURLWithPath: "/var/Games")
        let escaped = base.appendingPathComponent("../Preferences/secrets").standardizedFileURL
        XCTAssertFalse(BundleSchemeHandler.contains(base, escaped))
    }
}
