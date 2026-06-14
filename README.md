# PocketDOS

A not-for-profit, GPL-2 iOS app to play DOS games and run DOS/Windows-9x software
on iPhone (iPad in V2).

This repository is **Track A** of the project: the **App Store** track, which runs
[js-dos](https://github.com/caiiiycuk/js-dos) (WASM DOSBox / DOSBox-X) inside a
`WKWebView`. The WebView legitimately benefits from WebKit's WebAssembly JIT (which
runs in Apple's out-of-process WebContent), so no forbidden JIT entitlement is needed.
The native, dynarec-powered sideload track lives in a sibling repo, **PocketDos-Native**
(DOSBox Pure / libretro).

> Status: **Phase 0 spike.** Goal — prove js-dos boots from bundled assets, fully
> offline, and measure real DOS + Windows 98SE speed on an A14+ device. See `SPEC.md`
> (in the project planning notes) for the full V1 spec.

## How it works

- `Sources/BundleSchemeHandler.swift` serves the bundled `Web/` directory over a
  custom `pocketdos://app/...` scheme with correct MIME types — crucially
  `application/wasm`, so `WebAssembly.instantiateStreaming` works and the WebKit
  WASM JIT engages. No embedded HTTP server, no network entitlement, fully offline.
- `Sources/EmulatorWebView.swift` hosts the `WKWebView` and forwards JS
  `console.*` / errors to Xcode (prefixed `[web]`).
- `Web/index.html` is a thin harness that loads the js-dos global `Dos()` and starts
  a game (or the js-dos UI if no game is bundled). It also detects Lockdown Mode
  (which disables WASM) and shows a graceful message.

## Build & run

Requires Xcode (full IDE) and [XcodeGen](https://github.com/yonkov/XcodeGen)
(`brew install xcodegen`).

```bash
# 1. Sync the js-dos web assets into Web/ (from a sibling js-dos checkout).
#    First build js-dos:  cd ../js-dos && npx vite build
scripts/sync-jsdos.sh

# 2. Generate the Xcode project from project.yml
xcodegen generate

# 3. Open and run on a device (set your Team in Signing & Capabilities)
open PocketDOS.xcodeproj
```

To autostart a game, drop a js-dos bundle at `Web/games/game.jsdos` before building.
Use shareware/freeware only — **never commit copyrighted games.**

### Spike toggles

In `Web/index.html`:
- `USE_WORKER` / `USE_OFFSCREEN` — off by default for the most reliable first load;
  flip on to test off-main-thread performance.
- `BACKEND` — `dosbox` for DOS; js-dos auto-switches to `dosboxX` for Win9x configs.

## What we're measuring (Phase 0)

1. js-dos loads and runs entirely from the app bundle (offline). ✅ target
2. A DOS game (the hero point-and-click adventure) runs at usable speed + FPS.
3. **Windows 98SE boots to desktop and launches an app** under WASM-JIT — the #1
   open risk (`SPEC.md` M65). Record FPS via the on-screen HUD / Safari Web Inspector.

## License

GPL-2.0 (see `LICENSE`). js-dos and DOSBox/DOSBox-X are GPL-2; this app is a derivative
work and is distributed under GPL-2. App Store distribution of Track A is gated on
obtaining the js-dos author's consent (see `SPEC.md` B9 / M68). No copyrighted games or
Microsoft OS images are shipped; users supply their own.
