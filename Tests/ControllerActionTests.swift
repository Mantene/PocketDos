import XCTest
@testable import PocketDOS

/// The remappable-action model: token round-trips (meta.json persistence) and the
/// per-profile button defaults.
final class ControllerActionTests: XCTestCase {

    func testTokenRoundTrip() {
        for action: ControllerAction in [.none, .leftClick, .rightClick, .key(DOSKey.ctrl), .key(DOSKey.esc), .key(258)] {
            XCTAssertEqual(ControllerAction(token: action.token), action)
        }
    }

    func testKeyTokenFormat() {
        XCTAssertEqual(ControllerAction.key(341).token, "k341")
        XCTAssertEqual(ControllerAction(token: "k341"), .key(341))
    }

    func testUnknownTokenIsNone() {
        XCTAssertEqual(ControllerAction(token: "garbage"), .none)
        XCTAssertEqual(ControllerAction(token: ""), .none)
    }

    func testEveryDefaultIsOfferedInChoices() {
        // The picker must contain each profile default, or it would render blank.
        let tokens = Set(ControllerAction.choices.map { $0.action.token })
        for profile in [ControlProfile.fps, .mouse, .off] {
            for button in PadButton.allCases {
                XCTAssertTrue(tokens.contains(ControllerInput.defaultAction(button, profile: profile).token),
                              "\(button) default under \(profile) missing from choices")
            }
        }
    }

    func testFaceButtonDefaultsByProfile() {
        XCTAssertEqual(ControllerInput.defaultAction(.a, profile: .fps), .key(DOSKey.ctrl))
        XCTAssertEqual(ControllerInput.defaultAction(.a, profile: .mouse), .leftClick)
        XCTAssertEqual(ControllerInput.defaultAction(.b, profile: .mouse), .rightClick)
        XCTAssertEqual(ControllerInput.defaultAction(.menu, profile: .fps), .key(DOSKey.esc))
        XCTAssertEqual(ControllerInput.defaultAction(.l1, profile: .fps), .none)
    }
}
