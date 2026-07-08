import XCTest
@testable import PocketDOS

/// Pure-helper coverage for the install wizard's product-key field. The
/// idempotence case is load-bearing: formatKey runs inside the TextField's
/// onChange, and its re-entrant call terminates only because a second pass
/// over already-formatted text is a no-op (formatted == raw short-circuits).
final class InstallWizardTests: XCTestCase {

    func testFormatKeyNormalizesCaseAndJunk() {
        // Dummy key-shaped fixture — NEVER a real product key in the repo.
        XCTAssertEqual(InstallWizardView.formatKey("abcde 12345!fghij_67890-kmnpq"),
                       "ABCDE-12345-FGHIJ-67890-KMNPQ")
    }

    func testFormatKeyIsIdempotent() {
        let once = InstallWizardView.formatKey("abcde12345fghij67890klmno")
        XCTAssertEqual(InstallWizardView.formatKey(once), once)
    }

    func testFormatKeyCapsAtTwentyFiveChars() {
        let long = String(repeating: "A", count: 40)
        let out = InstallWizardView.formatKey(long)
        XCTAssertEqual(out, "AAAAA-AAAAA-AAAAA-AAAAA-AAAAA")
    }

    func testFormatKeyDashPositionsNeverTrailing() {
        // Partial entry: dash appears after each full group, never dangling.
        XCTAssertEqual(InstallWizardView.formatKey("ABCDE"), "ABCDE")
        XCTAssertEqual(InstallWizardView.formatKey("ABCDEF"), "ABCDE-F")
        XCTAssertEqual(InstallWizardView.formatKey(""), "")
    }

    func testIsValidKeyAcceptsFormattedKey() {
        XCTAssertTrue(InstallWizardView.isValidKey("ABCDE-12345-FGHIJ-67890-KMNPQ"))
    }

    func testIsValidKeyRejectsShortOrUnformatted() {
        XCTAssertFalse(InstallWizardView.isValidKey("ABCDE-12345"))            // too few groups
        XCTAssertFalse(InstallWizardView.isValidKey("ABCDE12345FGHIJ67890KMNPQ")) // no dashes
        XCTAssertFalse(InstallWizardView.isValidKey("ABCDE-12345-FGHIJ-67890-KMNP")) // short group
        XCTAssertFalse(InstallWizardView.isValidKey(""))
    }
}
