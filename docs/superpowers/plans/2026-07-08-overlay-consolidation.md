# Overlay Consolidation Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** After a Win98 install, fold the ~154 MB write-overlay into the chunk set so future boots skip the reseed.

**Architecture:** A pure, FAT-agnostic `OverlayConsolidator` engine folds the overlay's replayed sectors into the chunk files (build a new `drive.new/`, validate by sample-sector equality, atomically swap, delete the overlay). A `GameStore.reload()` recovery sweep repairs an interrupted swap. `InstallOrchestrator` runs it as a non-fatal final stage. A one-shot `idbreset` (marker → `SharedEmulator` query param → `index.html`) clears the stale IndexedDB write store so the first post-consolidation boot is also fast.

**Tech Stack:** Swift (Foundation only), XCTest, the existing `FAT32OverlayEditor` overlay decoder and `SockdriveChunker.Metaj` manifest type. Spec: `docs/superpowers/specs/2026-07-08-overlay-consolidation-design.md`.

**Branch note:** the repo develops on `main`; there is no dedicated worktree. Execute on `main` unless the user asks to branch.

---

## File Structure

- **Create** `Sources/OverlayConsolidator.swift` — the engine: `consolidate(gameFolder:)`, `recoverIfInterrupted(gameFolder:)`, and internal fold/validate/swap helpers.
- **Create** `Tests/OverlayConsolidatorTests.swift` — engine unit tests (tiny synthetic chunks + overlay).
- **Modify** `Sources/FAT32OverlayEditor.swift` — widen `parse` visibility so the consolidator reuses the overlay decoder (raw + LZ4).
- **Modify** `Sources/Game.swift` — `idbResetMarkerURL` + `needsIdbReset`; call `OverlayConsolidator.recoverIfInterrupted` in `GameStore.reload()`.
- **Modify** `Sources/InstallOrchestrator.swift` — `case consolidating` state + a non-fatal consolidation step after `finalize`.
- **Modify** `Sources/SharedEmulator.swift` — append `&idbreset=1` for a game whose marker is set, and clear the marker one-shot after launch.
- **Modify** `Web/index.html` — `clearSockdriveWrites(base)` + honor an `idbreset` flag in the `?drive=` boot path.

---

## Task 1: Expose the overlay decoder

**Files:**
- Modify: `Sources/FAT32OverlayEditor.swift` (the `parse` declaration, ~line 300+)

- [ ] **Step 1: Find the current declaration**

Run: `grep -n "static func parse(overlay" Sources/FAT32OverlayEditor.swift`
Expected: one line like `private static func parse(overlay: Data) throws -> ([UInt32: Data], UInt32) {`

- [ ] **Step 2: Widen visibility to internal**

Change `private static func parse(overlay:` to `static func parse(overlay:` (drop `private`). Add a doc line above it:

```swift
/// Decodes an overlay blob into (LBA → final 512-byte sector, record count),
/// replaying later-wins. Exposed for OverlayConsolidator, which folds these
/// sectors into the chunk files. Handles both raw-516 and LZ4 records.
static func parse(overlay: Data) throws -> (map: [UInt32: Data], count: UInt32) {
```

(Keep the existing named-tuple signature and body unchanged — only remove `private` and add the doc comment.)

- [ ] **Step 3: Build to confirm no breakage**

Run: `DEVELOPER_DIR=/Applications/Xcode-beta.app/Contents/Developer xcodebuild -project PocketDOS.xcodeproj -scheme PocketDOS -destination 'id=4C6AE55C-CD39-4A82-976F-396D8A0C750E' CODE_SIGNING_ALLOWED=NO build 2>&1 | tail -3`
Expected: `** BUILD SUCCEEDED **`

- [ ] **Step 4: Commit**

```bash
git add Sources/FAT32OverlayEditor.swift
git commit -m "FAT32OverlayEditor: expose parse() for OverlayConsolidator

Co-Authored-By: Claude Fable 5 <noreply@anthropic.com>"
```

---

## Task 2: OverlayConsolidator — fold overlay into a new chunk set

The core. Given `drive/` (chunk files `<i>.raw` + `sockdrive.metaj`) and `sockdrive-write.bin`, build `drive.new/` whose chunks equal `(old chunks with the overlay applied)`.

**Files:**
- Create: `Sources/OverlayConsolidator.swift`
- Test: `Tests/OverlayConsolidatorTests.swift`

- [ ] **Step 1: Write the failing test**

```swift
import XCTest
@testable import PocketDOS

final class OverlayConsolidatorTests: XCTestCase {
    private var root: URL!
    override func setUpWithError() throws {
        root = URL(fileURLWithPath: NSTemporaryDirectory())
            .appendingPathComponent("pdos-consolidate-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
    }
    override func tearDownWithError() throws { try? FileManager.default.removeItem(at: root) }

    // MARK: - Helpers

    static let chunkBytes = 262_144
    static let sectorSize = 512

    /// A 256 KiB chunk whose first sector is filled with `byte`, rest zero.
    private func chunk(firstSectorByte byte: UInt8) -> Data {
        var d = Data(count: Self.chunkBytes)
        for i in 0..<Self.sectorSize { d[i] = byte }
        return d
    }

    /// A raw-516 overlay of the given (absoluteLBA, 512-byte sector) records.
    private func overlay(_ records: [(UInt32, Data)]) -> Data {
        var d = Data()
        func u32(_ v: UInt32) -> Data { withUnsafeBytes(of: v.littleEndian) { Data($0) } }
        d.append(u32(UInt32(records.count)))
        for (lba, sector) in records {
            precondition(sector.count == 512)
            d.append(u32(516)); d.append(u32(lba)); d.append(sector)
        }
        return d
    }

    private func sector(_ byte: UInt8) -> Data { Data(repeating: byte, count: 512) }

    /// A minimal metaj JSON with the given range_count and dropped ranges.
    private func writeMetaj(_ dir: URL, rangeCount: Int, dropped: [UInt32], preload: [UInt32]) throws {
        let m = SockdriveChunker.Metaj(
            ahead_read: Self.chunkBytes, cylinders: 520, dropped_ranges: dropped, heads: 128,
            name: "fat32-2gb", preload_ranges: preload, range_count: rangeCount,
            sector_size: 512, sectors: 63, size: 2_097_152)
        let enc = JSONEncoder(); enc.outputFormatting = [.sortedKeys, .withoutEscapingSlashes]
        try enc.encode(m).write(to: dir.appendingPathComponent("sockdrive.metaj"))
    }

    func testFoldOverwritesFillsAndDrops() throws {
        // drive/: 4 ranges. range 0 = chunk(0xAA in sector0); range 2 present all-0xCC-sector0;
        // ranges 1,3 dropped (all-zero, no file).
        let drive = root.appendingPathComponent("drive", isDirectory: true)
        try FileManager.default.createDirectory(at: drive, withIntermediateDirectories: true)
        try chunk(firstSectorByte: 0xAA).write(to: drive.appendingPathComponent("0.raw"))
        try chunk(firstSectorByte: 0xCC).write(to: drive.appendingPathComponent("2.raw"))
        try writeMetaj(drive, rangeCount: 4, dropped: [1, 3], preload: [0, 2, 3])

        // overlay: overwrite range0 sector0 → 0xBB; fill dropped range1 sector0 → 0x11;
        // zero range2 sector0 → 0x00 (range 2 becomes all-zero → must drop).
        let ov = overlay([
            (0, sector(0xBB)),                 // lba 0 = range 0, sector 0
            (512, sector(0x11)),               // lba 512 = range 1, sector 0
            (1024, sector(0x00)),              // lba 1024 = range 2, sector 0
        ])
        try ov.write(to: root.appendingPathComponent("sockdrive-write.bin"))

        try OverlayConsolidator.fold(gameFolder: root)   // builds drive.new/

        let out = root.appendingPathComponent("drive.new", isDirectory: true)
        // range 0: overwritten → file present, sector0 == 0xBB
        let c0 = try Data(contentsOf: out.appendingPathComponent("0.raw"))
        XCTAssertEqual(Array(c0[0..<512]), Array(sector(0xBB)))
        // range 1: filled → file now present, sector0 == 0x11
        let c1 = try Data(contentsOf: out.appendingPathComponent("1.raw"))
        XCTAssertEqual(Array(c1[0..<512]), Array(sector(0x11)))
        // range 2: zeroed → all-zero → NO file
        XCTAssertFalse(FileManager.default.fileExists(atPath: out.appendingPathComponent("2.raw").path))
        // range 3: still dropped → NO file
        XCTAssertFalse(FileManager.default.fileExists(atPath: out.appendingPathComponent("3.raw").path))
        // metaj: dropped_ranges == [2,3] (1 filled, 2 newly dropped), sorted
        let m = try JSONDecoder().decode(SockdriveChunker.Metaj.self,
            from: Data(contentsOf: out.appendingPathComponent("sockdrive.metaj")))
        XCTAssertEqual(m.dropped_ranges, [2, 3])
        XCTAssertEqual(m.range_count, 4)
        // preload filtered to in-range, non-dropped: [0,2,3] → [0]
        XCTAssertEqual(m.preload_ranges, [0])
    }
}
```

- [ ] **Step 2: Run test to verify it fails**

Run: `DEVELOPER_DIR=/Applications/Xcode-beta.app/Contents/Developer xcodebuild -project PocketDOS.xcodeproj -scheme PocketDOS -destination 'id=4C6AE55C-CD39-4A82-976F-396D8A0C750E' CODE_SIGNING_ALLOWED=NO -only-testing:PocketDOSTests/OverlayConsolidatorTests test 2>&1 | grep -E "error:|no member"`
Expected: FAIL — `type 'OverlayConsolidator' has no member 'fold'` (and the type itself is undefined).

- [ ] **Step 3: Write minimal implementation**

Create `Sources/OverlayConsolidator.swift`:

```swift
import Foundation

/// Folds a sockdrive game's write-overlay into its chunk files so future boots
/// need no reseed. Pure sector arithmetic — no FAT32 knowledge — so it is
/// testable at tiny scale. See docs/superpowers/specs/2026-07-08-overlay-consolidation-design.md.
enum OverlayConsolidator {

    static let chunkBytes = 262_144
    static let sectorSize = 512
    static let sectorsPerChunk = chunkBytes / sectorSize   // 512

    enum ConsolidateError: Error, LocalizedError {
        case noMetaj
        case overlayLBAOutOfRange(UInt32, rangeCount: Int)
        var errorDescription: String? {
            switch self {
            case .noMetaj: return "The drive has no sockdrive.metaj."
            case .overlayLBAOutOfRange(let lba, let rc):
                return "Overlay sector \(lba) falls outside the \(rc)-range drive."
            }
        }
    }

    /// Builds `drive.new/` next to `drive/` with the overlay folded in. Does not
    /// swap anything. Throws (leaving `drive/` + overlay untouched) on any error.
    static func fold(gameFolder: URL) throws {
        let fm = FileManager.default
        let drive = gameFolder.appendingPathComponent("drive", isDirectory: true)
        let driveNew = gameFolder.appendingPathComponent("drive.new", isDirectory: true)
        let overlayURL = gameFolder.appendingPathComponent("sockdrive-write.bin")

        // Old manifest → geometry + range_count.
        let metajURL = drive.appendingPathComponent("sockdrive.metaj")
        guard let metajData = try? Data(contentsOf: metajURL) else { throw ConsolidateError.noMetaj }
        let old = try JSONDecoder().decode(SockdriveChunker.Metaj.self, from: metajData)
        let rangeCount = old.range_count

        // Overlay → final LBA→sector map (raw + LZ4), replayed later-wins.
        let overlayData = (try? Data(contentsOf: overlayURL)) ?? Data()
        let (map, _) = try FAT32OverlayEditor.parse(overlay: overlayData)

        // Fresh output dir.
        try? fm.removeItem(at: driveNew)
        try fm.createDirectory(at: driveNew, withIntermediateDirectories: true)

        // Which LBAs the overlay touches, bucketed by chunk index.
        var touchedByRange: [Int: [UInt32]] = [:]
        for lba in map.keys {
            let range = Int(lba) / sectorsPerChunk
            guard range < rangeCount else { throw ConsolidateError.overlayLBAOutOfRange(lba, rangeCount: rangeCount) }
            touchedByRange[range, default: []].append(lba)
        }

        var dropped: [UInt32] = []
        for range in 0..<rangeCount {
            let existing = drive.appendingPathComponent("\(range).raw")
            let touched = touchedByRange[range]
            // Untouched ranges pass through verbatim (copy the file, or stay dropped).
            if touched == nil {
                if fm.fileExists(atPath: existing.path) {
                    try fm.copyItem(at: existing, to: driveNew.appendingPathComponent("\(range).raw"))
                } else {
                    dropped.append(UInt32(range))
                }
                continue
            }
            // Touched: start from the old chunk (or zeros) and apply the overlay sectors.
            var chunk = (try? Data(contentsOf: existing)) ?? Data(count: chunkBytes)
            if chunk.count != chunkBytes { chunk = Data(count: chunkBytes) }
            for lba in touched! {
                guard let sector = map[lba] else { continue }
                let offset = (Int(lba) % sectorsPerChunk) * sectorSize
                chunk.replaceSubrange(chunk.startIndex + offset ..< chunk.startIndex + offset + sectorSize,
                                      with: sector)
            }
            let isZero = chunk.withUnsafeBytes { raw in !raw.contains { $0 != 0 } }
            if isZero {
                dropped.append(UInt32(range))
            } else {
                try chunk.write(to: driveNew.appendingPathComponent("\(range).raw"))
            }
        }

        // New manifest: same geometry, updated drops, preload re-filtered.
        let droppedSet = Set(dropped)
        let preload = old.preload_ranges.filter { $0 < UInt32(rangeCount) && !droppedSet.contains($0) }
        let new = SockdriveChunker.Metaj(
            ahead_read: old.ahead_read, cylinders: old.cylinders, dropped_ranges: dropped.sorted(),
            heads: old.heads, name: old.name, preload_ranges: preload, range_count: old.range_count,
            sector_size: old.sector_size, sectors: old.sectors, size: old.size)
        let enc = JSONEncoder(); enc.outputFormatting = [.sortedKeys, .withoutEscapingSlashes]
        try enc.encode(new).write(to: driveNew.appendingPathComponent("sockdrive.metaj"))
    }
}
```

- [ ] **Step 4: Run test to verify it passes**

Run: `DEVELOPER_DIR=/Applications/Xcode-beta.app/Contents/Developer xcodebuild -project PocketDOS.xcodeproj -scheme PocketDOS -destination 'id=4C6AE55C-CD39-4A82-976F-396D8A0C750E' CODE_SIGNING_ALLOWED=NO -only-testing:PocketDOSTests/OverlayConsolidatorTests test 2>&1 | grep -E "Executed|passed|failed"`
Expected: `Executed 1 test, with 0 failures`. (`OverlayConsolidator.swift` is picked up automatically — `Tests`/`Sources` are folder references; no `xcodegen` needed.)

- [ ] **Step 5: Commit**

```bash
git add Sources/OverlayConsolidator.swift Tests/OverlayConsolidatorTests.swift
git commit -m "OverlayConsolidator: fold overlay into a new chunk set

Co-Authored-By: Claude Fable 5 <noreply@anthropic.com>"
```

---

## Task 3: Sample-sector validation

Independently re-derive the original composite at a sample of LBAs and assert the new chunks match. This is both a unit-tested method and the on-device pre-swap gate.

**Files:**
- Modify: `Sources/OverlayConsolidator.swift`
- Test: `Tests/OverlayConsolidatorTests.swift`

- [ ] **Step 1: Write the failing test**

```swift
func testValidatePassesForFaithfulFoldAndFailsForCorruption() throws {
    let drive = root.appendingPathComponent("drive", isDirectory: true)
    try FileManager.default.createDirectory(at: drive, withIntermediateDirectories: true)
    try chunk(firstSectorByte: 0xAA).write(to: drive.appendingPathComponent("0.raw"))
    try writeMetaj(drive, rangeCount: 2, dropped: [1], preload: [0])
    let ov = overlay([(0, sector(0xBB)), (512, sector(0x11))])
    try ov.write(to: root.appendingPathComponent("sockdrive-write.bin"))

    try OverlayConsolidator.fold(gameFolder: root)
    // Faithful fold → validation passes.
    XCTAssertNoThrow(try OverlayConsolidator.validate(gameFolder: root))

    // Corrupt one new chunk → validation must throw.
    let bad = root.appendingPathComponent("drive.new/0.raw")
    var c = try Data(contentsOf: bad); c[0] = 0x00; try c.write(to: bad)
    XCTAssertThrowsError(try OverlayConsolidator.validate(gameFolder: root))
}
```

- [ ] **Step 2: Run test to verify it fails**

Run: `DEVELOPER_DIR=/Applications/Xcode-beta.app/Contents/Developer xcodebuild -project PocketDOS.xcodeproj -scheme PocketDOS -destination 'id=4C6AE55C-CD39-4A82-976F-396D8A0C750E' CODE_SIGNING_ALLOWED=NO -only-testing:PocketDOSTests/OverlayConsolidatorTests/testValidatePassesForFaithfulFoldAndFailsForCorruption test 2>&1 | grep -E "error:|no member"`
Expected: FAIL — `type 'OverlayConsolidator' has no member 'validate'`.

- [ ] **Step 3: Write minimal implementation**

Add to `OverlayConsolidator` (and a `ValidationError`):

```swift
    case validationMismatch(lba: UInt32)
    // (add the case to ConsolidateError and its errorDescription:
    //  "Consolidated chunk mismatch at sector \(lba) — refusing to swap.")

    /// Reads a sector straight from a chunk directory (no overlay): the file's
    /// sector, or zeros for a missing chunk.
    private static func sectorFromChunks(_ dir: URL, lba: UInt32) -> Data {
        let range = Int(lba) / sectorsPerChunk
        let url = dir.appendingPathComponent("\(range).raw")
        guard let chunk = try? Data(contentsOf: url), chunk.count == chunkBytes else {
            return Data(count: sectorSize)
        }
        let offset = (Int(lba) % sectorsPerChunk) * sectorSize
        return chunk.subdata(in: chunk.startIndex + offset ..< chunk.startIndex + offset + sectorSize)
    }

    /// Asserts `drive.new/` reproduces the original composite (old chunks ∥ overlay)
    /// at every overlay-touched LBA plus a deterministic spread. Throws on any mismatch.
    static func validate(gameFolder: URL) throws {
        let drive = gameFolder.appendingPathComponent("drive", isDirectory: true)
        let driveNew = gameFolder.appendingPathComponent("drive.new", isDirectory: true)
        let overlayData = (try? Data(contentsOf: gameFolder.appendingPathComponent("sockdrive-write.bin"))) ?? Data()
        let (map, _) = try FAT32OverlayEditor.parse(overlay: overlayData)

        // Every touched LBA: original composite is the overlay sector (overlay wins);
        // the new drive (no overlay) must read the same bytes from its chunks.
        // Cap to a deterministic sample so a 300k-record overlay stays fast on device.
        let sampleCap = 2_000
        let touched = map.keys.sorted()
        let stride = max(1, touched.count / sampleCap)
        for i in Swift.stride(from: 0, to: touched.count, by: stride) {
            let lba = touched[i]
            if sectorFromChunks(driveNew, lba: lba) != map[lba]! {
                throw ConsolidateError.validationMismatch(lba: lba)
            }
        }
        // Plus LBA 0 (boot record) unconditionally: original composite vs new chunks.
        let original0 = map[0] ?? sectorFromChunks(drive, lba: 0)
        if sectorFromChunks(driveNew, lba: 0) != original0 {
            throw ConsolidateError.validationMismatch(lba: 0)
        }
    }
```

- [ ] **Step 4: Run test to verify it passes**

Run: same `-only-testing:PocketDOSTests/OverlayConsolidatorTests` command as Task 2 Step 4.
Expected: `Executed 2 tests, with 0 failures`.

- [ ] **Step 5: Commit**

```bash
git add Sources/OverlayConsolidator.swift Tests/OverlayConsolidatorTests.swift
git commit -m "OverlayConsolidator: sample-sector validation gate

Co-Authored-By: Claude Fable 5 <noreply@anthropic.com>"
```

---

## Task 4: Atomic swap + one-shot idbreset marker

**Files:**
- Modify: `Sources/OverlayConsolidator.swift`
- Test: `Tests/OverlayConsolidatorTests.swift`

- [ ] **Step 1: Write the failing test**

```swift
func testConsolidateSwapsInPlaceAndArmsIdbReset() throws {
    let drive = root.appendingPathComponent("drive", isDirectory: true)
    try FileManager.default.createDirectory(at: drive, withIntermediateDirectories: true)
    try chunk(firstSectorByte: 0xAA).write(to: drive.appendingPathComponent("0.raw"))
    try writeMetaj(drive, rangeCount: 2, dropped: [1], preload: [0])
    try overlay([(0, sector(0xBB)), (512, sector(0x11))])
        .write(to: root.appendingPathComponent("sockdrive-write.bin"))

    try OverlayConsolidator.consolidate(gameFolder: root)

    let fm = FileManager.default
    // Overlay folded in and gone; live drive holds the merged chunks.
    XCTAssertFalse(fm.fileExists(atPath: root.appendingPathComponent("sockdrive-write.bin").path))
    XCTAssertFalse(fm.fileExists(atPath: root.appendingPathComponent("drive.new").path))
    XCTAssertFalse(fm.fileExists(atPath: root.appendingPathComponent("drive.old").path))
    let c0 = try Data(contentsOf: drive.appendingPathComponent("0.raw"))
    XCTAssertEqual(Array(c0[0..<512]), Array(sector(0xBB)))
    XCTAssertTrue(fm.fileExists(atPath: drive.appendingPathComponent("1.raw").path))
    // idbreset armed for the next boot.
    XCTAssertTrue(fm.fileExists(atPath: root.appendingPathComponent(".pdos-idbreset").path))
}

func testConsolidateNoOpWithoutOverlay() throws {
    let drive = root.appendingPathComponent("drive", isDirectory: true)
    try FileManager.default.createDirectory(at: drive, withIntermediateDirectories: true)
    try chunk(firstSectorByte: 0xAA).write(to: drive.appendingPathComponent("0.raw"))
    try writeMetaj(drive, rangeCount: 2, dropped: [1], preload: [0])
    // No sockdrive-write.bin.
    try OverlayConsolidator.consolidate(gameFolder: root)   // must not throw, must not arm reset
    XCTAssertFalse(FileManager.default.fileExists(atPath: root.appendingPathComponent(".pdos-idbreset").path))
}
```

- [ ] **Step 2: Run test to verify it fails**

Run: the `-only-testing:PocketDOSTests/OverlayConsolidatorTests` command.
Expected: FAIL — `type 'OverlayConsolidator' has no member 'consolidate'`.

- [ ] **Step 3: Write minimal implementation**

Add to `OverlayConsolidator`:

```swift
    static let idbResetMarkerName = ".pdos-idbreset"

    /// The full operation: fold → validate → swap → delete overlay → arm idbreset.
    /// No-op when there is no overlay. Throws (leaving the original intact) on any error.
    static func consolidate(gameFolder: URL) throws {
        let fm = FileManager.default
        let overlayURL = gameFolder.appendingPathComponent("sockdrive-write.bin")
        guard fm.fileExists(atPath: overlayURL.path) else { return }   // nothing to fold

        let drive = gameFolder.appendingPathComponent("drive", isDirectory: true)
        let driveNew = gameFolder.appendingPathComponent("drive.new", isDirectory: true)
        let driveOld = gameFolder.appendingPathComponent("drive.old", isDirectory: true)

        try fold(gameFolder: gameFolder)      // builds drive.new/
        try validate(gameFolder: gameFolder)  // throws → drive.new/ discarded below

        // Commit. Original drive/ + overlay stay intact until the first rename.
        try? fm.removeItem(at: driveOld)
        try fm.moveItem(at: drive, to: driveOld)     // step A
        try fm.moveItem(at: driveNew, to: drive)     // step B  (now live)
        try fm.removeItem(at: overlayURL)            // overlay now lives in the chunks
        try? fm.removeItem(at: driveOld)             // cleanup
        // Arm the one-shot IndexedDB reset for the next boot.
        fm.createFile(atPath: gameFolder.appendingPathComponent(idbResetMarkerName).path, contents: Data())
    }
```

Also: on a thrown `validate`, the caller (Task 8/orchestrator) treats it as non-fatal, but `drive.new/` must not linger. Add a `defer` cleanup of `drive.new/` inside `consolidate` if control leaves before the swap:

```swift
        // At the top of consolidate(), after computing driveNew:
        var swapped = false
        defer { if !swapped { try? fm.removeItem(at: driveNew) } }
        // ... set `swapped = true` immediately after the step-B moveItem succeeds.
```

- [ ] **Step 4: Run test to verify it passes**

Run: the `-only-testing:PocketDOSTests/OverlayConsolidatorTests` command.
Expected: `Executed 4 tests, with 0 failures`.

- [ ] **Step 5: Commit**

```bash
git add Sources/OverlayConsolidator.swift Tests/OverlayConsolidatorTests.swift
git commit -m "OverlayConsolidator: atomic swap + one-shot idbreset marker

Co-Authored-By: Claude Fable 5 <noreply@anthropic.com>"
```

---

## Task 5: Crash-recovery sweep

**Files:**
- Modify: `Sources/OverlayConsolidator.swift`
- Test: `Tests/OverlayConsolidatorTests.swift`

- [ ] **Step 1: Write the failing test** (one per reachable interrupted state — see the spec's table)

```swift
func testRecoverRollsBackWhenDriveAndDriveNewPresent() throws {
    // State: drive/ + drive.new/ (no drive.old/) → crash before swap → discard drive.new/.
    let fm = FileManager.default
    let drive = root.appendingPathComponent("drive", isDirectory: true)
    let driveNew = root.appendingPathComponent("drive.new", isDirectory: true)
    try fm.createDirectory(at: drive, withIntermediateDirectories: true)
    try fm.createDirectory(at: driveNew, withIntermediateDirectories: true)
    try Data([1]).write(to: drive.appendingPathComponent("marker"))
    try Data([2]).write(to: driveNew.appendingPathComponent("marker"))

    OverlayConsolidator.recoverIfInterrupted(gameFolder: root)

    XCTAssertTrue(fm.fileExists(atPath: drive.path))
    XCTAssertFalse(fm.fileExists(atPath: driveNew.path))       // rolled back
    XCTAssertEqual(try Data(contentsOf: drive.appendingPathComponent("marker")), Data([1]))
}

func testRecoverRollsForwardWhenDriveOldAndDriveNewPresent() throws {
    // State: drive.old/ + drive.new/ (no drive/) → crash between renames → promote drive.new/.
    let fm = FileManager.default
    let driveOld = root.appendingPathComponent("drive.old", isDirectory: true)
    let driveNew = root.appendingPathComponent("drive.new", isDirectory: true)
    try fm.createDirectory(at: driveOld, withIntermediateDirectories: true)
    try fm.createDirectory(at: driveNew, withIntermediateDirectories: true)
    try Data([2]).write(to: driveNew.appendingPathComponent("marker"))
    try Data([0xFF]).write(to: root.appendingPathComponent("sockdrive-write.bin"))

    OverlayConsolidator.recoverIfInterrupted(gameFolder: root)

    let drive = root.appendingPathComponent("drive", isDirectory: true)
    XCTAssertTrue(fm.fileExists(atPath: drive.path))
    XCTAssertEqual(try Data(contentsOf: drive.appendingPathComponent("marker")), Data([2]))  // new promoted
    XCTAssertFalse(fm.fileExists(atPath: driveOld.path))
    XCTAssertFalse(fm.fileExists(atPath: root.appendingPathComponent("sockdrive-write.bin").path)) // overlay dropped
}

func testRecoverFinishesCleanupWhenDriveAndDriveOldPresent() throws {
    // State: drive/ + drive.old/ (no drive.new/) → crash after swap → delete drive.old/ + overlay.
    let fm = FileManager.default
    let drive = root.appendingPathComponent("drive", isDirectory: true)
    let driveOld = root.appendingPathComponent("drive.old", isDirectory: true)
    try fm.createDirectory(at: drive, withIntermediateDirectories: true)
    try fm.createDirectory(at: driveOld, withIntermediateDirectories: true)
    try Data([0xFF]).write(to: root.appendingPathComponent("sockdrive-write.bin"))

    OverlayConsolidator.recoverIfInterrupted(gameFolder: root)

    XCTAssertTrue(fm.fileExists(atPath: drive.path))
    XCTAssertFalse(fm.fileExists(atPath: driveOld.path))
    XCTAssertFalse(fm.fileExists(atPath: root.appendingPathComponent("sockdrive-write.bin").path))
}
```

- [ ] **Step 2: Run to verify it fails**

Run: the `-only-testing` command. Expected: `no member 'recoverIfInterrupted'`.

- [ ] **Step 3: Write minimal implementation**

```swift
    /// Repairs a consolidation interrupted by a crash. Idempotent; safe to call on
    /// every folder during GameStore.reload(). See the spec's crash-safety table.
    static func recoverIfInterrupted(gameFolder: URL) {
        let fm = FileManager.default
        let drive = gameFolder.appendingPathComponent("drive", isDirectory: true)
        let driveNew = gameFolder.appendingPathComponent("drive.new", isDirectory: true)
        let driveOld = gameFolder.appendingPathComponent("drive.old", isDirectory: true)
        let overlay = gameFolder.appendingPathComponent("sockdrive-write.bin")
        let hasDrive = fm.fileExists(atPath: drive.path)
        let hasNew = fm.fileExists(atPath: driveNew.path)
        let hasOld = fm.fileExists(atPath: driveOld.path)

        if hasNew && hasDrive && !hasOld {
            try? fm.removeItem(at: driveNew)                 // rollback
        } else if hasNew && hasOld && !hasDrive {
            try? fm.moveItem(at: driveNew, to: drive)        // roll forward (validated pre-swap)
            try? fm.removeItem(at: driveOld)
            try? fm.removeItem(at: overlay)
        } else if hasDrive && hasOld && !hasNew {
            try? fm.removeItem(at: driveOld)                 // finish cleanup
            try? fm.removeItem(at: overlay)
        }
        // Any other combination (e.g. only drive/) is already consistent → no-op.
    }
```

- [ ] **Step 4: Run to verify it passes**

Run: the `-only-testing` command. Expected: `Executed 7 tests, with 0 failures`.

- [ ] **Step 5: Commit**

```bash
git add Sources/OverlayConsolidator.swift Tests/OverlayConsolidatorTests.swift
git commit -m "OverlayConsolidator: crash-recovery sweep

Co-Authored-By: Claude Fable 5 <noreply@anthropic.com>"
```

---

## Task 6: Game identity marker + reset flag

**Files:**
- Modify: `Sources/Game.swift` (Game struct, after `sockdriveRestorablePath` ~line 84)
- Test: `Tests/GameStoreTests.swift`

- [ ] **Step 1: Write the failing test** (append to `GameStoreTests`)

```swift
func testNeedsIdbResetReflectsMarkerFile() throws {
    let src = tempRoot.appendingPathComponent("Win98.zip")
    try makeZip(at: src, entries: [("drive/sockdrive.metaj", Data("{}".utf8))])
    try store.importGame(from: src)
    let g = try XCTUnwrap(store.games.first)
    XCTAssertFalse(g.needsIdbReset)
    try Data().write(to: g.idbResetMarkerURL)
    XCTAssertTrue(g.needsIdbReset)
}
```

- [ ] **Step 2: Run to verify it fails**

Run: `... -only-testing:PocketDOSTests/GameStoreTests/testNeedsIdbResetReflectsMarkerFile test 2>&1 | grep -E "error:|no member"`
Expected: `value of type 'Game' has no member 'idbResetMarkerURL'`.

- [ ] **Step 3: Write minimal implementation** (add to `Game`, near `sockdriveRestorablePath`)

```swift
    /// One-shot marker written by OverlayConsolidator: the next boot must reset the
    /// drive's IndexedDB "write" store (the folded-in install writes are stale there).
    var idbResetMarkerURL: URL { folderURL.appendingPathComponent(".pdos-idbreset") }
    var needsIdbReset: Bool { FileManager.default.fileExists(atPath: idbResetMarkerURL.path) }
```

- [ ] **Step 4: Run to verify it passes** — Expected: PASS.

- [ ] **Step 5: Commit**

```bash
git add Sources/Game.swift Tests/GameStoreTests.swift
git commit -m "Game: idbReset marker for post-consolidation boots

Co-Authored-By: Claude Fable 5 <noreply@anthropic.com>"
```

---

## Task 7: Recovery sweep in GameStore.reload()

**Files:**
- Modify: `Sources/Game.swift` (`GameStore.reload()`)
- Test: `Tests/GameStoreTests.swift`

- [ ] **Step 1: Write the failing test**

```swift
func testReloadRecoversInterruptedConsolidation() throws {
    // A game folder mid-swap: drive.old/ + drive.new/ (no drive/). reload() must
    // roll forward via OverlayConsolidator and then load the game.
    let dir = try makeGameFolder()
    let driveOld = dir.appendingPathComponent("drive.old", isDirectory: true)
    let driveNew = dir.appendingPathComponent("drive.new", isDirectory: true)
    try FileManager.default.createDirectory(at: driveNew, withIntermediateDirectories: true)
    try FileManager.default.createDirectory(at: driveOld, withIntermediateDirectories: true)
    try Data("{}".utf8).write(to: driveNew.appendingPathComponent("sockdrive.metaj"))

    store.reload()

    XCTAssertTrue(FileManager.default.fileExists(atPath: dir.appendingPathComponent("drive").path))
    XCTAssertFalse(FileManager.default.fileExists(atPath: driveNew.path))
    XCTAssertEqual(store.games.count, 1, "the recovered drive loads as a sockdrive game")
}
```

- [ ] **Step 2: Run to verify it fails** — Expected: FAIL (game not loaded; drive.new/ still present).

- [ ] **Step 3: Write minimal implementation** — in `reload()`, inside the `for dir in dirs` loop, BEFORE the `loadGame` call, add the sweep:

```swift
        for dir in dirs {
            let isDir = (try? dir.resourceValues(forKeys: [.isDirectoryKey]))?.isDirectory ?? false
            guard isDir else { continue }
            OverlayConsolidator.recoverIfInterrupted(gameFolder: dir)   // <-- add
            if let game = loadGame(in: dir) {
                found.append(game)
            } else {
                orphans.append(OrphanedInstall(id: dir.lastPathComponent, url: dir,
                                               sizeBytes: Self.folderSize(at: dir)))
            }
        }
```

- [ ] **Step 4: Run to verify it passes** — Expected: PASS. Then run the whole `GameStoreTests` class to confirm no regressions.

- [ ] **Step 5: Commit**

```bash
git add Sources/Game.swift Tests/GameStoreTests.swift
git commit -m "GameStore: recover interrupted consolidations on reload

Co-Authored-By: Claude Fable 5 <noreply@anthropic.com>"
```

---

## Task 8: Orchestrator — non-fatal `consolidating` stage

Wiring the engine into the install flow. The async orchestrator isn't unit-tested here (its logic lives in device runs); the change is verified by the full build + a device run (Task 11). Keep it minimal and non-fatal.

**Files:**
- Modify: `Sources/InstallOrchestrator.swift` (State enum ~line 97; `run()` ~line 262)

- [ ] **Step 1: Add the state case** — in `enum State`, after `case applyingMouseFix`:

```swift
        case applyingMouseFix
        /// Post-install: fold the write-overlay into the chunks (non-fatal).
        case consolidating
        case done(gameId: String)
```

- [ ] **Step 2: Call it after finalize** — in `run()`, between `try await finalize(...)` and `state = .done(...)`:

```swift
            try await finalize(store: store, gameId: gameId, folder: gameFolder, shared: shared)
            await consolidate(store: store, folder: gameFolder)   // <-- add; non-throwing
            state = .done(gameId: gameId)
```

- [ ] **Step 3: Implement the non-fatal step** — add near `finalize` (a new private method):

```swift
    /// Folds the freshly-installed overlay into the chunks so future boots skip the
    /// reseed. NON-FATAL: any failure logs a breadcrumb, leaves the original
    /// chunks + overlay intact, and the install still reports done.
    private func consolidate(store: GameStore, folder: URL) async {
        state = .consolidating
        do {
            try await Task.detached(priority: .utility) {
                try OverlayConsolidator.consolidate(gameFolder: folder)
            }.value
            print("[pdos-install] consolidate ok")
        } catch {
            print("[pdos-install] consolidate-skipped \(error.localizedDescription)")
        }
        store.reload()
    }
```

- [ ] **Step 4: Build + run the full suite**

Run: `DEVELOPER_DIR=/Applications/Xcode-beta.app/Contents/Developer xcodebuild -project PocketDOS.xcodeproj -scheme PocketDOS -destination 'id=4C6AE55C-CD39-4A82-976F-396D8A0C750E' CODE_SIGNING_ALLOWED=NO test 2>&1 | grep -E "Executed [0-9]+ tests|BUILD (FAILED|SUCCEEDED)|error:" | tail -6`
Expected: `** TEST SUCCEEDED **`, total count up by the new tests (Task 2/3/4/5/6/7). If a progress-UI mapping references `State` exhaustively (a `switch` over states), add a `.consolidating` arm mirroring `.applyingMouseFix` — grep `applyingMouseFix` in `Sources/` and handle each site.

- [ ] **Step 5: Commit**

```bash
git add Sources/InstallOrchestrator.swift Sources/*.swift
git commit -m "InstallOrchestrator: non-fatal consolidating stage after install

Co-Authored-By: Claude Fable 5 <noreply@anthropic.com>"
```

---

## Task 9: SharedEmulator — pass idbreset, clear one-shot

**Files:**
- Modify: `Sources/SharedEmulator.swift` (`startURL` sockdrive branch ~line 97; launch site ~line 57)

- [ ] **Step 1: Add the query param** — in the `if game.isSockdrive {` branch of `startURL`, after the `restore=` line:

```swift
            if let srp = game.sockdriveRestorablePath { s += "&restore=" + enc(abs(srp)) }
            if game.needsIdbReset { s += "&idbreset=1" }   // <-- add
            return URL(string: s + fpsParam) ?? BundleSchemeHandler.startURL
```

- [ ] **Step 2: Clear the marker one-shot at the launch site** — find the launcher (line ~55-57, `webView.load(URLRequest(url: Self.startURL(for: game)))`). After the load, clear the marker so only the next boot resets:

```swift
        webView.load(URLRequest(url: Self.startURL(for: game)))
        if game.needsIdbReset { try? FileManager.default.removeItem(at: game.idbResetMarkerURL) }
```

(Read the exact surrounding lines first; keep `startURL` pure — the deletion lives at the call site, not inside the URL builder.)

- [ ] **Step 3: Build**

Run: the `build` command from Task 1 Step 3. Expected: `** BUILD SUCCEEDED **`.

- [ ] **Step 4: Commit**

```bash
git add Sources/SharedEmulator.swift
git commit -m "SharedEmulator: one-shot idbreset param for consolidated drives

Co-Authored-By: Claude Fable 5 <noreply@anthropic.com>"
```

---

## Task 10: index.html — clear the IndexedDB write store on idbreset

**Files:**
- Modify: `Web/index.html` (`reseedSockdriveWrites` ~line 428; `bootFromSockdrive` ~line 552; the `?drive=` query dispatch)

- [ ] **Step 1: Add a clear function** — next to `reseedSockdriveWrites` (mirror it; delete key 0 of "write"):

```javascript
    // Post-consolidation: the folded-in install writes are stale in IndexedDB. Empty the
    // "write" store BEFORE mount so the drive boots from the (now merged) chunks alone.
    function clearSockdriveWrites(base) {
      return new Promise((resolve) => {
        let req;
        try { req = indexedDB.open("sockdrive (" + base + ")", 1); }
        catch (e) { console.warn("[pdos-sock] idbreset open threw: " + (e && e.message ? e.message : e)); resolve(false); return; }
        req.onupgradeneeded = (ev) => {
          const db = ev.target.result;
          if (!db.objectStoreNames.contains("raw")) { db.createObjectStore("raw").createIndex("sector", "", { multiEntry: false }); }
          if (!db.objectStoreNames.contains("write")) { db.createObjectStore("write").createIndex("sector", "", { multiEntry: false }); }
        };
        req.onerror = () => { console.warn("[pdos-sock] idbreset open failed"); resolve(false); };
        req.onsuccess = () => {
          const db = req.result;
          try {
            const tx = db.transaction("write", "readwrite");
            tx.objectStore("write").clear();
            tx.oncomplete = () => { console.log("[pdos-install] idbreset cleared write store for " + base); db.close(); resolve(true); };
            tx.onerror = () => { console.warn("[pdos-sock] idbreset clear failed"); db.close(); resolve(false); };
          } catch (e) { console.warn("[pdos-sock] idbreset txn threw: " + (e && e.message ? e.message : e)); db.close(); resolve(false); }
        };
      });
    }
```

- [ ] **Step 2: Thread the flag into `bootFromSockdrive`** — change its signature and, before the reseed, honor the reset:

```javascript
    async function bootFromSockdrive(base, memMb, restoreUrl, idbReset) {
      log("booting from sockdrive: " + base);
      window.__pdosSockBase = base;
      if (idbReset) { await clearSockdriveWrites(base); }   // <-- add, before reseed
      const writes = await loadRestoreInitFs(restoreUrl);
      if (writes) await reseedSockdriveWrites(base, writes);
      // ...unchanged...
    }
```

- [ ] **Step 3: Parse `idbreset` at the `?drive=` dispatch** — find where `bootFromSockdrive` is called with the parsed `restore` param (grep `bootFromSockdrive(` in `Web/index.html`), and pass the new flag:

```javascript
    // where params are read (e.g. const restore = qs.get("restore"); ...):
    const idbReset = qs.get("idbreset") === "1";
    // where the call happens:
    bootFromSockdrive(base, mem, restoreUrl, idbReset);
```

(Match the existing param-reading style in that block — use the same query-parsing object the file already uses.)

- [ ] **Step 4: Sanity-check served file** — `Web/` is a folder reference (no build step). Confirm the edit is well-formed JS:

Run: `node -e "require('fs').readFileSync('Web/index.html','utf8'); console.log('read ok')"` (a smoke check that the file is readable; there's no JS bundler). Then rely on the device run (Task 11) — the IndexedDB reset is not unit-testable.

- [ ] **Step 5: Commit**

```bash
git add Web/index.html
git commit -m "index.html: clear IndexedDB write store on idbreset boot

Co-Authored-By: Claude Fable 5 <noreply@anthropic.com>"
```

---

## Task 11: Full verification + device run

**Files:** none (verification only)

- [ ] **Step 1: Full suite green**

Run: `DEVELOPER_DIR=/Applications/Xcode-beta.app/Contents/Developer xcodebuild -project PocketDOS.xcodeproj -scheme PocketDOS -destination 'id=4C6AE55C-CD39-4A82-976F-396D8A0C750E' CODE_SIGNING_ALLOWED=NO test 2>&1 | grep -E "Executed [0-9]+ tests|TEST (SUCCEEDED|FAILED)" | tail -3`
Expected: `** TEST SUCCEEDED **`; total = prior 222 + ~9 new consolidator/store tests.

- [ ] **Step 2: Product-key leak check**

Run the product-key sentinel check — grep for the key's first group (see `HANDOFF-2026-07-06.md`; the literal token is intentionally NOT written here so this doc never trips the check):
`grep -rn "<key-first-group>" Sources/ Tests/ Web/ docs/ || echo clean`
Expected: `clean`.

- [ ] **Step 3: Device run (the only way to verify idbreset + real-drive fold)** — user rebuilds to their iPhone and runs a full Win98 install. Watch the Xcode console for:
  - `[pdos-install] consolidate ok` (or `consolidate-skipped <reason>` — non-fatal either way; the game still ships).
  - On the finished game's **first** launch: `[pdos-install] idbreset cleared write store for lib/<id>/drive`.
  - Confirm the game boots to the desktop and the mouse works, and that the **second** boot is visibly faster with no reseed (no long "restoring N bytes" pause).
  - Confirm footprint dropped (the `sockdrive-write.bin` is gone; `Documents/Games/<id>/` is ~150 MB, not ~300 MB).

- [ ] **Step 4: If consolidation fails on device** — it's non-fatal, so the game still works with the reseed. Capture the `consolidate-skipped` reason; the likely first suspects are the metaj decode (a geometry field mismatch) or a validation mismatch (an LBA/offset bug in `fold`). Re-open the spec's "Open risks" and the fold offset math.

---

## Self-Review

**Spec coverage:**
- Chunk-wise fold → Task 2. ✓
- Sample-sector validation (+ on-device gate) → Task 3. ✓
- Atomic swap + delete overlay + preserve identity (meta.json untouched) → Task 4 (never writes meta.json). ✓
- Crash-recovery table (3 reachable states) → Task 5 + Task 7 (reload sweep). ✓
- Non-fatal final `consolidating` stage after mouse fix → Task 8. ✓
- One-shot `idbreset` (marker → param → clear) → Tasks 6, 9, 10. ✓
- Testing plan (fold/drop/metaj/validation/recovery/identity/non-fatal) → Tasks 2–7. ✓
- Non-goals (imported games, manual button) → not implemented, as intended. ✓

**Placeholder scan:** No "TBD"/"handle edge cases"/"similar to". Two tasks (8, 10) are explicitly device-verified rather than unit-tested, with the reason stated (async orchestrator; IndexedDB) — honest, not a placeholder.

**Type consistency:** `OverlayConsolidator.consolidate/fold/validate/recoverIfInterrupted` and `Game.idbResetMarkerURL/needsIdbReset` and marker name `.pdos-idbreset` are used identically across tasks. `SockdriveChunker.Metaj` field names match `Sources/SockdriveChunker.swift`. `bootFromSockdrive(base, memMb, restoreUrl, idbReset)` signature matches its Task-10 call site.

**Note (resolved 2026-07-08):** confirmed `parse(overlay:)` decodes BOTH raw-516 and LZ4 records into decoded 512-byte sectors (`Sources/FAT32OverlayEditor.swift` `lz4BlockDecode`), so the fold receives plain sectors — no extra decode step needed.
