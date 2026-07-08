import SwiftUI

/// About / licenses screen. PocketDOS is GPL-2 software built on js-dos and DOSBox-X
/// (also GPL-2). GPL-2 requires attribution AND that the corresponding source be
/// available — both are surfaced here so the obligation is met in-app. Presented via
/// the library's single `LibrarySheet` (a `.about` case), not a second sheet modifier.
struct AboutView: View {
    @Environment(\.dismiss) private var dismiss

    private var version: String {
        let v = Bundle.main.infoDictionary?["CFBundleShortVersionString"] as? String ?? "?"
        let b = Bundle.main.infoDictionary?["CFBundleVersion"] as? String ?? "?"
        return "Version \(v) (\(b))"
    }

    var body: some View {
        NavigationStack {
            List {
                Section {
                    VStack(spacing: 6) {
                        Image(systemName: "opticaldiscdrive")
                            .font(.system(size: 44))
                            .foregroundStyle(.secondary)
                        Text("PocketDOS").font(.title2.weight(.bold))
                        Text("A not-for-profit DOS & Windows 9x player for iOS.")
                            .font(.footnote).foregroundStyle(.secondary)
                            .multilineTextAlignment(.center)
                        Text(version).font(.caption2).foregroundStyle(.tertiary)
                    }
                    .frame(maxWidth: .infinity)
                    .padding(.vertical, 8)
                }

                Section("License") {
                    Text("PocketDOS is free software under the GNU General Public License, version 2 (GPL-2.0). It comes with ABSOLUTELY NO WARRANTY. You may redistribute it under the terms of the GPL.")
                        .font(.footnote)
                    Link("Read the GPL-2.0", destination: URL(string: "https://www.gnu.org/licenses/old-licenses/gpl-2.0.html")!)
                }

                Section("Built with") {
                    credit("js-dos", "DOSBox-X compiled to WebAssembly (GPL-2). © caiiiycuk.", "https://js-dos.com")
                    credit("DOSBox-X", "The DOS / Windows 9x emulator core (GPL-2).", "https://dosbox-x.com")
                    credit("FluidSynth", "General-MIDI SoundFont synthesis (LGPL-2.1).", "https://www.fluidsynth.org")
                    credit("munt / mt32emu", "Roland MT-32 emulation (LGPL-2.1).", "https://github.com/munt/munt")
                    credit("ZIPFoundation", "Zip reading/writing (MIT).", "https://github.com/weichsel/ZIPFoundation")
                    credit("TimGM6mb SoundFont", "Bundled General-MIDI SoundFont (GPL-2). © Tim Brechbill.", nil)
                }

                Section("Source code") {
                    Text("As the GPL requires, the complete source for PocketDOS — including the patches and build steps for the modified DOSBox-X WebAssembly — is publicly available.")
                        .font(.footnote)
                    Link("PocketDOS on GitHub", destination: URL(string: "https://github.com/Mantene/PocketDos")!)
                }

                Section {
                    Text("PocketDOS bundles no copyrighted ROMs, games, or operating systems. MT-32 ROMs, Windows, and any games you add are yours to own and license.")
                        .font(.caption).foregroundStyle(.secondary)
                }
            }
            .navigationTitle("About")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .confirmationAction) { Button("Done") { dismiss() } }
            }
        }
    }

    @ViewBuilder
    private func credit(_ name: String, _ desc: String, _ url: String?) -> some View {
        VStack(alignment: .leading, spacing: 2) {
            if let url, let u = URL(string: url) {
                Link(name, destination: u).font(.subheadline.weight(.semibold))
            } else {
                Text(name).font(.subheadline.weight(.semibold))
            }
            Text(desc).font(.caption).foregroundStyle(.secondary)
        }
    }
}
