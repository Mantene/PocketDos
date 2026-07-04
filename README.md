# PocketDOS

A not-for-profit, GPL-2 iOS app to play DOS games and run DOS/Windows-9x software
on iPhone (iPad in V2).

This repository is **Track A** of the project: the **App Store** track, which runs
[js-dos](https://github.com/caiiiycuk/js-dos) (WASM DOSBox / DOSBox-X) inside a
`WKWebView`. The WebView legitimately benefits from WebKit's WebAssembly JIT (which
runs in Apple's out-of-process WebContent), so no forbidden JIT entitlement is needed.
The native, dynarec-powered sideload track (DOSBox Pure / libretro) is a future,
separate effort and is out of scope for V1.

> Status: **working app, on device.** The Phase-0 risk (Win9x speed under WASM-JIT)
> is resolved — DOS, Windows 3.x, 95, and **98SE** all run at usable speed (the last
> unlocked by a per-game emulated-RAM override). See `SPEC.md` for the full V1 spec.

## Features

- **Native game library** — cover-art grid, import from Files (.jsdos / .zip),
  rename, delete, per-game settings; everything stored under `Documents/Games/<id>/`
  and visible in the Files app.
- **Emulation** — plain DOSBox for DOS titles; DOSBox-X auto-selected for Windows-9x
  and for games that need the richer audio backends. Per-game emulated-RAM override
  (the dial that fits Win98SE under the memory ceiling).
- **Audio** — AdLib/OPL + Sound Blaster, **General MIDI** via a bundled SoundFont, and
  **Roland MT-32** via user-supplied ROMs — both rendered by a custom DOSBox-X WASM
  with FluidSynth and mt32emu compiled in (see `tools/midi-build/BUILD.md`). Sound
  plays regardless of the silent switch (iOS 17 `navigator.audioSession`).
- **Session persistence** — js-dos has no CPU/RAM save-state, so PocketDOS captures the
  emulator's **filesystem delta** (in-game saves, an installed Win9x's changed HDD
  image) and restores it on next launch. Autosave on a timer, on pause, on quit, and on
  backgrounding; **F6 = quick-save, F7 = quick-load**; per-game "Reset saved session".
- **Controls** — on-screen D-pad/buttons (with haptics), a tap-to-click mouse mode for
  point-and-click adventures, a soft keyboard, and hardware-keyboard support.
  Gameplay is landscape-locked; the library rotates freely.
- **Per-game DOS config editor** — append `dosbox.conf` overrides (Sound Blaster IRQ,
  General MIDI, MT-32, FM) without leaving the app.
- **Offline & private** — all assets are served from the app bundle over a custom
  scheme; top-level navigation is restricted to that scheme, so nothing reaches the
  network. No telemetry.

## How it works

- `Sources/BundleSchemeHandler.swift` serves the bundled `Web/` directory (and imported
  games under `lib/<id>/...`) over a custom `pocketdos://app/...` scheme with correct
  MIME types — crucially `application/wasm`, so `WebAssembly.instantiateStreaming` works
  and the WebKit WASM JIT engages. No embedded HTTP server, no network entitlement.
- `Sources/EmulatorWebView.swift` hosts the `WKWebView`, bridges native menu/key/persist
  actions into the page, restricts navigation to the custom scheme, and forwards JS
  `console.*` / errors to Xcode (prefixed `[web]`).
- `Sources/EmulatorController.swift` owns the save lifecycle (coalesced persist,
  autosave timer, background assertion) and input forwarding.
- `Sources/Game.swift` is the model + `GameStore` (import, library load, MT-32 ROM
  packaging, per-game metadata).
- `Web/index.html` is the harness that loads the js-dos `Dos()` component, applies
  per-game config/memory/MIDI/ROM overrides, and wires save/restore.

## Build & run

Requires full Xcode and [XcodeGen](https://github.com/yonkov/XcodeGen)
(`brew install xcodegen`). `ZIPFoundation` is resolved automatically via SwiftPM.

```bash
# 1. (When updating the web engine) sync js-dos assets into Web/ from a sibling
#    js-dos checkout — build js-dos first:  cd ../js-dos && npx vite build
scripts/sync-jsdos.sh

# 2. Generate the Xcode project from project.yml
xcodegen generate

# 3. Open and run on a device (set your Team in Signing & Capabilities)
open PocketDOS.xcodeproj
```

To autostart a bundled game, drop a js-dos bundle at `Web/games/game.jsdos` before
building. Use shareware/freeware only — **never commit copyrighted games or ROMs.**

### Tests

```bash
xcodegen generate
xcodebuild test -scheme PocketDOS -destination 'platform=iOS Simulator,name=iPhone 17'
```

Unit tests (`Tests/`) cover the logic layer — `GameStore` import/library/MT-32
packaging, the scheme handler's path-containment + MIME mapping, and error mapping.

## License

GPL-2.0 (see `LICENSE`). js-dos and DOSBox/DOSBox-X are GPL-2; this app is a derivative
work and is distributed under GPL-2. The custom WASM build's corresponding source
(FluidSynth + mt32emu patches) is documented in `tools/midi-build/`. App Store
distribution of Track A is gated on obtaining the js-dos author's consent
(see `SPEC.md` B9 / M68). No copyrighted games or Microsoft OS images are shipped;
users supply their own (MT-32 ROMs likewise).
