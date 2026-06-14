import Foundation
import Combine
import UniformTypeIdentifiers

/// A game stored in the app's library (one folder under Documents/Games/<id>/).
struct Game: Identifiable, Hashable {
    let id: String              // folder name (UUID)
    var title: String
    var bundleFileName: String  // e.g. "game.jsdos"
    var folderURL: URL

    /// Path the WKWebView's BundleSchemeHandler serves (same origin as the page),
    /// e.g. "lib/<id>/game.jsdos" → Documents/Games/<id>/game.jsdos.
    var webRelativeURL: String { "lib/\(id)/\(bundleFileName)" }
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
        let meta = dir.appendingPathComponent("meta.json")
        if let data = try? Data(contentsOf: meta),
           let obj = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
           let t = obj["title"] as? String, !t.isEmpty {
            title = t
        }

        return Game(id: dir.lastPathComponent, title: title,
                    bundleFileName: bundle.lastPathComponent, folderURL: dir)
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
        if let data = try? JSONSerialization.data(withJSONObject: ["title": title]) {
            try? data.write(to: dir.appendingPathComponent("meta.json"))
        }
        reload()
    }

    func rename(_ game: Game, to newTitle: String) {
        let meta = game.folderURL.appendingPathComponent("meta.json")
        if let data = try? JSONSerialization.data(withJSONObject: ["title": newTitle]) {
            try? data.write(to: meta)
        }
        reload()
    }

    func delete(_ game: Game) {
        try? FileManager.default.removeItem(at: game.folderURL)
        reload()
    }
}
