# PocketDOS

A not-for-profit, GPL-2.0 iOS app that plays DOS and Windows 9x software on
iPhone. It runs [js-dos](https://github.com/caiiiycuk/js-dos) — DOSBox and
DOSBox-X compiled to WebAssembly — inside a `WKWebView`, where WebKit's WASM
JIT executes in Apple's own out-of-process WebContent process. That makes the
speed of a JIT available to an ordinary, App-Store-legal app: no JIT
entitlement, no sideloading tricks. iPhone-first, iOS 17+.

> **Status:** working app, runs on device. DOS, Windows 3.x, and Windows 98 SE
> all run at usable speed. The headline experimental feature — an unattended,
> on-device **Windows 98 install wizard** that builds a bootable Win98 machine
> from *your own* CD image and product key — has completed end-to-end on real
> hardware. It is labeled experimental in the app, and it means it.

PocketDOS ships **zero Microsoft content** and no copyrighted games or ROMs.
Everything it emulates comes from media you supply.

## Table of contents

- [Features](#features)
- [The Windows 98 install wizard](#the-windows-98-install-wizard)
- [Architecture](#architecture)
  - [One shared WKWebView](#one-shared-wkwebview)
  - [BundleSchemeHandler and the pocketdos:// origin](#bundleschemehandler-and-the-pocketdos-origin)
  - [The custom wdosbox-x build](#the-custom-wdosbox-x-build)
  - [Sockdrive disks and the persist/reseed checkpoint model](#sockdrive-disks-and-the-persistreseed-checkpoint-model)
  - [The install orchestrator](#the-install-orchestrator)
- [Building](#building)
- [Tests](#tests)
- [Legal & licensing](#legal--licensing)
- [Status & roadmap](#status--roadmap)

## Features

- **Game library** — a tile-grid library with import from the Files app
  (`.jsdos` bundles, `.zip` archives, and zipped sockdrive drives — a `.zip`
  containing a `sockdrive.metaj` manifest imports as a hard-disk machine).
  Rename, delete, per-game settings; everything lives under
  `Documents/Games/<id>/` and is visible in the Files app.
  (`Sources/Game.swift`, `Sources/LibraryView.swift`)
- **Session persistence** — js-dos has no CPU save-state, so PocketDOS
  captures the emulator's *disk delta*: `changes.jsdos` (filesystem delta) for
  ordinary games, `sockdrive-write.bin` (sector diff) for hard-disk machines.
  Autosave every 3 minutes, save on quit and on backgrounding, **F6 =
  quick-save / F7 = quick-load** on a hardware keyboard, and per-game "Reset
  saved session". (`Sources/EmulatorController.swift`)
- **iCloud save sync** — save deltas (≤ 20 MB) sync via iCloud Drive, keyed by
  a content hash so a re-imported game finds its saves; large disk images stay
  local. Gracefully local-only when iCloud isn't available on the signing
  account. (`Sources/CloudSaveSync.swift`)
- **Controls** — three per-game profiles: `fps` (D-pad + Ctrl/Space/Alt/Shift
  action cluster + weapon keys), `mouse` (tap-to-click with an explicit
  right-click button, for point-and-click adventures), or `off`. Hardware
  keyboards and game controllers work via the GameController framework, with
  per-game remapping. (`Sources/ControllerInput.swift`,
  `Sources/GameControls.swift`)
- **Per-game emulated RAM + DOS config editing** — a `memsize` override (the
  dial that fits Win98 SE under the WASM memory ceiling) and an append-style
  `dosbox.conf` editor with one-tap presets: Sound Blaster IRQ, General MIDI,
  MT-32, FM-only. (`Sources/ConfigEditorView.swift`)
- **Audio** — Sound Blaster digital audio and AdLib/OPL FM out of the box;
  **General MIDI** via FluidSynth with a bundled GPL SoundFont (TimGM6mb);
  **Roland MT-32** via mt32emu with *user-supplied* ROMs (imported in-app,
  `.zip` games only). Both synths are compiled into a custom DOSBox-X WASM —
  see [below](#the-custom-wdosbox-x-build). Sound plays regardless of the
  silent switch (iOS 17 `navigator.audioSession`). (`Web/index.html`)
- **Offline and private** — every asset is served from the app bundle over a
  custom scheme; top-level navigation anywhere else is refused. No telemetry,
  no analytics, no network calls of the app's own.
  (`Sources/EmulatorWebView.swift`)

## The Windows 98 install wizard

**Experimental.** Library **+** menu → *New Windows 98 machine*. You provide
two things you already own:

1. a **Windows 98 Second Edition CD image** (`.iso`), read once during the
   install and never copied off-device, and
2. your **product key**, held in memory only — never stored, logged, or sent
   anywhere.

From those, entirely on-device, the wizard builds and boots a real Windows 98
machine:

- reads the ISO (ISO9660/ECMA-119) and extracts its **El Torito boot floppy**,
  then rewrites the floppy in place for unattended use
  (`Sources/ISO9660.swift`, `Sources/FAT12Floppy.swift`);
- builds a FAT16 install-source disk holding the CD's `\WIN98` cabinets plus a
  generated `MSBATCH.INF` answer file, and chunks it for streaming
  (`Sources/FAT16ImageBuilder.swift`, `Sources/SockdriveChunker.swift`,
  `Sources/InstallMediaBuilder.swift`);
- runs Microsoft Setup **unattended** through a staged, crash-recovering
  orchestration (file copy → scripted wizard pages → first boot to desktop),
  checkpointing the drive after every accepted write so engine restarts
  *resume* instead of starting over (`Sources/InstallOrchestrator.swift`,
  `Sources/InstallFlow.swift`);
- finishes by injecting the GPL-compatible DOSLIB mouse-integration driver
  directly into the finished FAT32 volume, so the touch cursor works on the
  Windows desktop (`Sources/FAT32OverlayEditor.swift`).

The result appears in the library as a normal game: a bootable Windows 98
machine with working touch/mouse input and persistent disk state.

Honest expectations: the full install runs **30–60 minutes unattended**. On
iPhone-class memory the emulator's WebContent process can be killed and the
WASM engine can panic mid-install; the orchestrator expects this — stages have
retry budgets, reboot boundaries are detected, and a post-panic "final flush"
captures the guest's last disk writes — but the feature is young. If an
install fails it fails cleanly (nothing half-registered in the library), and
the app ships no cleanup UI yet for partial install folders.

The app bundle contains only three install assets, none of them Microsoft's:
a **blank, self-generated FAT32 drive template** (empty filesystem structures
made with mtools — see `tools/make-win98-install-media.sh`), and the **DOSLIB
`dboxmpi` mouse driver** (`.drv` + `.inf`, LGPL-2.1). Everything else is
derived from your CD at install time and stays on your device.

## Architecture

A contributor-oriented tour. One paragraph per subsystem, with the file to
read next.

### One shared WKWebView

iOS does not reliably reap a dismissed `WKWebView`'s WebContent process, so a
web-view-per-game design leaks a ~300–400 MB zombie per launch and OOMs by the
third game. PocketDOS therefore keeps **one** `WKWebView` and one
`EmulatorController` for the app's lifetime (`Sources/SharedEmulator.swift`).
Leaving a game tears the page down and navigates to
`pocketdos://app/blank.html` — a *same-scheme* blank page, deliberately not
`about:blank`, because the same-protocol navigation path reuses the existing
WebContent process and reclaims its heap in place. The install wizard drives
this same shared web view.

### BundleSchemeHandler and the pocketdos:// origin

`Sources/BundleSchemeHandler.swift` serves the bundled `Web/` directory and
imported games (under `lib/<id>/…`) over a custom `pocketdos://app/…` scheme,
so the emulator, its assets, and user games are all one origin — no embedded
HTTP server, no CORS, no network entitlement. It sets correct MIME types
(critically `application/wasm`, so `WebAssembly.instantiateStreaming` works
and WebKit's WASM JIT engages), enforces path containment with a
trailing-slash boundary check (not a naive prefix match), and applies three
cache tiers: `lib/` (mutable game data) is `no-store`; `emulators/` (the
multi-megabyte WASM runtime) is `immutable`; everything else — the harness —
is `no-cache` so a rebuilt `index.html` is never served stale.
`Sources/EmulatorWebView.swift` completes the lockdown: any top-level
navigation to a scheme other than `pocketdos:` or `about:` is cancelled.

### The custom wdosbox-x build

Stock js-dos ships DOSBox-X with a MIDI *dispatcher* but no synthesizer
linked, so General MIDI and MT-32 music are silent. PocketDOS vendors a
**rebuilt** `Web/emulators/wdosbox-x.wasm` with **FluidSynth**
(LGPL-2.0-or-later) and **mt32emu/MUNT** (LGPL-2.1-or-later) compiled in and
statically linked. The complete rebuild recipe — upstream repos, the
Emscripten 6.0.0 toolchain requirement and why the js-dos-pinned 3.1.28
cannot build this module, and the two patches that make DOSBox-X's bundled
FluidSynth compile under Emscripten — lives in
[`tools/midi-build/BUILD.md`](tools/midi-build/BUILD.md) with the patches in
`tools/midi-build/patches/`. This doubles as the GPL corresponding-source
offer for the modified binary. The rest of the `Web/` runtime is stock js-dos
v8, synced by `scripts/sync-jsdos.sh`.

### Sockdrive disks and the persist/reseed checkpoint model

Win9x-sized hard disks can't be loaded whole into a browser process, so they
use js-dos's *sockdrive* layout: the image is split into 256 KiB chunks
(`<range>.raw` + a `sockdrive.metaj` manifest; all-zero ranges cost nothing),
served on demand through the scheme handler, and **guest writes accumulate in
an in-memory overlay** on top. `Sources/SockdriveChunker.swift` is a Swift
implementation of the chunker; the harness (`Web/index.html`) exposes the
overlay lifecycle to native code: *persist* serializes the write-overlay and
streams it over the bridge (saved as `sockdrive-write.bin`), and *reseed*
(`window.pdosReseed`) injects a saved overlay back into IndexedDB **before**
the drive mounts, so the next boot sees its history. Ordinary play needs one
persist on save and one reseed on launch; the install wizard turns the same
two primitives into a checkpointing transport.

### The install orchestrator

`Sources/InstallOrchestrator.swift` (a `@MainActor` driver for the shared web
view) and `Sources/InstallFlow.swift` (the pure, unit-tested half: stage
machine, retry budgets, capture cadence, injected-JS builders) run Windows
Setup through five states: `buildingMedia → stage1FileCopy → stage2Script →
stage3Finalizing → applyingMouseFix`. The harness emits `[pdos-install]`
console breadcrumbs (`ci-ready`, `captured <sectors> <bytes>`,
`capture-regressed`, panic re-emissions); the orchestrator parses them to
detect progress, guest reboots (a *reboot boundary* — pin the last good
overlay from the still-alive page, reload, reseed, continue), engine death
(retry the stage from its checkpoint, within a budget and per-stage
deadline), plateaus (write counts converge → probe with a keystroke cycle
before trusting that Setup is really done), and panics (a *final flush* races
one last persist out of the dying page, because Setup writes its continuation
flags in its final seconds). Stage 2's wizard pages that `MSBATCH.INF` cannot
answer are advanced by an idempotent scripted keystroke cycle. It is the
long-distance version of the same persist/reseed model that powers ordinary
save games.

## Building

Requires Xcode 26+ and [XcodeGen](https://github.com/yonaskolb/XcodeGen)
(`brew install xcodegen`). `ZIPFoundation` resolves automatically via Swift
Package Manager.

```sh
xcodegen generate     # produces PocketDOS.xcodeproj from project.yml
open PocketDOS.xcodeproj
```

Command-line builds (substitute your Xcode path if `xcode-select` already
points at the right one — the `DEVELOPER_DIR` prefix is only needed when it
doesn't):

```sh
# Simulator build
DEVELOPER_DIR=/Applications/Xcode-beta.app/Contents/Developer \
  xcodebuild build -scheme PocketDOS \
  -destination 'platform=iOS Simulator,name=iPhone 17' \
  CODE_SIGNING_ALLOWED=NO

# Full test suite
DEVELOPER_DIR=/Applications/Xcode-beta.app/Contents/Developer \
  xcodebuild test -scheme PocketDOS \
  -destination 'platform=iOS Simulator,name=iPhone 17' \
  CODE_SIGNING_ALLOWED=NO
```

Notes that save time:

- Build the **scheme**, not a bare target — SwiftPM dependencies resolve
  through the scheme.
- Don't delete the build directory to "fix" a wedged incremental build. If
  xcodebuild dies with *"no more rows available"*, delete only
  `DerivedData/…/Intermediates.noindex/XCBuildData/build.db` and rebuild.
- Running on a device requires your own Apple signing team (set it in
  Signing & Capabilities after `xcodegen generate`). The iCloud save-sync
  capability additionally needs an iCloud container on that account; without
  it the app runs local-only.
- SourceKit sometimes reports phantom "module not found" errors in the editor
  for a project that builds cleanly; trust `xcodebuild`.

## Tests

The logic layer is covered by **218 unit tests** across 14 files
(`Tests/`): the ISO9660/El Torito reader, FAT12/FAT16/FAT32 builders and the
overlay editor (verified against mtools as an oracle), the sockdrive chunker
(byte-identical output to the reference implementation), the install stage
machine and its retry/boundary/plateau policies, the scheme handler's path
containment and MIME mapping, game import/library/MT-32 packaging, and
controller mapping. UI and the live emulator are exercised on device, not in
unit tests.

## Legal & licensing

- **License:** GPL-2.0 — see [LICENSE](LICENSE).
  Copyright © 2026 [Mantene](https://github.com/Mantene/PocketDos).
  PocketDOS is a derivative work of js-dos and DOSBox/DOSBox-X (both
  GPL-2.0), so the GPL is not just the chosen license but the required one.
- **Third-party components:** see [THIRD_PARTY.md](THIRD_PARTY.md) for the
  full audited list — js-dos, DOSBox, DOSBox-X (GPL-2.0), FluidSynth
  (LGPL-2.0+), mt32emu (LGPL-2.1+), the TimGM6mb SoundFont (GPL-2.0), the
  DOSLIB mouse driver (LGPL-2.1), and ZIPFoundation (MIT).
- **Corresponding source for the modified emulator:** the shipped
  `wdosbox-x.wasm` differs from upstream; its patches and full rebuild recipe
  are in [`tools/midi-build/`](tools/midi-build/BUILD.md).
- **You supply the media.** The app bundles no games, no Microsoft software,
  no MT-32 ROMs, and no product keys. Windows installs derive entirely from
  your own CD image and license, on-device; MT-32 ROMs are imported from your
  own files; your CD image and key are read for the install and never
  transmitted anywhere. Never commit copyrighted games, OS images, or ROMs to
  this repository — the `.gitignore` quarantines the usual suspects, and the
  install-media dev script keeps its Microsoft-derived outputs out of the
  tree by design.
- **No telemetry.** There is no analytics or tracking of any kind, and the
  web layer's navigation policy refuses every scheme except the app's own
  bundle scheme (`Sources/EmulatorWebView.swift`), so the emulator cannot
  wander onto the network.
- **App Store:** distribution of this js-dos-based app through the App Store
  is gated on the js-dos author's consent (tracked in `SPEC.md` B9/M68); the
  repo and TestFlight-style personal builds are not.

## Status & roadmap

Working now, on device: the library, DOS and Windows 3.x/9x play, session
persistence, controls, GM/MT-32 audio, and one full unattended Windows 98 SE
install through the wizard.

V1 remainders, roughly in order:

- **Wizard hardening** — it has one clean end-to-end device run; it needs
  many. Known polish items: cleanup UI for failed partial installs (they
  currently linger invisibly under `Documents/Games/`), suppressing the
  Windows Welcome tour on first boot, and background consolidation of the
  write-overlay into base chunks (today each boot reseeds a ~150 MB overlay).
- **Editions** — the wizard supports **Windows 98 SE only**. 98 First
  Edition, 95 OSR2, and ME each need their own answer-file/keystroke
  profiles and are deferred.
- **Controllers** — MFi mapping is implemented but needs deeper testing on
  real hardware.
- **App Store preparation** — including the consent gate above and replacing
  any remaining non-original UI art.
- **iPad** — V2 (Stage Manager, external display, pointer support).

A separate, longer-term track — a native DOSBox Pure (libretro) core with a
real dynarec for sideloading — lives outside this repository and is out of
scope for V1. See [`SPEC.md`](SPEC.md) for the complete V1 specification and
decision log.
