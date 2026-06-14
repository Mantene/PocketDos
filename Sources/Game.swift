import Foundation
import Combine
import UniformTypeIdentifiers
import ZIPFoundation

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
    /// Launch command for raw-zip games: nil = not chosen yet, "" = drop to DOS
    /// prompt, otherwise the executable path (e.g. "DOOM/DOOM.EXE") to auto-run.
    var runCommand: String? = nil
    /// Candidate executables found inside a zip (for the launch picker).
    var executables: [String] = []
    /// Override for emulated RAM (DOSBox `memsize`, in MB); nil = use the bundle's own.
    var memoryMB: Int? = nil
    /// Extra dosbox.conf lines appended at launch (e.g. "[sblaster]\nirq=5") to
    /// override the bundle's config. nil/empty = no override.
    var configOverride: String? = nil

    var isZip: Bool { bundleFileName.lowercased().hasSuffix(".zip") }
    /// A zip we haven't chosen a launch command for yet, with options to offer.
    var needsLaunchSetup: Bool { isZip && runCommand == nil && !executables.isEmpty }

    /// Path the WKWebView's BundleSchemeHandler serves (same origin as the page),
    /// e.g. "lib/<id>/game.jsdos" → Documents/Games/<id>/game.jsdos.
    var webRelativeURL: String { "lib/\(id)/\(bundleFileName)" }
}

/// Writes meta.json for a game folder.
func writeGameMeta(title: String, profile: ControlProfile,
                   runCommand: String?, executables: [String],
                   memoryMB: Int?, configOverride: String?, to dir: URL) {
    var obj: [String: Any] = [
        "title": title,
        "controlProfile": profile.rawValue,
        "executables": executables,
    ]
    if let runCommand { obj["runCommand"] = runCommand }
    if let memoryMB { obj["memoryMB"] = memoryMB }
    if let configOverride, !configOverride.isEmpty { obj["configOverride"] = configOverride }
    if let data = try? JSONSerialization.data(withJSONObject: obj) {
        try? data.write(to: dir.appendingPathComponent("meta.json"))
    }
}

/// Persists a new control profile (preserving the other fields).
func writeControlProfile(_ profile: ControlProfile, for game: Game) {
    writeGameMeta(title: game.title, profile: profile, runCommand: game.runCommand,
                  executables: game.executables, memoryMB: game.memoryMB,
                  configOverride: game.configOverride, to: game.folderURL)
}

/// Persists a new launch command (preserving the other fields).
func writeRunCommand(_ runCommand: String?, for game: Game) {
    writeGameMeta(title: game.title, profile: game.controlProfile, runCommand: runCommand,
                  executables: game.executables, memoryMB: game.memoryMB,
                  configOverride: game.configOverride, to: game.folderURL)
}

/// Persists an emulated-RAM override (preserving the other fields).
func writeMemory(_ memoryMB: Int?, for game: Game) {
    writeGameMeta(title: game.title, profile: game.controlProfile, runCommand: game.runCommand,
                  executables: game.executables, memoryMB: memoryMB,
                  configOverride: game.configOverride, to: game.folderURL)
}

/// Persists a dosbox.conf override (preserving the other fields).
func writeConfigOverride(_ configOverride: String?, for game: Game) {
    writeGameMeta(title: game.title, profile: game.controlProfile, runCommand: game.runCommand,
                  executables: game.executables, memoryMB: game.memoryMB,
                  configOverride: configOverride, to: game.folderURL)
}

/// Reads the dosbox.conf embedded in a .jsdos bundle (for showing current settings
/// in the config editor). Returns nil for zip games (config is generated at launch).
func currentDosboxConf(for game: Game) -> String? {
    guard game.bundleFileName.lowercased().hasSuffix(".jsdos") else { return nil }
    let bundleURL = game.folderURL.appendingPathComponent(game.bundleFileName)
    guard let archive = try? Archive(url: bundleURL, accessMode: .read),
          let entry = archive[".jsdos/dosbox.conf"] else { return nil }
    var data = Data()
    _ = try? archive.extract(entry) { data.append($0) }
    return String(data: data, encoding: .utf8)
}

/// Lists executable entries (.exe/.com/.bat) inside a zip, for the launch picker.
func executablesInZip(at url: URL) -> [String] {
    guard let archive = try? Archive(url: url, accessMode: .read) else { return [] }
    var result: [String] = []
    for entry in archive {
        let lower = entry.path.lowercased()
        if lower.hasSuffix(".exe") || lower.hasSuffix(".com") || lower.hasSuffix(".bat") {
            result.append(entry.path)
        }
    }
    return result.sorted { $0.localizedCaseInsensitiveCompare($1) == .orderedAscending }
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
        var runCommand: String? = nil
        var executables: [String] = []
        var memoryMB: Int? = nil
        var configOverride: String? = nil
        let meta = dir.appendingPathComponent("meta.json")
        if let data = try? Data(contentsOf: meta),
           let obj = try? JSONSerialization.jsonObject(with: data) as? [String: Any] {
            if let t = obj["title"] as? String, !t.isEmpty { title = t }
            if let p = obj["controlProfile"] as? String, let cp = ControlProfile(rawValue: p) { profile = cp }
            if let rc = obj["runCommand"] as? String { runCommand = rc }
            if let exes = obj["executables"] as? [String] { executables = exes }
            if let mb = obj["memoryMB"] as? Int { memoryMB = mb }
            if let co = obj["configOverride"] as? String { configOverride = co }
        }

        return Game(id: dir.lastPathComponent, title: title,
                    bundleFileName: bundle.lastPathComponent, folderURL: dir,
                    controlProfile: profile, runCommand: runCommand,
                    executables: executables, memoryMB: memoryMB, configOverride: configOverride)
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
        let exes = ext.lowercased() == "zip" ? executablesInZip(at: dest) : []
        writeGameMeta(title: title, profile: .fps, runCommand: nil,
                      executables: exes, memoryMB: nil, configOverride: nil, to: dir)
        reload()
    }

    func rename(_ game: Game, to newTitle: String) {
        writeGameMeta(title: newTitle, profile: game.controlProfile,
                      runCommand: game.runCommand, executables: game.executables,
                      memoryMB: game.memoryMB, configOverride: game.configOverride, to: game.folderURL)
        reload()
    }

    /// Sets the launch command for a zip game ("" = drop to prompt).
    func setRunCommand(_ command: String?, for game: Game) {
        writeRunCommand(command, for: game)
        reload()
    }

    /// Sets the emulated-RAM override (nil = use the bundle's own memsize).
    func setMemory(_ memoryMB: Int?, for game: Game) {
        writeMemory(memoryMB, for: game)
        reload()
    }

    /// Sets the dosbox.conf override appended at launch (nil/"" = none).
    func setConfigOverride(_ text: String?, for game: Game) {
        let trimmed = text?.trimmingCharacters(in: .whitespacesAndNewlines)
        writeConfigOverride((trimmed?.isEmpty ?? true) ? nil : trimmed, for: game)
        reload()
    }

    func game(byId id: String) -> Game? {
        games.first { $0.id == id }
    }

    func delete(_ game: Game) {
        try? FileManager.default.removeItem(at: game.folderURL)
        reload()
    }
}
