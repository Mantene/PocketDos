import SwiftUI
import UniformTypeIdentifiers

/// "New Windows 98 machine" wizard (increment 1: requirements UI — ISO picker +
/// product-key entry + validation; the install engine lands in later increments).
///
/// LICENSING GROUND RULES (why this wizard exists at all): the app bundles ZERO
/// Microsoft content. The user supplies their own Windows 98 SE CD image and their
/// own product key. Everything derived from them (the D: CAB source, the extracted
/// boot floppy, the installed C: drive) stays in this app's Documents, on-device.
/// The only install assets we ship are license-clean: a blank formatted FAT32 disk
/// template (zeros + FAT structures) and DOSBox-X's GPL mouse-integration driver.
struct InstallWizardView: View {
    var onDone: () -> Void

    // The picked ISO. We keep a security-scoped BOOKMARK (not a copy): a Win98 CD
    // image is ~650 MB, and the install only needs to read \WIN98 out of it once,
    // at install time — duplicating it into our sandbox would double the footprint.
    @State private var isoURL: URL?
    @State private var isoBookmark: Data?
    @State private var isoSizeMB: Int = 0
    @State private var isoError: String?
    @State private var pickingISO = false

    // The product key, held in MEMORY ONLY. It is never logged and never persisted;
    // at install time (later increment) it is burned into the generated MSBATCH.INF
    // on the D: source image — the user's credential, applied to the user's media.
    @State private var productKey: String = ""

    var body: some View {
        NavigationStack {
            Form {
                Section {
                    Label {
                        Text("This creates a real, bootable Windows 98 machine you can play like any game. You provide the two things PocketDOS cannot ship: your own Windows 98 SE CD image (.iso) and your own product key.")
                    } icon: {
                        Image(systemName: "sparkles.tv")
                    }
                } header: {
                    Text("New Windows 98 machine")
                }

                Section {
                    Button {
                        pickingISO = true
                    } label: {
                        HStack {
                            Label(isoURL == nil ? "Choose CD image…" : (isoURL?.lastPathComponent ?? ""),
                                  systemImage: "opticaldisc")
                            Spacer()
                            if isoURL != nil {
                                Text("\(isoSizeMB) MB").foregroundStyle(.secondary)
                                Image(systemName: "checkmark.circle.fill").foregroundStyle(.green)
                            }
                        }
                    }
                    if let isoError {
                        Text(isoError).font(.footnote).foregroundStyle(.red)
                    }
                } header: {
                    Text("Windows 98 SE CD image")
                } footer: {
                    Text("A .iso of your own Windows 98 Second Edition CD. It is read once during install and never leaves this device.")
                }

                Section {
                    TextField("XXXXX-XXXXX-XXXXX-XXXXX-XXXXX", text: $productKey)
                        .font(.body.monospaced())
                        .textInputAutocapitalization(.characters)
                        .autocorrectionDisabled()
                        .keyboardType(.asciiCapable)
                        .onChange(of: productKey) { _, raw in
                            let formatted = Self.formatKey(raw)
                            if formatted != raw { productKey = formatted }
                        }
                    HStack {
                        Image(systemName: keyValid ? "checkmark.circle.fill" : "circle.dotted")
                            .foregroundStyle(keyValid ? .green : .secondary)
                        Text(keyValid ? "Key format looks valid" : "25 characters, letters and digits")
                            .font(.footnote).foregroundStyle(.secondary)
                    }
                } header: {
                    Text("Product key")
                } footer: {
                    Text("From your own Windows 98 license. Kept in memory only — never stored or sent anywhere.")
                }

                Section {
                    Button {
                        // Increment 1 stops here by design: requirements captured +
                        // validated. The install engine (media build → unattended
                        // Setup → mouse driver → final machine) is the next build.
                        onDone()
                    } label: {
                        Label("Install Windows 98", systemImage: "arrow.down.circle")
                            .frame(maxWidth: .infinity)
                    }
                    .disabled(true)
                } footer: {
                    Text("Installation is coming in the next build. Your selections above already validate, so this wizard will pick up right here.")
                }
            }
            .navigationTitle("Install Windows 98")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .topBarTrailing) {
                    Button("Done") { onDone() }
                }
            }
            .fileImporter(isPresented: $pickingISO,
                          allowedContentTypes: Self.isoTypes,
                          allowsMultipleSelection: false) { result in
                handlePickedISO(result)
            }
        }
    }

    // MARK: - ISO handling

    /// .iso is public.iso-image (conforms to disk-image); include the generic disk
    /// image type so Files providers that only report the parent type still match.
    static var isoTypes: [UTType] {
        var types: [UTType] = [.diskImage]
        if let iso = UTType(filenameExtension: "iso") { types.insert(iso, at: 0) }
        return types
    }

    private func handlePickedISO(_ result: Result<[URL], Error>) {
        isoError = nil
        guard case .success(let urls) = result, let url = urls.first else { return }
        let scoped = url.startAccessingSecurityScopedResource()
        defer { if scoped { url.stopAccessingSecurityScopedResource() } }

        let size = (try? url.resourceValues(forKeys: [.fileSizeKey]).fileSize) ?? 0
        // Sanity floor only (a full Win98 SE CD is ~650 MB, slimmed ISOs less):
        // real \WIN98\*.CAB validation arrives with the ISO9660 reader increment.
        guard size > 50 * 1024 * 1024 else {
            isoError = "That file is too small to be a Windows 98 CD image."
            isoURL = nil; isoBookmark = nil; isoSizeMB = 0
            return
        }
        // A FULL security-scoped bookmark (created while scoped access is held — the
        // ordering is load-bearing) keeps read access re-startable for the later, long
        // install step without copying the 650 MB image into our sandbox. Not
        // .minimalBookmark: minimal bookmarks are documented as fragile and can drop
        // the data third-party file providers (Dropbox etc.) need to re-resolve.
        // The bookmark IS the recovery vehicle, so its failure is a hard error —
        // a bare URL is not guaranteed re-startable after scoped access ends.
        guard let bookmark = try? url.bookmarkData() else {
            isoError = "Couldn't keep access to that file. Try copying it to On My iPhone and picking it again."
            isoURL = nil; isoBookmark = nil; isoSizeMB = 0
            return
        }
        isoBookmark = bookmark
        isoURL = url
        isoSizeMB = size / (1024 * 1024)
    }

    // MARK: - Product key

    private var keyValid: Bool { Self.isValidKey(productKey) }

    /// Win98 keys are 25 chars in 5 dash-joined groups. Normalize as the user types:
    /// uppercase, drop anything outside A–Z/0–9, cap at 25, re-insert dashes.
    static func formatKey(_ raw: String) -> String {
        let chars = raw.uppercased().unicodeScalars
            .filter { CharacterSet.alphanumerics.contains($0) && $0.isASCII }
            .prefix(25)
        var out = ""
        for (i, c) in chars.enumerated() {
            if i > 0 && i % 5 == 0 { out.append("-") }
            out.append(Character(c))
        }
        return out
    }

    static func isValidKey(_ key: String) -> Bool {
        let groups = key.split(separator: "-")
        return groups.count == 5 && groups.allSatisfy { $0.count == 5 }
    }
}
