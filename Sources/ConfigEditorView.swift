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
                    Text("These lines are appended to the game's dosbox.conf at launch and override it.\n\nMusic: tap “General MIDI” for rich SoundFont music — best for adventure/RPG games that offer a General MIDI / MPU-401 / Roland option in their setup. Or use AdLib / Sound Blaster for FM music; “Force FM music” hides the MIDI port so auto-detecting games fall back to FM.\n\nIf in-game sound cuts out after a moment, try the other Sound Blaster IRQ.")
                        .font(.footnote)
                        .foregroundStyle(.secondary)
                }

                Section("Sound Blaster IRQ") {
                    HStack {
                        Button("SB IRQ 5") { append("[sblaster]\nirq=5\n") }
                        Spacer()
                        Button("SB IRQ 7") { append("[sblaster]\nirq=7\n") }
                    }
                    .buttonStyle(.bordered)
                    .font(.footnote)
                }

                Section("Music") {
                    Button("Enable General MIDI (SoundFont)") {
                        // mididevice=synth renders FluidSynth into DOSBox's own mixer
                        // (the WASM-friendly path); the "fluidsynth" device opens a
                        // standalone OS audio driver that doesn't exist in the browser.
                        // midiconfig is the SoundFont path FluidSynth fopen()s on the
                        // HOST (Emscripten MEMFS), NOT a DOS C:\ path — the bundle is
                        // unpacked to /home/web_user, so that's where the injected .sf2 lives.
                        append("[midi]\nmpu401=intelligent\nmididevice=synth\nmidiconfig=/home/web_user/TIMGM6MB.SF2\n")
                    }
                    .buttonStyle(.borderedProminent)
                    .font(.footnote)
                    HStack {
                        Button("Force FM music") { append("[midi]\nmpu401=none\n") }
                        Spacer()
                        Button("FM only (mute digital)") { append("[sblaster]\nsbtype=none\noplmode=auto\n") }
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
