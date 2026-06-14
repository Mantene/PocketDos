import SwiftUI

/// Root screen: a cover-art grid of imported games + an importer.
struct LibraryView: View {
    @StateObject private var store = GameStore()
    @State private var importing = false
    @State private var importError: String?

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
                                NavigationLink(value: game) {
                                    GameTile(game: game)
                                }
                                .buttonStyle(.plain)
                                .contextMenu {
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
                    Button {
                        importing = true
                    } label: {
                        Label("Import", systemImage: "plus")
                    }
                }
            }
            .navigationDestination(for: Game.self) { game in
                EmulatorView(game: game)
            }
            .fileImporter(isPresented: $importing,
                          allowedContentTypes: GameStore.importTypes,
                          allowsMultipleSelection: true) { result in
                handleImport(result)
            }
            .alert("Import failed",
                   isPresented: Binding(get: { importError != nil },
                                        set: { if !$0 { importError = nil } })) {
                Button("OK", role: .cancel) { importError = nil }
            } message: {
                Text(importError ?? "")
            }
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
    @Environment(\.dismiss) private var dismiss
    @StateObject private var controller = EmulatorController()
    @State private var showMenu = false
    @State private var showControls = true

    var body: some View {
        EmulatorWebView(gameRelativeURL: game.webRelativeURL, controller: controller)
            .ignoresSafeArea()
            .background(Color.black)
            .navigationBarBackButtonHidden(true)
            .toolbar(.hidden, for: .navigationBar)
            .overlay(alignment: .topLeading) { backButton }
            .overlay(alignment: .topTrailing) { menuButton }
            .overlay(alignment: .bottomLeading) {
                if showControls {
                    DPad(controller: controller)
                        .padding(.leading, 16).padding(.bottom, 28)
                }
            }
            .overlay(alignment: .bottomTrailing) {
                if showControls {
                    ActionCluster(controller: controller)
                        .padding(.trailing, 16).padding(.bottom, 28)
                }
            }
            .confirmationDialog("Game menu", isPresented: $showMenu, titleVisibility: .visible) {
                Button(showControls ? "Hide controls" : "Show controls") { showControls.toggle() }
                Button(controller.isPaused ? "Resume" : "Pause") { controller.togglePause() }
                Button("Save state") { controller.saveState() }
                Button("Restart") { controller.restart() }
                Button("Quit to Library", role: .destructive) { dismiss() }
                Button("Cancel", role: .cancel) {}
            }
            .alert("Couldn't run this game",
                   isPresented: Binding(get: { controller.loadError != nil },
                                        set: { if !$0 { controller.loadError = nil } })) {
                Button("Back to Library") { dismiss() }
            } message: {
                Text(friendlyEmulatorError(controller.loadError ?? ""))
            }
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
