import SwiftUI

/// Rudimentary per-game controller remap (SPEC F34): assign each face/shoulder/Menu
/// button to a DOS key or mouse click, choose which movement keys the D-pad/stick
/// emit (Arrows/WASD/Numpad — DOS games have no joystick channel in js-dos, so a
/// controller drives them via keys), and pick the cursor speed for Mouse-profile games.
struct ControllerSettingsView: View {
    let profile: ControlProfile
    let onSave: (_ map: [String: String], _ cursorSpeed: Int, _ directionScheme: String) -> Void

    @Environment(\.dismiss) private var dismiss
    @State private var map: [String: String]
    @State private var cursorSpeed: Int
    @State private var directionScheme: String

    init(profile: ControlProfile, map: [String: String], cursorSpeed: Int?, directionScheme: String?,
         onSave: @escaping (_ map: [String: String], _ cursorSpeed: Int, _ directionScheme: String) -> Void) {
        self.profile = profile
        self.onSave = onSave
        _map = State(initialValue: map)
        _cursorSpeed = State(initialValue: cursorSpeed ?? ControllerInput.defaultCursorSpeed)
        _directionScheme = State(initialValue: directionScheme ?? DirectionScheme.arrows.rawValue)
    }

    var body: some View {
        NavigationStack {
            Form {
                Section {
                    Text("Map the controller onto the game's own keyboard/mouse controls. The D-pad and left stick send the movement keys below; assign each button to a key or click.")
                        .font(.footnote)
                        .foregroundStyle(.secondary)
                }
                Section("Movement (D-pad & left stick)") {
                    Picker("Keys", selection: $directionScheme) {
                        ForEach(DirectionScheme.allCases) { scheme in
                            Text(scheme.label).tag(scheme.rawValue)
                        }
                    }
                    .pickerStyle(.segmented)
                }
                Section("Buttons") {
                    ForEach(PadButton.allCases) { button in
                        Picker(button.label, selection: binding(for: button)) {
                            ForEach(ControllerAction.choices, id: \.action.token) { choice in
                                Text(choice.label).tag(choice.action.token)
                            }
                        }
                    }
                }
                if profile == .mouse {
                    Section("Cursor speed") {
                        Picker("Cursor speed", selection: $cursorSpeed) {
                            Text("Slow").tag(ControllerInput.cursorSlow)
                            Text("Medium").tag(ControllerInput.cursorMedium)
                            Text("Fast").tag(ControllerInput.cursorFast)
                        }
                        .pickerStyle(.segmented)
                    }
                }
                Section("Presets") {
                    Button("Mouse clicks (A = left, B = right)") {
                        map = ["a": ControllerAction.leftClick.token,
                               "b": ControllerAction.rightClick.token]
                    }
                    Button("Action keys (A = Ctrl, B = Space, X = Alt, Y = Shift)") {
                        map = ["a": ControllerAction.key(DOSKey.ctrl).token,
                               "b": ControllerAction.key(DOSKey.space).token,
                               "x": ControllerAction.key(DOSKey.alt).token,
                               "y": ControllerAction.key(DOSKey.shift).token,
                               "menu": ControllerAction.key(DOSKey.esc).token]
                    }
                }
                Section {
                    Button("Reset to defaults", role: .destructive) {
                        map = [:]
                        cursorSpeed = ControllerInput.defaultCursorSpeed
                        directionScheme = DirectionScheme.arrows.rawValue
                    }
                }
            }
            .navigationTitle("Controller")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) { Button("Cancel") { dismiss() } }
                ToolbarItem(placement: .confirmationAction) {
                    Button("Save") { onSave(map, cursorSpeed, directionScheme); dismiss() }
                }
            }
        }
    }

    /// Picker binding for a button: shows the current override or the profile default,
    /// and stores only overrides (selecting the default clears the entry).
    private func binding(for button: PadButton) -> Binding<String> {
        Binding(
            get: { map[button.id] ?? ControllerInput.defaultAction(button, profile: profile).token },
            set: { token in
                if token == ControllerInput.defaultAction(button, profile: profile).token {
                    map[button.id] = nil
                } else {
                    map[button.id] = token
                }
            }
        )
    }
}
