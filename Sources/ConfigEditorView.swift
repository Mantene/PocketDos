import SwiftUI

/// Per-game "Advanced DOS config": text appended to the bundle's dosbox.conf at
/// launch (overrides it, since DOSBox takes the last value). Main use: fix a
/// game's Sound Blaster IRQ so in-game audio doesn't stop after the first buffer.
struct ConfigEditorView: View {
    let game: Game
    let onSave: (String) -> Void

    @Environment(\.dismiss) private var dismiss
    @State private var text: String
    private let currentConf: String?

    init(game: Game, onSave: @escaping (String) -> Void) {
        self.game = game
        self.onSave = onSave
        _text = State(initialValue: game.configOverride ?? "")
        self.currentConf = currentDosboxConf(for: game)
    }

    var body: some View {
        NavigationStack {
            Form {
                Section {
                    Text("These lines are appended to the game's dosbox.conf at launch and override it. Common audio fix: set the Sound Blaster IRQ to match the game (try the other value if sound cuts out after a moment).")
                        .font(.footnote)
                        .foregroundStyle(.secondary)
                }

                Section("Quick fixes") {
                    HStack {
                        Button("SB IRQ 5") { append("[sblaster]\nirq=5\n") }
                        Spacer()
                        Button("SB IRQ 7") { append("[sblaster]\nirq=7\n") }
                        Spacer()
                        Button("AdLib only") { append("[sblaster]\nsbtype=none\noplmode=auto\n") }
                    }
                    .buttonStyle(.bordered)
                    .font(.footnote)
                }

                Section("Config override") {
                    TextEditor(text: $text)
                        .font(.system(.callout, design: .monospaced))
                        .frame(minHeight: 150)
                        .autocorrectionDisabled()
                        .textInputAutocapitalization(.never)
                }

                if let currentConf, !currentConf.isEmpty {
                    Section("Current dosbox.conf (read-only)") {
                        Text(currentConf)
                            .font(.system(.caption2, design: .monospaced))
                            .foregroundStyle(.secondary)
                            .textSelection(.enabled)
                    }
                }
            }
            .navigationTitle(game.title)
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("Cancel") { dismiss() }
                }
                ToolbarItem(placement: .confirmationAction) {
                    Button("Save") { onSave(text); dismiss() }
                }
            }
        }
    }

    private func append(_ snippet: String) {
        if !text.isEmpty && !text.hasSuffix("\n") { text += "\n" }
        text += snippet
    }
}
