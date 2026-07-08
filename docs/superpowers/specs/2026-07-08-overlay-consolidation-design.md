# Overlay Consolidation — design spec

**Status:** approved design, pre-implementation
**Date:** 2026-07-08
**Scope:** PocketDOS v1.1, item #4 (see `docs/V1.1-PLAN.md`)

## Problem

A Win98 machine built by the install wizard boots as `(pristine chunks + write
overlay)`. Because the unattended install writes the entire OS as sockdrive write
records on top of a blank-C: template, the overlay (`sockdrive-write.bin`) is ~154 MB
while the chunks are nearly empty. Every boot **reseeds** that 154 MB overlay into an
in-memory store (and IndexedDB) before the guest runs — the same serialize/copy churn
behind the stage-2 OOM roulette, paid on every launch.

**Goal:** fold the overlay into the chunk set once, after install, so future boots load
`(150 MB chunks, no overlay)` — no reseed, roughly half the footprint, and the memory
spike gone.

## Background (facts the design relies on)

- **Overlay format** (`sockdrive-write.bin`, `FAT32OverlayEditor` doc): u32le record
  count, then per record u32le blockLen + block; blockLen==516 → raw u32le absolute LBA
  + 512 bytes, else an LZ4 block decoding to the same 516. Records replay in order,
  later supersedes earlier.
- **Chunk format** (`SockdriveChunker`): 256 KiB chunk files `<i>.raw`; all-zero ranges
  produce **no file** and are listed in the metaj `dropped_ranges`; the client
  synthesizes zeros for them. Geometry in the metaj comes from a template matched by
  exact byte size. `preload_ranges` is a hint list filtered to in-bounds, non-dropped
  ranges.
- **Composite read** (`FAT32OverlayEditor.compositeRead`): a sector = overlay record if
  present, else the backing chunk, else zeros. This is already the exact precedence the
  client uses.
- **Boot path** (`Game.sockdriveRestorablePath`, `Web/index.html`): a game with no
  `sockdrive-write.bin` has a nil restore path and "boots from the pristine chunks (no
  &restore= param)". So deleting the overlay is what removes the reseed.
- **Identity** (`Game.contentHash`, `GameStore.loadGame`): `contentHash` is stored in
  `meta.json` and only *derived* from the metaj when nil. It is the (future) iCloud
  save-sync key and the library's stable game identity.
- **IndexedDB**: the client reseeds `sockdrive-write.bin` into an IndexedDB "write" store
  keyed by the drive base (`lib/<id>/drive`, unchanged by consolidation). Persisted
  writes therefore survive across launches independent of the file.

## Non-goals (deferred)

- Consolidating **imported** sockdrive games, or games that grew large from **play**.
  The engine is game-agnostic, so these are cheap to add later as new triggers; v1.1
  only wires the post-install trigger.
- A manual "Optimize" button.
- Compressing chunks or the overlay.

## Architecture

Two components — this is **not** purely native:

### 1. `OverlayConsolidator` (new, `Sources/OverlayConsolidator.swift`, Foundation-only)

Pure engine, unit-tested like the other install engines. Input: a game folder holding
`drive/` (chunks + metaj) and `sockdrive-write.bin`. Output: `drive/` rewritten with the
overlay folded in and `sockdrive-write.bin` deleted. Reuses `FAT32OverlayEditor`'s
composite read and mirrors `SockdriveChunker`'s metaj rules.

### 2. `index.html` one-shot `idbreset`

A boot-path addition: when a game is launched with a one-shot `idbreset` signal, the page
empties the drive's IndexedDB "write" store **before** mounting, then proceeds. **Required
for correctness** — without it, the install writes linger in IndexedDB and reseed
themselves even after `sockdrive-write.bin` is deleted, erasing the win. Modeled on the
existing one-shot `PDOSRAN.FLG` pattern.

## Data flow

```
consolidate(gameFolder) throws:
  let editor = FAT32OverlayEditor(overlay: sockdrive-write.bin, chunks: drive/)
  let old = read old metaj (geometry: name, cyl, heads, sectors, sector_size, size,
                            ahead_read, range_count, preload_ranges)

  make drive.new/ (must not pre-exist):
    var dropped = []
    for range in 0..<range_count:
      chunk = concat(editor.readSector(lba) for the 512 lbas of this range)   // overlay wins
      if chunk all-zero: dropped.append(range)          // no file, matches SockdriveChunker
      else: write drive.new/<range>.raw  (exactly 256 KiB)
    write drive.new/sockdrive.metaj:
      same geometry as old; dropped_ranges = dropped;
      preload_ranges = old.preload filtered to (< range_count && not dropped)

  validate(drive.new/) or throw            // see Testing → safety invariant

  swap (see Crash-safety):
    rename drive → drive.old
    rename drive.new → drive
    delete sockdrive-write.bin
    delete drive.old

  // meta.json is untouched → contentHash (identity) preserved
  // caller arms the one-shot idbreset for this game's next boot
```

`range_count`, geometry, and `size` are unchanged (same template) — only `dropped_ranges`
shrinks (chunks the overlay filled) or, rarely, grows (a chunk the overlay zeroed).

## Crash-safety

The original `drive/` and `sockdrive-write.bin` are **untouched until the swap**, so any
crash during build/validate rolls back for free: discard `drive.new/`, the original still
boots.

A **recovery sweep** in `GameStore.reload()` handles an interrupted swap. Renames within
the game folder are atomic (same filesystem), so only whole-step states are observable —
keyed on the transient dirs:

| Present on load | Recovery |
|---|---|
| `drive/` + `drive.new/` (no `drive.old/`) | Crash before the swap. Rollback: delete `drive.new/`; original `drive/` + overlay intact. |
| `drive.old/` + `drive.new/` (no `drive/`) | Crash between the two renames. `drive.new/` was validated before the swap began → roll forward: rename `drive.new/`→`drive/`, delete `drive.old/`, delete the overlay. |
| `drive/` + `drive.old/` (no `drive.new/`) | Crash after the swap, before cleanup. New chunks are live and validated → delete `drive.old/`, delete the overlay if still present. |

Validation is a precondition of the first rename, so the mere presence of `drive.old/`
proves the new chunk set passed — recovery can safely roll forward rather than guess.

Invariant: the overlay is **never** deleted until the new chunks are live, so at every
point the drive is bootable from *some* consistent state. Worst case a consolidation is
redone; corruption is impossible.

## Trigger integration (`InstallOrchestrator`)

Add a final stage **after** `applyingMouseFix` (the mouse fix appends dboxmpi records to
the overlay, so consolidation must run after to fold them in) and before `done`:

```
buildingMedia → stage1 → stage2 → stage3 → applyingMouseFix → consolidating → done
```

- Shown as "Optimizing for faster boots…". Emulator is already torn down → no memory
  competition, and no chance of the game booting mid-swap (zero concurrency).
- **Non-fatal:** if `consolidate` throws or validation fails, log a `[pdos-install]
  consolidate-skipped <reason>` breadcrumb, leave the original `chunks + overlay` intact,
  and mark the install **done anyway**. The user gets a working game (with the reseed);
  an optimization must never fail a 40-minute install.
- On success, arm the one-shot `idbreset` for the game.

## Identity

`meta.json`'s `contentHash` is preserved verbatim (never recomputed during
consolidation). The game keeps its identity across the re-pack even though the metaj bytes
change, because `loadGame` only backfills the hash when it is nil.

## Testing (TDD)

Engine is pure and filesystem-backed (temp dirs), like `SockdriveChunkerTests` /
`FAT32OverlayEditorTests`:

1. **mtools oracle** (as inc 4 used): after consolidating a synthetic
   `(chunks + overlay)`, mount `drive.new/` and assert a known file reads back
   byte-identical to its composite read from the original.
2. **Safety invariant** (also the on-device pre-swap gate): for critical LBAs (boot
   sector, FAT start, root dir, a sentinel file) plus a random sample,
   `compositeRead(old chunks ∥ overlay) == compositeRead(new chunks ∥ empty)`.
3. **Drop correctness**: a range the overlay fully zeroes ends up in `dropped_ranges` with
   no file; a range the overlay fills is removed from `dropped_ranges` with a file.
4. **metaj**: geometry/size/range_count/preload unchanged except the drop set; encodes
   byte-identically to `SockdriveChunker`'s rules (sorted keys).
5. **Crash recovery**: construct each interrupted state from the table above → the reload
   sweep restores a bootable drive.
6. **Identity preserved**: `contentHash` unchanged after consolidate.
7. **Non-fatal**: a consolidate that throws leaves `drive/` + overlay byte-identical to
   before.

The `idbreset` boot-path change is verified on device (one install run), since the
IndexedDB reset is not reproducible in the unit layer.

## Open risks

- **Device time/disk**: rewriting ~150 MB of chunks + a transient `drive.new/` copy. Both
  are within iPhone budgets, but the actual wall-clock is a device-run unknown; the
  progress UI must not look hung (periodic breadcrumb).
- **idbreset mechanics**: the exact IndexedDB store name/key must match what the client
  uses (`"sockdrive (<base>)"`, store "write", key 0 — per `Game.swift`). Confirm against
  the client at implementation time.
