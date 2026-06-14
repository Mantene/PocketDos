import SwiftUI

/// Shown when launching a raw-zip game that hasn't had a launch program chosen.
/// Lets the user pick which executable runs (or choose to just open a DOS prompt).
struct LaunchPickerView: View {
    let game: Game
    /// Called with the chosen command: "" = drop to DOS prompt, else the exe path.
    let onChoose: (String) -> Void
    @Environment(\.dismiss) private var dismiss

    var body: some View {
        NavigationStack {
            List {
                Section("Which program runs this game?") {
                    ForEach(game.executables, id: \.self) { exe in
                        Button {
                            onChoose(exe)
                        } label: {
                            Label(exe, systemImage: "terminal")
                                .foregroundStyle(.primary)
                        }
                    }
                }
                Section {
                    Button {
                        onChoose("")
                    } label: {
                        Label("Just open a DOS prompt", systemImage: "chevron.left.forwardslash.chevron.right")
                            .foregroundStyle(.primary)
                    }
                } footer: {
                    Text("You can change this later from a game's menu.")
                }
            }
            .navigationTitle("Set up \(game.title)")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("Cancel") { dismiss() }
                }
            }
        }
    }
}
