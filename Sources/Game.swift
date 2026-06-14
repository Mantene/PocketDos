import Foundation
import Combine
import UniformTypeIdentifiers

/// How a game is controlled on screen (persisted per game).
enum ControlProfile: String, CaseIterable {
    case fps    // D-pad + fire/use + weapons (action games)
    case mouse  // tap-to-click (js-dos absolute mouse) + right-click button (adventures)
    case off    // no on-screen controls (hardware keyboard/controller only)

    var label: String {
        switch self {
        case .fps: return "FPS controls"
        case .mouse: return "Mouse controls"
        case .off: return "No controls"
        }
    }
}

/// A game stored in the app's library (one folder under Documents/Games/<id>/).
struct Game: Identifiable, Hashable {
    let id: String              // folder name (UUID)
    var title: String
    var bundleFileName: String  // e.g. "game.jsdos"
    var folderURL: URL
    var controlProfile: ControlProfile = .fps

    /// Path the WKWebView's BundleSchemeHandler serves (same origin as the page),
    /// e.g. "lib/<id>/game.jsdos" → Documents/Games/<id>/game.jsdos.
    var webRelativeURL: String { "lib/\(id)/\(bundleFileName)" }
}

/// Writes meta.json (title + control profile) for a game folder.
func writeGameMeta(title: String, profile: ControlProfile, to dir: URL) {
    let obj: [String: Any] = ["title": title, "controlProfile": profile.rawValue]
    if let data = try? JSONSerialization.data(withJSONObject: obj) {
        try? data.write(to: dir.appendingPathComponent("meta.json"))
    }
}

/// Persists a new control profile for a game (preserving its title).
func writeControlProfile(_ profile: ControlProfile, for game: Game) {
    writeGameMeta(title: game.title, profile: profile, to: game.folderURL)
}

/// Manages the on-disk game library under Documents/Games (Files-app visible).
@MainActor
final class GameStore: ObservableObject {
    @Published private(set) var games: [Game] = []

    static let gamesDirName = "Games"

    /// File types the importer accepts.
    static var importTypes: [UTType] {
        var types: [UTType] = [.zip]
        if let jsdos = UTType(filenameExtension: "jsdos") { types.append(jsdos) }
        types.append(.data) // fallback so untyped .jsdos files are still pickable
        return types
    }

    private var documentsURL: URL {
        FileManager.default.urls(for: .documentDirectory, in: .userDomainMask)[0]
    }
    var gamesURL: URL {
        documentsURL.appendingPathComponent(Self.gamesDirName, isDirectory: true)
    }

    init() {
        try? FileManager.default.createDirectory(at: gamesURL, withIntermediateDirectories: true)
        reload()
    }

    func reload() {
        let fm = FileManager.default
        let dirs = (try? fm.contentsOfDirectory(at: gamesURL,
                                                includingPropertiesForKeys: [.isDirectoryKey])) ?? []
        var found: [Game] = []
        for dir in dirs {
            let isDir = (try? dir.resourceValues(forKeys: [.isDirectoryKey]))?.isDirectory ?? false
            if isDir, let game = loadGame(in: dir) { found.append(game) }
        }
        games = found.sorted {
            $0.title.localizedCaseInsensitiveCompare($1.title) == .orderedAscending
        }
    }

    private func loadGame(in dir: URL) -> Game? {
        let fm = FileManager.default
        let files = (try? fm.contentsOfDirectory(at: dir, includingPropertiesForKeys: nil)) ?? []
        guard let bundle = files.first(where: {
            ["jsdos", "zip"].contains($0.pathExtension.lowercased())
        }) else { return nil }

        var title = bundle.deletingPathExtension().lastPathComponent
        var profile: ControlProfile = .fps
        let meta = dir.appendingPathComponent("meta.json")
        if let data = try? Data(contentsOf: meta),
           let obj = try? JSONSerialization.jsonObject(with: data) as? [String: Any] {
            if let t = obj["title"] as? String, !t.isEmpty { title = t }
            if let p = obj["controlProfile"] as? String, let cp = ControlProfile(rawValue: p) { profile = cp }
        }

        return Game(id: dir.lastPathComponent, title: title,
                    bundleFileName: bundle.lastPathComponent, folderURL: dir,
                    controlProfile: profile)
    }

    /// Copies a picked file into a fresh library folder.
    func importGame(from sourceURL: URL) throws {
        let fm = FileManager.default
        let scoped = sourceURL.startAccessingSecurityScopedResource()
        defer { if scoped { sourceURL.stopAccessingSecurityScopedResource() } }

        let id = UUID().uuidString
        let dir = gamesURL.appendingPathComponent(id, isDirectory: true)
        try fm.createDirectory(at: dir, withIntermediateDirectories: true)

        let ext = sourceURL.pathExtension.isEmpty ? "jsdos" : sourceURL.pathExtension
        let dest = dir.appendingPathComponent("game.\(ext)")
        try fm.copyItem(at: sourceURL, to: dest)

        let title = sourceURL.deletingPathExtension().lastPathComponent
        writeGameMeta(title: title, profile: .fps, to: dir)
        reload()
    }

    func rename(_ game: Game, to newTitle: String) {
        writeGameMeta(title: newTitle, profile: game.controlProfile, to: game.folderURL)
        reload()
    }

    func delete(_ game: Game) {
        try? FileManager.default.removeItem(at: game.folderURL)
        reload()
    }
}
