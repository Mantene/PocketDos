import XCTest
@testable import PocketDOS

/// The pure controller→DOS translation (the GameController wiring itself needs a
/// physical pad and is verified on device).
final class ControllerMapTests: XCTestCase {

    // MARK: stick → mouse (note: vertical is inverted — stick up = cursor up)

    func testStickToMouseCenterIsZero() {
        let (dx, dy) = ControllerMap.stickToMouse(x: 0, y: 0)
        XCTAssertEqual(dx, 0); XCTAssertEqual(dy, 0)
    }

    func testStickToMouseDeadzoneIsZero() {
        let (dx, dy) = ControllerMap.stickToMouse(x: 0.1, y: -0.1)   // inside 0.2 deadzone
        XCTAssertEqual(dx, 0); XCTAssertEqual(dy, 0)
    }

    func testStickToMouseFullRight() {
        let (dx, dy) = ControllerMap.stickToMouse(x: 1, y: 0)
        XCTAssertEqual(dx, Int(ControllerMap.mouseSpeed)); XCTAssertEqual(dy, 0)
    }

    func testStickToMouseUpIsNegativeY() {
        let (_, dy) = ControllerMap.stickToMouse(x: 0, y: 1)   // stick up → cursor up
        XCTAssertEqual(dy, -Int(ControllerMap.mouseSpeed))
    }

    func testStickToMouseDownIsPositiveY() {
        let (_, dy) = ControllerMap.stickToMouse(x: 0, y: -1)
        XCTAssertEqual(dy, Int(ControllerMap.mouseSpeed))
    }

    // MARK: stick → arrow keys (codes from DOSKey)

    func testStickToArrowsCenterEmpty() {
        XCTAssertTrue(ControllerMap.stickToArrows(x: 0, y: 0).isEmpty)
    }

    func testStickToArrowsDeadzoneEmpty() {
        XCTAssertTrue(ControllerMap.stickToArrows(x: 0.15, y: -0.15).isEmpty)
    }

    func testStickToArrowsCardinals() {
        XCTAssertEqual(ControllerMap.stickToArrows(x: 0.5, y: 0), [DOSKey.right])
        XCTAssertEqual(ControllerMap.stickToArrows(x: -0.5, y: 0), [DOSKey.left])
        XCTAssertEqual(ControllerMap.stickToArrows(x: 0, y: 0.5), [DOSKey.up])
        XCTAssertEqual(ControllerMap.stickToArrows(x: 0, y: -0.5), [DOSKey.down])
    }

    func testStickToArrowsDiagonal() {
        XCTAssertEqual(ControllerMap.stickToArrows(x: 0.9, y: 0.9), [DOSKey.right, DOSKey.up])
    }

    // MARK: movement schemes (the keyboard bridge for joystick-wanting games)

    func testStickToArrowsWASD() {
        let k = DirectionScheme.wasd.keys
        XCTAssertEqual(ControllerMap.stickToArrows(x: 0.9, y: 0.9, keys: k), [DOSKey.d, DOSKey.w])
        XCTAssertEqual(ControllerMap.stickToArrows(x: -0.5, y: -0.5, keys: k), [DOSKey.a, DOSKey.s])
    }

    func testStickToArrowsNumpad() {
        let k = DirectionScheme.numpad.keys
        XCTAssertEqual(ControllerMap.stickToArrows(x: 0.5, y: 0, keys: k), [DOSKey.kpRight])
        XCTAssertEqual(ControllerMap.stickToArrows(x: 0, y: 0.5, keys: k), [DOSKey.kpUp])
    }

    func testDirectionSchemeFromToken() {
        XCTAssertEqual(DirectionScheme(token: "wasd"), .wasd)
        XCTAssertEqual(DirectionScheme(token: "numpad"), .numpad)
        XCTAssertEqual(DirectionScheme(token: nil), .arrows)        // nil → arrows default
        XCTAssertEqual(DirectionScheme(token: "garbage"), .arrows)  // unknown → arrows
    }

    func testDirectionSchemeKeysDistinct() {
        // Each scheme must emit a different up-key, or the picker is pointless.
        let ups = Set([DirectionScheme.arrows, .wasd, .numpad].map { $0.keys.up })
        XCTAssertEqual(ups.count, 3)
    }
}
