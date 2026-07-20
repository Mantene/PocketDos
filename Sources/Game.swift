import Foundation
import Combine
import UniformTypeIdentifiers
import ZIPFoundation
import CryptoKit

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
    /// Stable SHA256 (hex) of the game bundle — the cross-device identity used to key
    /// iCloud save sync, so a save follows the same game across devices / reinstalls
    /// (the local folder id is a per-import UUID and can't match across devices).
    var contentHash: String? = nil
    /// Per-game game-controller button overrides: PadButton.id → ControllerAction token.
    /// Only buttons the user reassigned are stored; the rest use profile defaults.
    var controllerMap: [String: String] = [:]
    /// Controller cursor speed (px/frame) for the .mouse profile; nil = default.
    var cursorSpeed: Int? = nil
    /// Movement key-set the D-pad/left-stick emit ("arrows"/"wasd"/"numpad"); nil =
    /// arrows. Lets a controller match a game's keyboard movement scheme (DOS games
    /// have no joystick channel in js-dos, so a controller drives them via keys).
    var directionScheme: String? = nil

    var isZip: Bool { bundleFileName.lowercased().hasSuffix(".zip") }
    /// A zip we haven't chosen a launch command for yet, with options to offer.
    var needsLaunchSetup: Bool { isZip && runCommand == nil && !executables.isEmpty }

    /// Path the WKWebView's BundleSchemeHandler serves (same origin as the page),
    /// e.g. "lib/<id>/game.jsdos" → Documents/Games/<id>/game.jsdos.
    var webRelativeURL: String { "lib/\(id)/\(bundleFileName)" }

    // ---- Sockdrive games -------------------------------------------------------------
    /// A sockdrive game has NO single bundle file — its disk is a `drive/` directory of
    /// 256 KiB chunk files (`sockdrive.metaj` + `<N>.raw`), served at `lib/<id>/drive` and
    /// mounted via `imgmount 2 sockdrive`. The whole image is never loaded into memory
    /// (only the touched chunks stream), which removes the Win9x image-size memory ceiling.
    /// Detected by the presence of `drive/sockdrive.metaj` (bundleFileName is "").
    var driveMetaURL: URL { folderURL.appendingPathComponent("drive/sockdrive.metaj") }
    var isSockdrive: Bool { FileManager.default.fileExists(atPath: driveMetaURL.path) }
    /// Canonical same-origin base for the sockdrive — NO trailing slash (the client strips
    /// one). This ONE string is the `imgmount` base AND (for S2) the IndexedDB db-name
    /// suffix + sector-diff re-seed key; keep it identical everywhere.
    var driveBasePath: String { "lib/\(id)/drive" }
    /// On-disk location of the sockdrive sector-diff write-set (S2 persistence). Unlike a
    /// normal game's `changes.jsdos` (a whole-FS delta overlaid into MEMFS), this is the
    /// serialized CHANGED SECTORS the sockdrive client accumulates; it is re-seeded into
    /// IndexedDB (`"sockdrive (<base>)"`, store "write", key 0) before the drive mounts.
    var sockdriveWriteFileURL: URL { folderURL.appendingPathComponent("sockdrive-write.bin") }
    /// True once a sockdrive write-set has been persisted.
    var hasSockdriveWrite: Bool { FileManager.default.fileExists(atPath: sockdriveWriteFileURL.path) }
    /// Same-origin path the page fetches to re-seed the sockdrive write-set at boot, or nil
    /// when none is saved yet (boots from the pristine chunks). NO size cap — unlike a
    /// whole-FS restore, a sector-diff re-seed streams into IndexedDB (no MEMFS doubling),
    /// so the `maxRestoreBytes` OOM guard that gates `restorablePath` doesn't apply here.
    var sockdriveRestorablePath: String? { hasSockdriveWrite ? "lib/\(id)/sockdrive-write.bin" : nil }

    /// File name of the persisted filesystem-changes bundle (in-game saves +
    /// any disk changes, e.g. an installed Win9x HDD image).
    static let saveFileName = "changes.jsdos"
    /// On-disk location of this game's saved session (next to its bundle).
    var saveFileURL: URL { folderURL.appendingPathComponent(Self.saveFileName) }
    /// True when a saved session exists to restore on launch.
    var hasSavedSession: Bool { FileManager.default.fileExists(atPath: saveFileURL.path) }
    /// Same-origin path the page fetches to overlay the saved session. Always
    /// supplied: the page 404-handles a missing file, so a reload (quick-load /
    /// restart) always picks up the latest save, even one made mid-session.
    var restorePath: String { "lib/\(id)/\(Self.saveFileName)" }
    /// A save whose delta is ~the whole disk image (a mounted Win9x qcow2 — js-dos
    /// persists at FILE granularity, so any write marks the whole image "changed")
    /// must NOT be overlaid at launch: bundle + a 200 MB+ restore doubles memory and
    /// OOM-crashes the WebContent process on reopen (observed with Win98). Cap restores
    /// to a save small enough to overlay safely. Incremental Win9x saves are the
    /// sockdrive plan (sector diffs), not this whole-FS-delta path.
    static let maxRestoreBytes = 96 * 1_048_576
    /// `restorePath`, but only when a saved session exists AND is small enough to
    /// overlay without risking OOM; nil → the game loads fresh instead of crashing.
    var restorablePath: String? {
        guard hasSavedSession else { return nil }
        let attrs = try? FileManager.default.attributesOfItem(atPath: saveFileURL.path)
        let size = (attrs?[.size] as? Int) ?? 0
        return size <= Self.maxRestoreBytes ? restorePath : nil
    }
    /// Byte size of the game bundle file on disk (0 if it can't be read or there's no
    /// single bundle, e.g. a sockdrive game whose disk is a chunk directory).
    var bundleByteSize: Int {
        guard !bundleFileName.isEmpty else { return 0 }
        let attrs = try? FileManager.default.attributesOfItem(atPath: folderURL.appendingPathComponent(bundleFileName).path)
        return (attrs?[.size] as? Int) ?? 0
    }
    /// A large bundle is a mounted disk image (a Win9x qcow2 inside a `.jsdos`). One fact,
    /// two consequences — so it's named once:
    ///  • it can't be persisted — building its whole-FS delta via `ci.persist(true)`
    ///    OOM-crashes the WebContent process (observed on iPhone exiting Win98), and the
    ///    delta would exceed `maxRestoreBytes` anyway (unusable on reopen);
    ///  • it can't take a mem/config override — js-dos's in-place config rewrite re-buffers
    ///    the whole 200 MB+ bundle ~3× in JS heap → load OOM on iPhone (the "applying config…"
    ///    path in index.html; see `SharedEmulator.startURL`).
    /// Such images must bake their emulated RAM into their own dosbox.conf and load via the
    /// light streaming path; they run EPHEMERALLY until sockdrive adds sector-diff saves.
    var isLargeDiskImage: Bool { bundleByteSize > Self.maxRestoreBytes }
    /// Whether to attempt session persistence at all.
    var isPersistable: Bool {
        #if DEBUG
        if isSockSpike || isWriteSpike { return false }   // spikes never persist — no autosave noise
        #endif
        if isSockdrive { return true }    // S2: sockdrive persists incremental sector diffs (sockdrive-write.bin)
        return !isLargeDiskImage
    }

    #if DEBUG
    /// DEBUG-only synthetic library entry for the sockdrive boot-speed spike. Routed by
    /// `SharedEmulator.startURL` to `index.html?sockspike=…`, which boots Win9x from the
    /// 256 KiB chunks bundled at `Web/drive/` so we can measure on-device boot time
    /// (the one unknown the Chrome/Mac spike couldn't answer). Not a real game; it owns
    /// no folder and is never persisted.
    static let sockSpikeID = "__sockdrive_spike__"
    static var sockSpike: Game {
        Game(id: sockSpikeID, title: "▶ Win98 sockdrive spike", bundleFileName: "",
             folderURL: FileManager.default.temporaryDirectory)
    }
    var isSockSpike: Bool { id == Self.sockSpikeID }

    /// DEBUG-only synthetic entry for the sockdrive WRITE-LOAD OOM spike. Boots the
    /// bundled MS-DOS 7.1 floppy onto the existing win98 sockdrive and copies ~398 MB to
    /// C: to find the in-heap write-set OOM ceiling (the make-or-break for an on-device
    /// install wizard). Writes are ephemeral sector-diffs; the base chunks are untouched.
    static let writeSpikeID = "__sockdrive_writespike__"
    static var writeSpike: Game {
        Game(id: writeSpikeID, title: "▶ Win98 sockdrive WRITE spike", bundleFileName: "",
             folderURL: FileManager.default.temporaryDirectory)
    }
    var isWriteSpike: Bool { id == Self.writeSpikeID }
    #endif

    /// User-supplied Roland MT-32/CM-32L ROMs, repackaged with an MT32_ROMS/
    /// prefix so they unpack to /home/web_user/MT32_ROMS/ (= mt32.romdir).
    /// Copyrighted — never bundled; the user imports their own.
    static let mt32RomsFileName = "mt32_roms.zip"
    var mt32RomsURL: URL { folderURL.appendingPathComponent(Self.mt32RomsFileName) }
    var hasMT32ROMs: Bool { FileManager.default.fileExists(atPath: mt32RomsURL.path) }
    /// Same-origin path the harness injects when the game requests MT-32, or nil.
    var mt32RomsRelativeURL: String? {
        hasMT32ROMs ? "lib/\(id)/\(Self.mt32RomsFileName)" : nil
    }
}

/// SHA256 (lowercase hex) of a file, memory-mapped so large (e.g. Win9x) bundles
/// aren't fully loaded into RAM. nil if the file can't be read.
func sha256Hex(ofFileAt url: URL) -> String? {
    guard let data = try? Data(contentsOf: url, options: .mappedIfSafe) else { return nil }
    return SHA256.hash(data: data).map { String(format: "%02x", $0) }.joined()
}

/// Writes a game's full state to meta.json (a complete rewrite). Takes the whole
/// `Game` so callers can't silently drop a field by forgetting to pass it — the
/// failure mode that lost saved settings before.
func writeGameMeta(_ game: Game) {
    var obj: [String: Any] = [
        "title": game.title,
        "controlProfile": game.controlProfile.rawValue,
        "executables": game.executables,
    ]
    if let v = game.runCommand { obj["runCommand"] = v }
    if let v = game.memoryMB { obj["memoryMB"] = v }
    if let v = game.configOverride, !v.isEmpty { obj["configOverride"] = v }
    if let v = game.contentHash, !v.isEmpty { obj["contentHash"] = v }
    if !game.controllerMap.isEmpty { obj["controllerMap"] = game.controllerMap }
    if let v = game.cursorSpeed { obj["cursorSpeed"] = v }
    if let v = game.directionScheme, !v.isEmpty { obj["directionScheme"] = v }
    if let data = try? JSONSerialization.data(withJSONObject: obj) {
        try? data.write(to: game.folderURL.appendingPathComponent("meta.json"))
    }
}

/// Field-update helpers — copy the game, change one field, persist. New fields are
/// preserved automatically (no per-wrapper threading to forget).
func writeControlProfile(_ profile: ControlProfile, for game: Game) {
    var g = game; g.controlProfile = profile; writeGameMeta(g)
}
func writeRunCommand(_ runCommand: String?, for game: Game) {
    var g = game; g.runCommand = runCommand; writeGameMeta(g)
}
func writeMemory(_ memoryMB: Int?, for game: Game) {
    var g = game; g.memoryMB = memoryMB; writeGameMeta(g)
}
func writeConfigOverride(_ configOverride: String?, for game: Game) {
    var g = game; g.configOverride = configOverride; writeGameMeta(g)
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

/// True if a zip carries a sockdrive (any entry named `sockdrive.metaj`). Such a zip is
/// a chunked raw HDD, not a DOSBox bundle — it imports into a `drive/` folder, not `game.zip`.
func sockdriveMetaInZip(at url: URL) -> Bool {
    guard let archive = try? Archive(url: url, accessMode: .read) else { return false }
    for entry in archive where (entry.path as NSString).lastPathComponent == "sockdrive.metaj" {
        return true
    }
    return false
}

/// Extracts a sockdrive zip's chunk files flat into `<dir>/drive/`. The zip may wrap its
/// chunks in a top-level folder (e.g. `drive/0.raw`) or place them at the root — either way
/// each file lands in `drive/` by its basename. Skips directories, dotfiles, and __MACOSX.
func importSockdriveZip(from url: URL, into dir: URL) throws {
    let fm = FileManager.default
    let driveDir = dir.appendingPathComponent("drive", isDirectory: true)
    try fm.createDirectory(at: driveDir, withIntermediateDirectories: true)
    guard let archive = try? Archive(url: url, accessMode: .read) else {
        throw CocoaError(.fileReadCorruptFile)
    }
    for entry in archive {
        guard entry.type == .file else { continue }
        let name = (entry.path as NSString).lastPathComponent
        if name.isEmpty || name.hasPrefix(".") || entry.path.hasPrefix("__MACOSX") { continue }
        let dest = driveDir.appendingPathComponent(name)
        if fm.fileExists(atPath: dest.path) { try? fm.removeItem(at: dest) }
        _ = try archive.extract(entry, to: dest)
    }
}

/// A directory under Games/ that isn't a loadable game — the leftover of a failed
/// Windows install (kept for forensics) or a partial import. Surfaced by
/// `GameStore.reload()` so the user can reclaim the disk; deleted by
/// `cleanupOrphanedInstalls()`.
struct OrphanedInstall: Identifiable, Equatable {
    let id: String       // the folder's name (a UUID)
    let url: URL
    let sizeBytes: Int64
}

/// Manages the on-disk game library under Documents/Games (Files-app visible).
@MainActor
final class GameStore: ObservableObject {
    @Published private(set) var games: [Game] = []
    /// Folders under Games/ that aren't loadable games — the residue of failed installs
    /// (see `cleanupOrphanedInstalls`). Surfaced so the user can reclaim leaked disk.
    @Published private(set) var orphanedInstalls: [OrphanedInstall] = []

    static let gamesDirName = "Games"

    /// File types the importer accepts.
    static var importTypes: [UTType] {
        var types: [UTType] = [.zip]
        if let jsdos = UTType(filenameExtension: "jsdos") { types.append(jsdos) }
        types.append(.data) // fallback so untyped .jsdos files are still pickable
        return types
    }

    /// iCloud save-sync mirror (no-ops when iCloud is unavailable).
    let cloud = CloudSaveSync()
    /// Test override for the library root; production uses Documents/Games.
    private let gamesBaseOverride: URL?
    private var documentsURL: URL {
        FileManager.default.urls(for: .documentDirectory, in: .userDomainMask)[0]
    }
    var gamesURL: URL {
        gamesBaseOverride ?? documentsURL.appendingPathComponent(Self.gamesDirName, isDirectory: true)
    }

    /// `gamesBaseURL` is for tests (an isolated temp dir); production calls `GameStore()`.
    init(gamesBaseURL: URL? = nil) {
        self.gamesBaseOverride = gamesBaseURL
        try? FileManager.default.createDirectory(at: gamesURL, withIntermediateDirectories: true)
        reload()
        // Start mirroring saves from iCloud; resolve a synced save's content hash to
        // the local game folder so newer remote saves are pulled into it.
        cloud.start { [weak self] hash in self?.folderURL(forContentHash: hash) }
    }

    /// Local folder for the game with this content hash (for the iCloud pull mapping).
    func folderURL(forContentHash hash: String) -> URL? {
        games.first { $0.contentHash == hash }?.folderURL
    }

    /// Push a game's current save to iCloud (size-capped, no-op when unavailable).
    func cloudPushSave(for game: Game) {
        guard let hash = game.contentHash, game.hasSavedSession else { return }
        cloud.pushSave(localURL: game.saveFileURL, contentHash: hash)
    }

    func reload() {
        let fm = FileManager.default
        let dirs = (try? fm.contentsOfDirectory(at: gamesURL,
                                                includingPropertiesForKeys: [.isDirectoryKey])) ?? []
        var found: [Game] = []
        var orphans: [OrphanedInstall] = []
        for dir in dirs {
            let isDir = (try? dir.resourceValues(forKeys: [.isDirectoryKey]))?.isDirectory ?? false
            guard isDir else { continue }
            if let game = loadGame(in: dir) {
                found.append(game)
            } else {
                // A directory that isn't a loadable game is the residue of a FAILED install
                // (kept deliberately for forensics — see InstallOrchestrator.run) or a partial
                // import. It's invisible to the library and silently leaks disk. Surface it so
                // the user can reclaim the space; we never auto-delete (that would destroy the
                // only forensic artifact of a 30-60 minute unattended run).
                orphans.append(OrphanedInstall(id: dir.lastPathComponent, url: dir,
                                               sizeBytes: Self.folderSize(at: dir)))
            }
        }
        games = found.sorted {
            $0.title.localizedCaseInsensitiveCompare($1.title) == .orderedAscending
        }
        // Biggest first — the point of surfacing these is reclaiming space.
        orphanedInstalls = orphans.sorted { $0.sizeBytes > $1.sizeBytes }
    }

    private func loadGame(in dir: URL) -> Game? {
        let fm = FileManager.default
        // A sockdrive game has NO bundle file — its disk is a drive/ chunk directory.
        // Detect it FIRST (the .jsdos/.zip guard below returns nil for a bundle-less folder).
        let driveMeta = dir.appendingPathComponent("drive/sockdrive.metaj")
        if fm.fileExists(atPath: driveMeta.path) {
            var title = dir.lastPathComponent
            var profile: ControlProfile = .mouse   // a sockdrive game is a desktop OS → tap-to-click, not an FPS D-pad
            var controllerMap: [String: String] = [:]
            var cursorSpeed: Int? = nil
            var directionScheme: String? = nil
            var memoryMB: Int? = nil
            var contentHash: String? = nil
            if let data = try? Data(contentsOf: dir.appendingPathComponent("meta.json")),
               let obj = try? JSONSerialization.jsonObject(with: data) as? [String: Any] {
                if let t = obj["title"] as? String, !t.isEmpty { title = t }
                if let p = obj["controlProfile"] as? String, let cp = ControlProfile(rawValue: p) { profile = cp }
                if let cm = obj["controllerMap"] as? [String: String] { controllerMap = cm }
                if let cs = obj["cursorSpeed"] as? Int { cursorSpeed = cs }
                if let ds = obj["directionScheme"] as? String { directionScheme = ds }
                if let mb = obj["memoryMB"] as? Int { memoryMB = mb }
                if let ch = obj["contentHash"] as? String { contentHash = ch }
            }
            var game = Game(id: dir.lastPathComponent, title: title, bundleFileName: "", folderURL: dir,
                            controlProfile: profile, memoryMB: memoryMB, contentHash: contentHash,
                            controllerMap: controllerMap, cursorSpeed: cursorSpeed,
                            directionScheme: directionScheme)
            // Stable cross-device identity = SHA256 of the small, deterministic metaj.
            if game.contentHash == nil {
                game.contentHash = sha256Hex(ofFileAt: driveMeta)
                if game.contentHash != nil { writeGameMeta(game) }
            }
            return game
        }
        let files = (try? fm.contentsOfDirectory(at: dir, includingPropertiesForKeys: nil)) ?? []
        // The game bundle shares its extension (.zip/.jsdos) with auxiliary files
        // we store alongside it — the saved-session bundle and the MT-32 ROM zip.
        // Exclude those so the actual game is identified (imported games are always
        // named "game.<ext>", so a real bundle is never excluded).
        let auxiliary: Set<String> = [Game.saveFileName, Game.mt32RomsFileName]
        guard let bundle = files.first(where: {
            ["jsdos", "zip"].contains($0.pathExtension.lowercased())
                && !auxiliary.contains($0.lastPathComponent)
        }) else { return nil }

        var title = bundle.deletingPathExtension().lastPathComponent
        var profile: ControlProfile = .fps
        var runCommand: String? = nil
        var executables: [String] = []
        var memoryMB: Int? = nil
        var configOverride: String? = nil
        var contentHash: String? = nil
        var controllerMap: [String: String] = [:]
        var cursorSpeed: Int? = nil
        var directionScheme: String? = nil
        let meta = dir.appendingPathComponent("meta.json")
        if let data = try? Data(contentsOf: meta),
           let obj = try? JSONSerialization.jsonObject(with: data) as? [String: Any] {
            if let t = obj["title"] as? String, !t.isEmpty { title = t }
            if let p = obj["controlProfile"] as? String, let cp = ControlProfile(rawValue: p) { profile = cp }
            if let rc = obj["runCommand"] as? String { runCommand = rc }
            if let exes = obj["executables"] as? [String] { executables = exes }
            if let mb = obj["memoryMB"] as? Int { memoryMB = mb }
            if let co = obj["configOverride"] as? String { configOverride = co }
            if let ch = obj["contentHash"] as? String { contentHash = ch }
            if let cm = obj["controllerMap"] as? [String: String] { controllerMap = cm }
            if let cs = obj["cursorSpeed"] as? Int { cursorSpeed = cs }
            if let ds = obj["directionScheme"] as? String { directionScheme = ds }
        }

        var game = Game(id: dir.lastPathComponent, title: title,
                        bundleFileName: bundle.lastPathComponent, folderURL: dir,
                        controlProfile: profile, runCommand: runCommand,
                        executables: executables, memoryMB: memoryMB, configOverride: configOverride,
                        contentHash: contentHash, controllerMap: controllerMap, cursorSpeed: cursorSpeed,
                        directionScheme: directionScheme)

        // Backfill the content hash once for games imported before iCloud sync existed,
        // then persist it so we hash the (possibly large) bundle only this one time.
        if game.contentHash == nil {
            game.contentHash = sha256Hex(ofFileAt: bundle)
            if game.contentHash != nil { writeGameMeta(game) }
        }
        return game
    }

    enum ImportError: Error, LocalizedError, Equatable {
        /// The picked file can never load as a game (loadGame only recognizes
        /// .zip/.jsdos bundles). Without this guard the importer would copy the
        /// file anyway and silently produce an orphaned folder — the trap App
        /// Review hit after the Files app auto-unzipped the sample and they
        /// picked BOOM.EXE from inside it.
        case notAGameBundle(String)
        var errorDescription: String? {
            switch self {
            case .notAGameBundle(let name):
                return "\"\(name)\" isn't a game bundle. Import the whole game as a "
                    + ".zip or .jsdos file — if the Files app unzipped it, import the "
                    + "original .zip itself, not the files inside it."
            }
        }
    }

    /// Copies a picked file into a fresh library folder.
    func importGame(from sourceURL: URL) throws {
        let fm = FileManager.default
        let scoped = sourceURL.startAccessingSecurityScopedResource()
        defer { if scoped { sourceURL.stopAccessingSecurityScopedResource() } }

        // The picker's .data fallback (needed for untyped .jsdos downloads) lets
        // ANY file through — reject non-bundles before touching the library dir.
        let ext = sourceURL.pathExtension.isEmpty ? "jsdos" : sourceURL.pathExtension
        guard ["zip", "jsdos"].contains(ext.lowercased()) else {
            throw ImportError.notAGameBundle(sourceURL.lastPathComponent)
        }

        let id = UUID().uuidString
        let dir = gamesURL.appendingPathComponent(id, isDirectory: true)
        try fm.createDirectory(at: dir, withIntermediateDirectories: true)

        // A sockdrive zip is a chunked raw HDD, not a bundle. Unpack its chunks into
        // `<dir>/drive/` and register a bundle-less game (identity = SHA256 of metaj).
        if ext.lowercased() == "zip", sockdriveMetaInZip(at: sourceURL) {
            try importSockdriveZip(from: sourceURL, into: dir)
            let title = sourceURL.deletingPathExtension().lastPathComponent
            // Default a sockdrive (Win9x desktop) to mouse/tap-to-click controls, not the
            // struct-default FPS D-pad. Persisted to meta.json, so loadGame reads it back.
            var game = Game(id: id, title: title, bundleFileName: "", folderURL: dir, controlProfile: .mouse)
            game.contentHash = sha256Hex(ofFileAt: dir.appendingPathComponent("drive/sockdrive.metaj"))
            writeGameMeta(game)
            reload()
            if let h = game.contentHash { cloud.checkForSave(contentHash: h) }
            return
        }

        let dest = dir.appendingPathComponent("game.\(ext)")
        try fm.copyItem(at: sourceURL, to: dest)

        let title = sourceURL.deletingPathExtension().lastPathComponent
        let exes = ext.lowercased() == "zip" ? executablesInZip(at: dest) : []
        let contentHash = sha256Hex(ofFileAt: dest)
        var game = Game(id: id, title: title, bundleFileName: "game.\(ext)", folderURL: dir)
        game.executables = exes
        game.contentHash = contentHash
        writeGameMeta(game)
        reload()
        // A save for this exact game may already be in iCloud (synced from another
        // device) — pull it now that the game's hash resolves to a local folder.
        if let contentHash { cloud.checkForSave(contentHash: contentHash) }
    }

    func rename(_ game: Game, to newTitle: String) {
        var g = game; g.title = newTitle; writeGameMeta(g)
        reload()
    }

    /// Persists the per-game controller button overrides + cursor speed.
    func setControllerMapping(_ map: [String: String], cursorSpeed: Int?, directionScheme: String?,
                              for game: Game) {
        var g = game
        g.controllerMap = map; g.cursorSpeed = cursorSpeed; g.directionScheme = directionScheme
        writeGameMeta(g)
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

    // MARK: - Failed-install cleanup

    /// Total disk used by all surfaced failed installs (drives the "reclaim X" affordance).
    var orphanedInstallsTotalBytes: Int64 {
        orphanedInstalls.reduce(0) { $0 + $1.sizeBytes }
    }

    /// Deletes every surfaced failed-install folder, then refreshes. Loadable games are
    /// never in `orphanedInstalls`, so this cannot touch a real game.
    func cleanupOrphanedInstalls() {
        for orphan in orphanedInstalls {
            try? FileManager.default.removeItem(at: orphan.url)
        }
        reload()
    }

    /// Recursively sums the logical byte size of a folder's regular files (metadata
    /// enumeration only — never reads file contents). Logical size keeps the estimate
    /// deterministic; it differs from on-disk allocated size only by block rounding.
    private static func folderSize(at url: URL) -> Int64 {
        let fm = FileManager.default
        guard let en = fm.enumerator(at: url,
                                     includingPropertiesForKeys: [.fileSizeKey, .isRegularFileKey]) else {
            return 0
        }
        var total: Int64 = 0
        for case let file as URL in en {
            let vals = try? file.resourceValues(forKeys: [.fileSizeKey, .isRegularFileKey])
            if vals?.isRegularFile == true { total += Int64(vals?.fileSize ?? 0) }
        }
        return total
    }

    /// Deletes the saved session so the game next boots fresh from its bundle.
    func clearSave(_ game: Game) {
        try? FileManager.default.removeItem(at: game.saveFileURL)
        objectWillChange.send()
    }

    /// Imports user-supplied Roland MT-32/CM-32L ROMs, repackaged into
    /// `mt32_roms.zip` with an `MT32_ROMS/` prefix so they unpack to
    /// `/home/web_user/MT32_ROMS/` (the `mt32.romdir` the config editor sets).
    /// Accepts the raw `.ROM` files and/or a `.zip` containing them.
    func importMT32ROMs(for game: Game, from sourceURLs: [URL]) throws {
        // 1. Collect ROM bytes from the inputs (.ROM files and/or .zip archives).
        //    Skip empty extracts so a failed read never becomes a 0-byte ROM.
        var roms: [(name: String, data: Data)] = []
        for src in sourceURLs {
            let scoped = src.startAccessingSecurityScopedResource()
            defer { if scoped { src.stopAccessingSecurityScopedResource() } }
            switch src.pathExtension.lowercased() {
            case "zip":
                guard let inZip = try? Archive(url: src, accessMode: .read) else { continue }
                for entry in inZip where entry.path.lowercased().hasSuffix(".rom") {
                    var data = Data()
                    _ = try? inZip.extract(entry) { data.append($0) }
                    if !data.isEmpty { roms.append(((entry.path as NSString).lastPathComponent, data)) }
                }
            case "rom":
                let data = try Data(contentsOf: src)
                if !data.isEmpty { roms.append((src.lastPathComponent, data)) }
            default:
                continue
            }
        }

        guard !roms.isEmpty else {
            throw NSError(domain: "PocketDOS", code: 1, userInfo: [NSLocalizedDescriptionKey:
                "No .ROM files found. Import the Roland MT-32/CM-32L ROMs "
                + "(e.g. MT32_CONTROL.ROM and MT32_PCM.ROM), or a .zip containing them."])
        }

        // 2. Write them into a temp zip under MT32_ROMS/, then atomically swap it in.
        //    Building to a temp + moving means a mid-write failure never leaves a
        //    partial zip that `hasMT32ROMs` would report as a valid ROM set.
        let fm = FileManager.default
        let dest = game.mt32RomsURL
        let tmp = dest.deletingLastPathComponent()
            .appendingPathComponent("mt32_roms.\(UUID().uuidString).tmp.zip")
        var ok = false
        defer { if !ok { try? fm.removeItem(at: tmp) } }
        do {
            let archive = try Archive(url: tmp, accessMode: .create)
            for rom in roms {
                try archive.addEntry(with: "MT32_ROMS/\(rom.name)", type: .file,
                                     uncompressedSize: Int64(rom.data.count),
                                     compressionMethod: .deflate) { position, size in
                    let start = Int(position)
                    return rom.data.subdata(in: start ..< min(start + size, rom.data.count))
                }
            }
        }   // archive deinits here → file handle flushed + closed before the move

        try? fm.removeItem(at: dest)
        try fm.moveItem(at: tmp, to: dest)
        ok = true
        objectWillChange.send()
    }

    /// Removes a game's imported MT-32 ROMs.
    func removeMT32ROMs(_ game: Game) {
        try? FileManager.default.removeItem(at: game.mt32RomsURL)
        objectWillChange.send()
    }
}
