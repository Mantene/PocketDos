import Foundation
import GameController

/// A remappable controller action: a DOS key, a mouse click, or nothing.
enum ControllerAction: Equatable {
    case none
    case leftClick
    case rightClick
    case key(Int)

    /// Stable token for meta.json (`k<code>` for keys).
    var token: String {
        switch self {
        case .none: return "none"
        case .leftClick: return "lclick"
        case .rightClick: return "rclick"
        case .key(let code): return "k\(code)"
        }
    }

    init(token: String) {
        switch token {
        case "lclick": self = .leftClick
        case "rclick": self = .rightClick
        case "none", "": self = .none
        default:
            if token.hasPrefix("k"), let code = Int(token.dropFirst()) { self = .key(code) }
            else { self = .none }
        }
    }

    /// The curated set offered in the remap UI (token + human label).
    static let choices: [(action: ControllerAction, label: String)] = [
        (.none, "— None —"),
        (.leftClick, "Left click"),
        (.rightClick, "Right click"),
        (.key(DOSKey.ctrl), "Ctrl (fire)"),
        (.key(DOSKey.space), "Space (use)"),
        (.key(DOSKey.alt), "Alt (strafe)"),
        (.key(DOSKey.shift), "Shift (run)"),
        (.key(DOSKey.enter), "Enter"),
        (.key(DOSKey.esc), "Esc"),
        (.key(DOSKey.tab), "Tab"),
        (.key(DOSKey.n1), "1"),
        (.key(DOSKey.n2), "2"),
        (.key(DOSKey.n3), "3"),
        (.key(DOSKey.n4), "4"),
        (.key(DOSKey.n5), "5"),
    ]
}

/// The remappable physical buttons (D-pad and sticks stay profile-driven).
enum PadButton: String, CaseIterable, Identifiable {
    case a, b, x, y, l1, r1, menu
    var id: String { rawValue }
    var label: String {
        switch self {
        case .a: return "A"; case .b: return "B"; case .x: return "X"; case .y: return "Y"
        case .l1: return "L1"; case .r1: return "R1"; case .menu: return "Menu"
        }
    }
}

/// Which key-set the D-pad and left stick emit for movement. js-dos has no joystick
/// channel, so a controller drives DOS games via keys — and not every game uses arrows.
enum DirectionScheme: String, CaseIterable, Identifiable {
    case arrows, wasd, numpad
    var id: String { rawValue }
    var label: String {
        switch self {
        case .arrows: return "Arrows"
        case .wasd:   return "WASD"
        case .numpad: return "Numpad"
        }
    }
    /// (up, down, left, right) DOS key codes for this scheme.
    var keys: (up: Int, down: Int, left: Int, right: Int) {
        switch self {
        case .arrows: return (DOSKey.up, DOSKey.down, DOSKey.left, DOSKey.right)
        case .wasd:   return (DOSKey.w, DOSKey.s, DOSKey.a, DOSKey.d)
        case .numpad: return (DOSKey.kpUp, DOSKey.kpDown, DOSKey.kpLeft, DOSKey.kpRight)
        }
    }
    /// Unknown/nil token → arrows (the safe default).
    init(token: String?) { self = DirectionScheme(rawValue: token ?? "") ?? .arrows }
}

/// Pure controller→DOS mapping (no GameController/UI deps) so it's unit-testable.
enum ControllerMap {
    static let deadzone: Float = 0.2
    static let mouseSpeed: Float = 12   // default px/frame at full deflection

    /// Thumbstick → relative cursor delta. yAxis is +1 up; screen Y grows down → invert.
    static func stickToMouse(x: Float, y: Float, speed: Float = mouseSpeed) -> (dx: Int, dy: Int) {
        let dx = abs(x) < deadzone ? 0 : Int((x * speed).rounded())
        let dy = abs(y) < deadzone ? 0 : Int((y * speed).rounded())
        return (dx, -dy)
    }

    /// Thumbstick → the set of movement-key codes currently "pressed" (FPS profile).
    /// `k` is the scheme's (up,down,left,right) codes; defaults to arrows.
    static func stickToArrows(x: Float, y: Float,
                              keys k: (up: Int, down: Int, left: Int, right: Int)
                                  = (DOSKey.up, DOSKey.down, DOSKey.left, DOSKey.right)) -> Set<Int> {
        var keys = Set<Int>()
        if x > deadzone { keys.insert(k.right) } else if x < -deadzone { keys.insert(k.left) }
        if y > deadzone { keys.insert(k.up) } else if y < -deadzone { keys.insert(k.down) }
        return keys
    }
}

/// Bridges an MFi/Bluetooth game controller to the running emulator (SPEC F34).
/// Face/shoulder/Menu buttons use the per-game remap (`map`, falling back to
/// profile defaults); D-pad → arrows and left stick → cursor(.mouse)/arrows(.fps)
/// are profile-driven. Buttons are event-driven; the stick is polled at 60 Hz and
/// emits only while deflected.
@MainActor
final class ControllerInput {
    static let cursorSlow = 5, cursorMedium = 9, cursorFast = 14
    static let defaultCursorSpeed = cursorMedium

    /// Default action for a button under a profile (used when the user hasn't remapped it).
    /// Pure (reads only its args + compile-time key constants) → `nonisolated` so non-main-actor
    /// callers (e.g. unit tests) can use it; main-actor callers like `resolve()` are unaffected.
    nonisolated static func defaultAction(_ button: PadButton, profile: ControlProfile) -> ControllerAction {
        switch button {
        case .a:    return profile == .mouse ? .leftClick  : .key(DOSKey.ctrl)
        case .b:    return profile == .mouse ? .rightClick : .key(DOSKey.space)
        case .x:    return .key(DOSKey.alt)
        case .y:    return .key(DOSKey.shift)
        case .l1:   return .none
        case .r1:   return .none
        case .menu: return .key(DOSKey.esc)
        }
    }

    private weak var emulator: EmulatorController?
    private var profile: ControlProfile
    private var map: [String: String]          // button id → action token (overrides only)
    private var cursorSpeed: Int
    private var directionScheme: DirectionScheme
    private var connectObs: NSObjectProtocol?
    private var disconnectObs: NSObjectProtocol?
    private var pollTimer: Timer?
    private var heldStickKeys: Set<Int> = []

    init(emulator: EmulatorController, profile: ControlProfile,
         map: [String: String], cursorSpeed: Int?, directionScheme: String?) {
        self.emulator = emulator
        self.profile = profile
        self.map = map
        self.cursorSpeed = cursorSpeed ?? Self.defaultCursorSpeed
        self.directionScheme = DirectionScheme(token: directionScheme)
    }

    func start() {
        let nc = NotificationCenter.default
        connectObs = nc.addObserver(forName: .GCControllerDidConnect, object: nil, queue: .main) { [weak self] note in
            guard let self, let c = note.object as? GCController else { return }
            MainActor.assumeIsolated { self.attach(c) }
        }
        disconnectObs = nc.addObserver(forName: .GCControllerDidDisconnect, object: nil, queue: .main) { [weak self] _ in
            MainActor.assumeIsolated { self?.releaseHeld() }
        }
        GCController.controllers().forEach(attach)
        GCController.startWirelessControllerDiscovery {}
    }

    /// Apply edited settings live (from the remap sheet or a profile change).
    func setMapping(profile: ControlProfile, map: [String: String], cursorSpeed: Int?,
                    directionScheme: String?) {
        releaseHeld()
        self.profile = profile
        self.map = map
        self.cursorSpeed = cursorSpeed ?? Self.defaultCursorSpeed
        self.directionScheme = DirectionScheme(token: directionScheme)
        // Re-wire buttons so handlers capture the new mapping.
        GCController.controllers().forEach { if let pad = $0.extendedGamepad { wireButtons(pad) } }
    }

    func stop() {
        if let connectObs { NotificationCenter.default.removeObserver(connectObs) }
        if let disconnectObs { NotificationCenter.default.removeObserver(disconnectObs) }
        connectObs = nil
        disconnectObs = nil
        pollTimer?.invalidate()
        pollTimer = nil
        releaseHeld()
    }

    // MARK: - Wiring

    private func attach(_ controller: GCController) {
        guard let pad = controller.extendedGamepad else { return }
        emulator?.noteControllerConnected()
        wireButtons(pad)
        startPolling()
    }

    private func wireButtons(_ pad: GCExtendedGamepad) {
        // D-pad sends the chosen movement key-set (arrows by default).
        let dk = directionScheme.keys
        pad.dpad.up.pressedChangedHandler    = { [weak self] _, _, p in self?.key(dk.up, p) }
        pad.dpad.down.pressedChangedHandler  = { [weak self] _, _, p in self?.key(dk.down, p) }
        pad.dpad.left.pressedChangedHandler  = { [weak self] _, _, p in self?.key(dk.left, p) }
        pad.dpad.right.pressedChangedHandler = { [weak self] _, _, p in self?.key(dk.right, p) }
        // Remappable buttons.
        pad.buttonA.pressedChangedHandler        = { [weak self] _, _, p in self?.fire(.a, p) }
        pad.buttonB.pressedChangedHandler        = { [weak self] _, _, p in self?.fire(.b, p) }
        pad.buttonX.pressedChangedHandler        = { [weak self] _, _, p in self?.fire(.x, p) }
        pad.buttonY.pressedChangedHandler        = { [weak self] _, _, p in self?.fire(.y, p) }
        pad.leftShoulder.pressedChangedHandler   = { [weak self] _, _, p in self?.fire(.l1, p) }
        pad.rightShoulder.pressedChangedHandler  = { [weak self] _, _, p in self?.fire(.r1, p) }
        pad.buttonMenu.pressedChangedHandler     = { [weak self] _, _, p in self?.fire(.menu, p) }
    }

    private func startPolling() {
        guard pollTimer == nil else { return }
        // 60 Hz: responsive cursor; emits only while the stick is deflected.
        pollTimer = Timer.scheduledTimer(withTimeInterval: 1.0 / 60.0, repeats: true) { [weak self] _ in
            MainActor.assumeIsolated { self?.poll() }
        }
    }

    private func poll() {
        guard let stick = (GCController.current ?? GCController.controllers().first)?
            .extendedGamepad?.leftThumbstick else { return }
        let x = stick.xAxis.value, y = stick.yAxis.value
        switch profile {
        case .mouse:
            let (dx, dy) = ControllerMap.stickToMouse(x: x, y: y, speed: Float(cursorSpeed))
            if dx != 0 || dy != 0 { emulator?.mouseMoveRelative(dx: dx, dy: dy) }
        case .fps, .off:
            updateStickKeys(ControllerMap.stickToArrows(x: x, y: y, keys: directionScheme.keys))
        }
    }

    // MARK: - Input emission

    private func resolve(_ button: PadButton) -> ControllerAction {
        if let token = map[button.id] { return ControllerAction(token: token) }
        return Self.defaultAction(button, profile: profile)
    }

    /// Apply a remappable button's resolved action on press/release.
    private func fire(_ button: PadButton, _ pressed: Bool) {
        switch resolve(button) {
        case .none: break
        case .leftClick: emulator?.mouseButton(0, pressed: pressed)
        case .rightClick: emulator?.mouseButton(1, pressed: pressed)
        case .key(let code): key(code, pressed)
        }
    }

    private func key(_ code: Int, _ pressed: Bool) {
        pressed ? emulator?.keyDown(code) : emulator?.keyUp(code)
    }

    private func updateStickKeys(_ desired: Set<Int>) {
        for code in desired.subtracting(heldStickKeys) { emulator?.keyDown(code) }
        for code in heldStickKeys.subtracting(desired) { emulator?.keyUp(code) }
        heldStickKeys = desired
    }

    private func releaseHeld() {
        for code in heldStickKeys { emulator?.keyUp(code) }
        heldStickKeys.removeAll()
    }
}
