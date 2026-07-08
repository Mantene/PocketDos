import SwiftUI
import UIKit
import UniformTypeIdentifiers

/// Which modal sheet the library is presenting (single sheet avoids SwiftUI's
/// multiple-.sheet conflicts).
enum LibrarySheet: Identifiable {
    case launchPicker(Game)
    case config(Game)
    case about
    case installWizard
    var id: String {
        switch self {
        case .launchPicker(let g): return "p" + g.id
        case .config(let g): return "c" + g.id
        case .about: return "about"
        case .installWizard: return "wizard"
        }
    }
}

/// Root screen: a cover-art grid of imported games + an importer.
struct LibraryView: View {
    @StateObject private var store = GameStore()
    /// ONE WebView/WebContent process reused for every game launch (iOS won't reap a
    /// dismissed WebView's process for this app, so per-game WebViews leaked until OOM).
    @StateObject private var sharedEmulator = SharedEmulator()
    @State private var importing = false
    @State private var importError: String?
    @State private var playingGame: Game?
    @State private var sheet: LibrarySheet?
    @State private var showMT32Importer = false
    @State private var mt32Target: Game?

    private let columns = [GridItem(.adaptive(minimum: 110), spacing: 16)]

    var body: some View {
        NavigationStack {
            Group {
                if store.games.isEmpty {
                    emptyState
                } else {
                    ScrollView {
                        LazyVGrid(columns: columns, spacing: 16) {
                            ForEach(store.games) { game in
                                Button {
                                    launch(game)
                                } label: {
                                    GameTile(game: game)
                                }
                                .buttonStyle(.plain)
                                .contextMenu {
                                    if game.isZip {
                                        Button {
                                            sheet = .launchPicker(game)
                                        } label: {
                                            Label("Set launch program", systemImage: "terminal")
                                        }
                                    }
                                    Menu {
                                        Button("Auto") { store.setMemory(nil, for: game) }
                                        ForEach([16, 32, 48, 64, 128, 256], id: \.self) { mb in
                                            Button("\(mb) MB") { store.setMemory(mb, for: game) }
                                        }
                                    } label: {
                                        Label("Emulated memory", systemImage: "memorychip")
                                    }
                                    Button {
                                        sheet = .config(game)
                                    } label: {
                                        Label("DOS config…", systemImage: "slider.horizontal.3")
                                    }
                                    if game.isZip {
                                        Button {
                                            mt32Target = game
                                            showMT32Importer = true
                                        } label: {
                                            Label("Import MT-32 ROMs…", systemImage: "pianokeys")
                                        }
                                    }
                                    if game.hasMT32ROMs {
                                        Button(role: .destructive) {
                                            store.removeMT32ROMs(game)
                                        } label: {
                                            Label("Remove MT-32 ROMs", systemImage: "pianokeys.inverse")
                                        }
                                    }
                                    if game.hasSavedSession {
                                        Button {
                                            store.clearSave(game)
                                        } label: {
                                            Label("Reset saved session", systemImage: "arrow.counterclockwise")
                                        }
                                    }
                                    Button(role: .destructive) {
                                        store.delete(game)
                                    } label: {
                                        Label("Delete", systemImage: "trash")
                                    }
                                }
                            }
                        }
                        .padding()
                    }
                }
            }
            .navigationTitle("PocketDOS")
            .toolbar {
                ToolbarItem(placement: .topBarTrailing) {
                    // One "+" menu: import a ready-made game, or build a Windows 98
                    // machine from the user's own CD image (the install wizard).
                    Menu {
                        Button {
                            importing = true
                        } label: {
                            Label("Import game…", systemImage: "square.and.arrow.down")
                        }
                        Button {
                            sheet = .installWizard
                        } label: {
                            Label("New Windows 98 machine (Experimental)…", systemImage: "opticaldisc")
                        }
                    } label: {
                        Label("Add", systemImage: "plus")
                    }
                }
                ToolbarItem(placement: .topBarLeading) {
                    Button { sheet = .about } label: { Label("About", systemImage: "info.circle") }
                }
                #if DEBUG
                // Sockdrive boot-speed spike: routes the shared emulator to
                // index.html?sockspike=… (Win9x booting from Web/drive/ chunks). Reuses
                // the real EmulatorView nav so the teardown/relaunch path is exercised too.
                ToolbarItem(placement: .topBarLeading) {
                    Button { playingGame = Game.sockSpike } label: {
                        Label("sockdrive spike", systemImage: "ladybug")
                    }
                }
                // Sockdrive WRITE-LOAD OOM spike: boots the DOS floppy onto the sockdrive
                // and writes ~398 MB to C: to find the in-heap write-set ceiling (the
                // make-or-break for an on-device install wizard).
                ToolbarItem(placement: .topBarLeading) {
                    Button { playingGame = Game.writeSpike } label: {
                        Label("write spike", systemImage: "square.and.arrow.down.on.square")
                    }
                }
                #endif
            }
            .navigationDestination(item: $playingGame) { game in
                EmulatorView(game: game, store: store, shared: sharedEmulator)
            }
            .sheet(item: $sheet) { which in
                switch which {
                case .launchPicker(let game):
                    LaunchPickerView(game: game) { choice in
                        store.setRunCommand(choice, for: game)
                        sheet = nil
                        // Launch with the freshly chosen command.
                        playingGame = store.game(byId: game.id)
                    }
                case .config(let game):
                    ConfigEditorView(game: game) { text in
                        store.setConfigOverride(text, for: game)
                        sheet = nil
                    }
                case .about:
                    AboutView()
                case .installWizard:
                    // The wizard drives the SAME shared WebView/process the games
                    // use (the app never creates a second WebContent process).
                    InstallWizardView(store: store, shared: sharedEmulator) { sheet = nil }
                }
            }
            .fileImporter(isPresented: $importing,
                          allowedContentTypes: GameStore.importTypes,
                          allowsMultipleSelection: true) { result in
                handleImport(result)
            }
            // The MT-32 ROM importer lives on a SEPARATE (clear) background host: TWO
            // `.fileImporter` modifiers on the same view conflict (only one presents) —
            // that left the main "Import a game" picker dead on iPad. Isolating this one
            // frees the main importer.
            .background {
                Color.clear.fileImporter(isPresented: $showMT32Importer,
                              allowedContentTypes: [.zip, .data],
                              allowsMultipleSelection: true) { result in
                    let game = mt32Target
                    mt32Target = nil
                    guard let game else { return }
                    switch result {
                    case .success(let urls):
                        do { try store.importMT32ROMs(for: game, from: urls) }
                        catch { importError = error.localizedDescription }
                    case .failure(let error):
                        importError = error.localizedDescription
                    }
                }
            }
            .alert("Import failed",
                   isPresented: Binding(get: { importError != nil },
                                        set: { if !$0 { importError = nil } })) {
                Button("OK", role: .cancel) { importError = nil }
            } message: {
                Text(importError ?? "")
            }
            // "Open in PocketDOS" from Files / share sheet → import (a second path,
            // independent of the in-app picker). onOpenURL is an event modifier, not a
            // presentation, so it doesn't add to the modifier-stacking problem above.
            .onOpenURL { url in handleOpenedFile(url) }
            #if DEBUG
            // Headless smoke hook: launch with `-pdos-sockspike` (e.g. via
            // `simctl launch … -pdos-sockspike 1`) to auto-enter the sockdrive boot-speed
            // spike with no tap — so the mount + dosbox-x path can be validated from CLI.
            .task {
                let args = ProcessInfo.processInfo.arguments
                if args.contains("-pdos-sockspike") {
                    playingGame = Game.sockSpike
                } else if args.contains("-pdos-writespike") {
                    playingGame = Game.writeSpike
                }
            }
            #endif
        }
    }

    private var emptyState: some View {
        VStack(spacing: 16) {
            Image(systemName: "opticaldiscdrive")
                .font(.system(size: 56))
                .foregroundStyle(.secondary)
            Text("No games yet")
                .font(.title2.weight(.semibold))
            Text("Tap + to import a .jsdos or .zip game from Files.\nUse freeware/shareware — don't add copyrighted games.")
                .font(.subheadline)
                .foregroundStyle(.secondary)
                .multilineTextAlignment(.center)
            Button {
                importing = true
            } label: {
                Label("Import a game", systemImage: "plus")
                    .padding(.horizontal, 8)
            }
            .buttonStyle(.borderedProminent)
        }
        .padding(32)
    }

    private func launch(_ game: Game) {
        if game.needsLaunchSetup {
            sheet = .launchPicker(game)   // ask which program to run first
        } else {
            playingGame = game
        }
    }

    private func handleImport(_ result: Result<[URL], Error>) {
        switch result {
        case .success(let urls):
            for url in urls {
                do { try store.importGame(from: url) }
                catch { importError = error.localizedDescription }
            }
        case .failure(let error):
            importError = error.localizedDescription
        }
    }

    /// A file opened via "Open in PocketDOS" (Files / share sheet). importGame handles
    /// the security-scoped resource access for an out-of-sandbox URL.
    private func handleOpenedFile(_ url: URL) {
        do { try store.importGame(from: url) }
        catch { importError = error.localizedDescription }
    }
}

/// A single library tile (placeholder cover + title).
struct GameTile: View {
    let game: Game

    var body: some View {
        VStack(spacing: 8) {
            RoundedRectangle(cornerRadius: 12, style: .continuous)
                .fill(LinearGradient(colors: [.indigo, .black],
                                     startPoint: .topLeading, endPoint: .bottomTrailing))
                .aspectRatio(3.0 / 4.0, contentMode: .fit)
                .overlay {
                    Image(systemName: "gamecontroller.fill")
                        .font(.system(size: 30))
                        .foregroundStyle(.white.opacity(0.85))
                }
            Text(game.title)
                .font(.caption)
                .lineLimit(2)
                .multilineTextAlignment(.center)
                .foregroundStyle(.primary)
        }
    }
}

/// Full-screen play surface for one game (native chrome around the WebView).
struct EmulatorView: View {
    let game: Game
    let store: GameStore
    @Environment(\.dismiss) private var dismiss
    @Environment(\.scenePhase) private var scenePhase
    let shared: SharedEmulator
    private var controller: EmulatorController { shared.controller }
    @State private var showMenu = false
    @State private var profile: ControlProfile
    /// MFi/Bluetooth controller bridge (created on appear; mapping follows `profile`).
    @State private var pads: ControllerInput?
    @State private var controllerMap: [String: String]
    @State private var cursorSpeed: Int?
    @State private var directionScheme: String?
    @State private var showControllerSettings = false

    init(game: Game, store: GameStore, shared: SharedEmulator) {
        self.game = game
        self.store = store
        self.shared = shared
        _profile = State(initialValue: game.controlProfile)
        _controllerMap = State(initialValue: game.controllerMap)
        _cursorSpeed = State(initialValue: game.cursorSpeed)
        _directionScheme = State(initialValue: game.directionScheme)
    }

    var body: some View {
        EmulatorWebView(shared: shared)
            .ignoresSafeArea()
            .background(Color.black)
            .navigationBarBackButtonHidden(true)
            .toolbar(.hidden, for: .navigationBar)
            .onAppear {
                // Sockdrive games persist a sector-diff to sockdrive-write.bin; normal games
                // persist a whole-FS delta to changes.jsdos. cloudPushSave keys on
                // changes.jsdos, so it naturally no-ops for sockdrive (iCloud deferred to a
                // later increment — sector-diff sizes vs the 20 MB cap need measuring first).
                controller.saveURL = game.isSockdrive ? game.sockdriveWriteFileURL : game.saveFileURL
                controller.isSockdrivePersist = game.isSockdrive
                controller.onPersisted = { store.cloudPushSave(for: game) }
                // Large disk-image games (Win9x) run ephemerally: persisting the whole-FS
                // delta OOM-crashes the WebContent process. Disable persist and drop any
                // stale (unusable, over-cap) save so it stops wasting space.
                controller.persistEnabled = game.isPersistable
                if !game.isPersistable { try? FileManager.default.removeItem(at: game.saveFileURL) }
                shared.play(game)   // reset the shared controller + navigate the one WebView to this game
                setLandscapeLock(true)
                controller.startAutosave()
                let input = ControllerInput(emulator: controller, profile: profile,
                                            map: controllerMap, cursorSpeed: cursorSpeed,
                                            directionScheme: directionScheme)
                input.start()
                pads = input
            }
            .onDisappear {
                setLandscapeLock(false)
                controller.stopAutosave()
                pads?.stop()
                pads = nil
                shared.leave()   // blank.html (same-origin) — frees the page, KEEPS the reused process
            }
            .onChange(of: scenePhase) { _, phase in
                // Save when the app is about to leave the foreground. Fire on
                // .inactive (not .background): once backgrounded the WebContent
                // JS is suspended before the async persist round-trip can run.
                if phase == .inactive { controller.persistNow(isBackground: true) }
            }
            .overlay(alignment: .topLeading) { backButton }
            .overlay(alignment: .topTrailing) { menuButton }
            .overlay(alignment: .top) { saveToast }
            .animation(.easeInOut(duration: 0.2), value: controller.saveStatus)
            .overlay(alignment: .bottomLeading) {
                if profile == .fps {
                    DPad(controller: controller)
                        .padding(.leading, 16).padding(.bottom, 28)
                }
            }
            .overlay(alignment: .bottomTrailing) {
                if profile == .fps {
                    ActionCluster(controller: controller)
                        .padding(.trailing, 16).padding(.bottom, 28)
                } else if profile == .mouse {
                    MouseControls(controller: controller)
                        .padding(.trailing, 16).padding(.bottom, 28)
                }
            }
            .confirmationDialog("Game menu", isPresented: $showMenu, titleVisibility: .visible) {
                Button("Controls: FPS pad") { setProfile(.fps) }
                Button("Controls: Mouse (tap to click)") { setProfile(.mouse) }
                Button("Controls: Off") { setProfile(.off) }
                Button("Controller buttons…") { showControllerSettings = true }
                Button(controller.isPaused ? "Resume" : "Pause") { controller.togglePause() }
                Button("Save now") { controller.persistNow() }
                Button("Restart") { controller.restart() }
                Button("Quit to Library", role: .destructive) { quit() }
                Button("Cancel", role: .cancel) {}
            }
            .alert("Couldn't run this game",
                   isPresented: Binding(get: { controller.loadError != nil },
                                        set: { if !$0 { controller.loadError = nil } })) {
                Button("Back to Library") { dismiss() }
            } message: {
                Text(friendlyEmulatorError(controller.loadError ?? ""))
            }
            .sheet(isPresented: $showControllerSettings) {
                ControllerSettingsView(profile: profile, map: controllerMap, cursorSpeed: cursorSpeed,
                                       directionScheme: directionScheme) { newMap, newSpeed, newDir in
                    controllerMap = newMap
                    cursorSpeed = newSpeed
                    directionScheme = newDir
                    store.setControllerMapping(newMap, cursorSpeed: newSpeed, directionScheme: newDir, for: game)
                    pads?.setMapping(profile: profile, map: newMap, cursorSpeed: newSpeed, directionScheme: newDir)
                }
            }
    }

    private func setProfile(_ newProfile: ControlProfile) {
        profile = newProfile
        writeControlProfile(newProfile, for: game)
        // Controller mapping follows the chosen profile (defaults differ per profile).
        pads?.setMapping(profile: newProfile, map: controllerMap, cursorSpeed: cursorSpeed,
                         directionScheme: directionScheme)
    }

    /// Save the session, then leave. Dismiss in the persist completion so the
    /// WebView stays alive long enough to flush; a timeout guards against a stall.
    private func quit() {
        // Dismiss when the save completes (not on a fixed race), so we don't return
        // to the library before a large Win9x delta finishes writing. The timeout is
        // only a safety valve against a hung engine, generous enough not to trip on a
        // legitimately slow save.
        var done = false
        let leave = { if !done { done = true; dismiss() } }
        controller.persistNow(isBackground: true) { leave() }
        DispatchQueue.main.asyncAfter(deadline: .now() + 8) { leave() }
    }

    /// Lock gameplay to landscape (the library stays free to rotate). Backed by
    /// AppDelegate.lockLandscape, which feeds supportedInterfaceOrientationsFor.
    private func setLandscapeLock(_ on: Bool) {
        AppDelegate.lockLandscape = on
        guard let scene = UIApplication.shared.connectedScenes
            .first(where: { $0.activationState == .foregroundActive }) as? UIWindowScene else { return }
        if on {
            scene.requestGeometryUpdate(.iOS(interfaceOrientations: .landscapeRight))
        }
        scene.keyWindow?.rootViewController?.setNeedsUpdateOfSupportedInterfaceOrientations()
    }

    private var backButton: some View {
        Button {
            dismiss()
        } label: {
            Image(systemName: "chevron.backward.circle.fill")
                .font(.title)
                .symbolRenderingMode(.hierarchical)
                .foregroundStyle(.white)
                .padding(10)
        }
        .padding(.top, 4)
    }

    /// Transient confirmation for save / restore (auto-clears via the controller).
    @ViewBuilder private var saveToast: some View {
        if let status = controller.saveStatus {
            Text(status)
                .font(.footnote.weight(.semibold))
                .foregroundStyle(.white)
                .padding(.horizontal, 14)
                .padding(.vertical, 8)
                .background(.black.opacity(0.7), in: Capsule())
                .padding(.top, 10)
                .transition(.opacity)
        }
    }

    private var menuButton: some View {
        Button {
            showMenu = true
        } label: {
            Image(systemName: "slider.horizontal.3")
                .font(.title2)
                .symbolRenderingMode(.hierarchical)
                .foregroundStyle(.white)
                .padding(12)
                .background(.black.opacity(0.45), in: Circle())
        }
        .padding(16)
    }
}
