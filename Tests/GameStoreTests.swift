import XCTest
import ZIPFoundation
@testable import PocketDOS

/// Logic-layer tests for the game library (the richest pure-logic surface, and
/// where our real bugs have lived). Runs against an isolated temp directory via
/// the `gamesBaseURL` test override, so it never touches the live sandbox.
@MainActor
final class GameStoreTests: XCTestCase {
    private var tempRoot: URL!
    private var store: GameStore!

    override func setUpWithError() throws {
        tempRoot = URL(fileURLWithPath: NSTemporaryDirectory())
            .appendingPathComponent("pdos-tests-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: tempRoot, withIntermediateDirectories: true)
        store = GameStore(gamesBaseURL: tempRoot)
    }

    override func tearDownWithError() throws {
        try? FileManager.default.removeItem(at: tempRoot)
    }

    // MARK: - Helpers

    private func makeZip(at url: URL, entries: [(String, Data)]) throws {
        try? FileManager.default.removeItem(at: url)
        let archive = try Archive(url: url, accessMode: .create)
        for (path, data) in entries {
            try archive.addEntry(with: path, type: .file, uncompressedSize: Int64(data.count),
                                 compressionMethod: .deflate) { position, size in
                let start = Int(position)
                return data.subdata(in: start ..< min(start + size, data.count))
            }
        }
    }

    private func makeGameFolder() throws -> URL {
        let dir = tempRoot.appendingPathComponent(UUID().uuidString, isDirectory: true)
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        return dir
    }

    @discardableResult
    private func importJsdos(named name: String) throws -> Game {
        let src = tempRoot.appendingPathComponent("\(name).jsdos")
        try makeZip(at: src, entries: [(".jsdos/dosbox.conf", Data("[dosbox]\n".utf8))])
        try store.importGame(from: src)
        return try XCTUnwrap(store.game(byId: store.games.first { $0.title == name }?.id ?? ""))
    }

    // MARK: - loadGame aux-file exclusion (regression: the bundle-detection bug)

    func testLoadGameIgnoresChangesJsdos() throws {
        let dir = try makeGameFolder()
        try Data("x".utf8).write(to: dir.appendingPathComponent("changes.jsdos"))
        store.reload()
        XCTAssertTrue(store.games.isEmpty, "changes.jsdos must not be picked as a game bundle")
    }

    func testLoadGameIgnoresMT32RomsZip() throws {
        let dir = try makeGameFolder()
        try Data("x".utf8).write(to: dir.appendingPathComponent("mt32_roms.zip"))
        store.reload()
        XCTAssertTrue(store.games.isEmpty, "mt32_roms.zip must not be picked as a game bundle")
    }

    func testLoadGamePicksRealBundleOverAuxFiles() throws {
        let dir = try makeGameFolder()
        try makeZip(at: dir.appendingPathComponent("game.jsdos"),
                    entries: [(".jsdos/dosbox.conf", Data("[dosbox]\n".utf8))])
        try Data("x".utf8).write(to: dir.appendingPathComponent("changes.jsdos"))
        try Data("x".utf8).write(to: dir.appendingPathComponent("mt32_roms.zip"))
        store.reload()
        XCTAssertEqual(store.games.count, 1)
        XCTAssertEqual(store.games.first?.bundleFileName, "game.jsdos")
    }

    // MARK: - importGame

    func testImportGameCreatesLibraryEntry() throws {
        let g = try importJsdos(named: "Monkey Island")
        XCTAssertEqual(g.title, "Monkey Island")
        XCTAssertTrue(FileManager.default.fileExists(atPath: g.folderURL.appendingPathComponent("game.jsdos").path))
        XCTAssertTrue(FileManager.default.fileExists(atPath: g.folderURL.appendingPathComponent("meta.json").path))
    }

    func testImportGameZipScansExecutables() throws {
        let src = tempRoot.appendingPathComponent("DOOM.zip")
        try makeZip(at: src, entries: [
            ("DOOM/DOOM.EXE", Data("MZ".utf8)),
            ("SETUP.COM", Data("x".utf8)),
            ("README.TXT", Data("hi".utf8)),
        ])
        try store.importGame(from: src)
        let g = try XCTUnwrap(store.games.first)
        XCTAssertEqual(g.executables, ["DOOM/DOOM.EXE", "SETUP.COM"], "only .exe/.com/.bat, sorted")
    }

    // MARK: - sockdrive import (chunked raw HDD zip)

    func testImportSockdriveZipCreatesBundlelessGame() throws {
        let src = tempRoot.appendingPathComponent("Windows 98.zip")
        try makeZip(at: src, entries: [
            ("drive/sockdrive.metaj", Data("{\"sectorSize\":512}".utf8)),
            ("drive/0.raw", Data(repeating: 0xAB, count: 32)),
            ("drive/17.raw", Data(repeating: 0xCD, count: 32)),
        ])
        try store.importGame(from: src)
        let g = try XCTUnwrap(store.games.first)
        XCTAssertEqual(g.title, "Windows 98")
        XCTAssertTrue(g.bundleFileName.isEmpty, "a sockdrive game has no bundle file")
        XCTAssertTrue(g.isSockdrive)
        XCTAssertEqual(g.driveBasePath, "lib/\(g.id)/drive")
        // Chunks land flat under <dir>/drive/ by basename; metaj drives the content hash.
        let drive = g.folderURL.appendingPathComponent("drive")
        XCTAssertTrue(FileManager.default.fileExists(atPath: drive.appendingPathComponent("sockdrive.metaj").path))
        XCTAssertTrue(FileManager.default.fileExists(atPath: drive.appendingPathComponent("0.raw").path))
        XCTAssertTrue(FileManager.default.fileExists(atPath: drive.appendingPathComponent("17.raw").path))
        XCTAssertNotNil(g.contentHash)
        // No bundle file should have been written alongside the drive.
        XCTAssertFalse(FileManager.default.fileExists(atPath: g.folderURL.appendingPathComponent("game.zip").path))
    }

    func testImportSockdriveZipFlattensRootLevelChunks() throws {
        // A zip whose chunks sit at the root (no wrapping folder) imports the same way.
        let src = tempRoot.appendingPathComponent("flat.zip")
        try makeZip(at: src, entries: [
            ("sockdrive.metaj", Data("{}".utf8)),
            ("3.raw", Data(repeating: 0x01, count: 16)),
        ])
        try store.importGame(from: src)
        let g = try XCTUnwrap(store.games.first)
        XCTAssertTrue(g.isSockdrive)
        let drive = g.folderURL.appendingPathComponent("drive")
        XCTAssertTrue(FileManager.default.fileExists(atPath: drive.appendingPathComponent("sockdrive.metaj").path))
        XCTAssertTrue(FileManager.default.fileExists(atPath: drive.appendingPathComponent("3.raw").path))
    }

    func testImportSockdriveGameSurvivesReload() throws {
        let src = tempRoot.appendingPathComponent("Win98.zip")
        try makeZip(at: src, entries: [
            ("drive/sockdrive.metaj", Data("{}".utf8)),
            ("drive/0.raw", Data(repeating: 0x7F, count: 8)),
        ])
        try store.importGame(from: src)
        let hash = try XCTUnwrap(store.games.first?.contentHash)
        store.reload()
        let g = try XCTUnwrap(store.games.first)
        XCTAssertTrue(g.isSockdrive, "loadGame must re-detect the drive/ folder on reload")
        XCTAssertEqual(g.contentHash, hash, "stable metaj-derived identity persists across reload")
    }

    func testImportPlainZipIsNotTreatedAsSockdrive() throws {
        // A normal game zip (no sockdrive.metaj) takes the bundle path, not the drive path.
        let src = tempRoot.appendingPathComponent("Game.zip")
        try makeZip(at: src, entries: [("GAME.EXE", Data("MZ".utf8))])
        try store.importGame(from: src)
        let g = try XCTUnwrap(store.games.first)
        XCTAssertFalse(g.isSockdrive)
        XCTAssertEqual(g.bundleFileName, "game.zip")
    }

    // MARK: - sockdrive S2 write persistence

    func testSockdriveGameIsPersistable() throws {
        // S1 was read-only (isPersistable == false); S2 persists sector diffs, so it's now true.
        let src = tempRoot.appendingPathComponent("Win98.zip")
        try makeZip(at: src, entries: [("drive/sockdrive.metaj", Data("{}".utf8))])
        try store.importGame(from: src)
        let g = try XCTUnwrap(store.games.first)
        XCTAssertTrue(g.isSockdrive)
        XCTAssertTrue(g.isPersistable, "S2 sockdrive games persist incremental sector diffs")
    }

    func testImportedSockdriveDefaultsToMouseControls() throws {
        // A sockdrive game is a desktop OS (Win9x) → tap-to-click suits it, not an FPS D-pad.
        let src = tempRoot.appendingPathComponent("Win98.zip")
        try makeZip(at: src, entries: [("drive/sockdrive.metaj", Data("{}".utf8))])
        try store.importGame(from: src)
        let g = try XCTUnwrap(store.games.first)
        XCTAssertEqual(g.controlProfile, .mouse, "sockdrive imports default to mouse controls")
        // And the default survives a reload (it's persisted in meta.json).
        store.reload()
        XCTAssertEqual(try XCTUnwrap(store.games.first).controlProfile, .mouse)
    }

    func testSockdriveRestorablePathReflectsWriteFile() throws {
        let src = tempRoot.appendingPathComponent("Win98.zip")
        try makeZip(at: src, entries: [("drive/sockdrive.metaj", Data("{}".utf8))])
        try store.importGame(from: src)
        let g = try XCTUnwrap(store.games.first)
        // No write-set yet → boots from the pristine chunks (no &restore= param).
        XCTAssertFalse(g.hasSockdriveWrite)
        XCTAssertNil(g.sockdriveRestorablePath)
        // Once a sector-diff is persisted, the same-origin restore path points at it.
        try Data([0x01, 0x02, 0x03]).write(to: g.sockdriveWriteFileURL)
        XCTAssertTrue(g.hasSockdriveWrite)
        XCTAssertEqual(g.sockdriveRestorablePath, "lib/\(g.id)/sockdrive-write.bin")
    }

    func testReloadSortsByTitleCaseInsensitive() throws {
        for title in ["Zork", "doom", "Castle"] { try importJsdos(named: title) }
        XCTAssertEqual(store.games.map(\.title), ["Castle", "doom", "Zork"])
    }

    // MARK: - importMT32ROMs (regression: MT32_ROMS/ prefix + reject-no-ROMs)

    func testImportMT32ROMsPrefixesEntries() throws {
        let g = try importJsdos(named: "Sierra")
        let control = tempRoot.appendingPathComponent("MT32_CONTROL.ROM")
        let pcm = tempRoot.appendingPathComponent("MT32_PCM.ROM")
        try Data(repeating: 1, count: 64).write(to: control)
        try Data(repeating: 2, count: 128).write(to: pcm)

        try store.importMT32ROMs(for: g, from: [control, pcm])

        XCTAssertTrue(g.hasMT32ROMs)
        let zip = try Archive(url: g.mt32RomsURL, accessMode: .read)
        let paths = zip.map(\.path).sorted()
        XCTAssertEqual(paths, ["MT32_ROMS/MT32_CONTROL.ROM", "MT32_ROMS/MT32_PCM.ROM"],
                       "ROMs must land under MT32_ROMS/ so they unpack to /home/web_user/MT32_ROMS")
    }

    func testImportMT32ROMsFromZip() throws {
        let g = try importJsdos(named: "Sierra")
        let romZip = tempRoot.appendingPathComponent("roms.zip")
        try makeZip(at: romZip, entries: [
            ("MT32_CONTROL.ROM", Data(repeating: 1, count: 64)),
            ("MT32_PCM.ROM", Data(repeating: 2, count: 128)),
        ])
        try store.importMT32ROMs(for: g, from: [romZip])
        let zip = try Archive(url: g.mt32RomsURL, accessMode: .read)
        XCTAssertEqual(zip.map(\.path).filter { $0.hasPrefix("MT32_ROMS/") }.count, 2)
    }

    func testImportMT32ROMsRejectsInputWithNoROMs() throws {
        let g = try importJsdos(named: "Sierra")
        let junk = tempRoot.appendingPathComponent("notes.txt")
        try Data("not a rom".utf8).write(to: junk)
        XCTAssertThrowsError(try store.importMT32ROMs(for: g, from: [junk]))
        XCTAssertFalse(g.hasMT32ROMs, "no zip should be left behind when no ROMs were found")
    }

    // MARK: - config override persistence

    func testSetConfigOverrideTrimsWhitespace() throws {
        let g = try importJsdos(named: "Sierra")
        store.setConfigOverride("  [midi]\nmpu401=intelligent  ", for: g)
        let updated = try XCTUnwrap(store.game(byId: g.id))
        XCTAssertEqual(updated.configOverride, "[midi]\nmpu401=intelligent")
    }

    func testSetConfigOverrideNilsOnEmpty() throws {
        let g = try importJsdos(named: "Sierra")
        store.setConfigOverride("    ", for: g)
        let updated = try XCTUnwrap(store.game(byId: g.id))
        XCTAssertNil(updated.configOverride)
    }

    // MARK: - Game computed properties

    func testGameComputedPaths() throws {
        let g = try importJsdos(named: "Sierra")
        XCTAssertEqual(g.webRelativeURL, "lib/\(g.id)/game.jsdos")
        XCTAssertEqual(g.restorePath, "lib/\(g.id)/changes.jsdos")
        XCTAssertFalse(g.isZip)

        XCTAssertFalse(g.hasSavedSession)
        try Data("save".utf8).write(to: g.saveFileURL)
        XCTAssertTrue(g.hasSavedSession)
    }

    // MARK: - content hash (iCloud save-sync identity)

    func testImportComputesContentHash() throws {
        let g = try importJsdos(named: "Sierra")
        let bundle = g.folderURL.appendingPathComponent(g.bundleFileName)
        XCTAssertEqual(g.contentHash, sha256Hex(ofFileAt: bundle))
        XCTAssertEqual(g.contentHash?.count, 64)
    }

    func testLoadGameBackfillsMissingContentHash() throws {
        // Simulate a game imported before iCloud sync: bundle + meta.json with NO contentHash.
        let dir = try makeGameFolder()
        let bundle = dir.appendingPathComponent("game.jsdos")
        try makeZip(at: bundle, entries: [(".jsdos/dosbox.conf", Data("[dosbox]\n".utf8))])
        let meta: [String: Any] = ["title": "Old Game", "controlProfile": "fps", "executables": []]
        try JSONSerialization.data(withJSONObject: meta).write(to: dir.appendingPathComponent("meta.json"))

        store.reload()

        let g = try XCTUnwrap(store.games.first)
        XCTAssertEqual(g.contentHash, sha256Hex(ofFileAt: bundle), "loadGame backfills the hash")
        // And it's persisted, so a second load reads it back (no re-hash needed).
        store.reload()
        XCTAssertEqual(store.games.first?.contentHash, g.contentHash)
    }

    // MARK: - meta round-trip preserves all fields (writeGameMeta-takes-Game refactor)

    func testControllerMapSurvivesUnrelatedSettingChange() throws {
        let g = try importJsdos(named: "Sierra")
        store.setControllerMapping(["a": "rclick"], cursorSpeed: 14, directionScheme: "wasd", for: g)

        // Change an UNRELATED setting; the controller map + speed + scheme must NOT be
        // wiped (the old positional writeGameMeta dropped fields a caller forgot to pass).
        store.setMemory(64, for: try XCTUnwrap(store.game(byId: g.id)))

        let updated = try XCTUnwrap(store.game(byId: g.id))
        XCTAssertEqual(updated.controllerMap, ["a": "rclick"])
        XCTAssertEqual(updated.cursorSpeed, 14)
        XCTAssertEqual(updated.directionScheme, "wasd")
        XCTAssertEqual(updated.memoryMB, 64)
    }
}
