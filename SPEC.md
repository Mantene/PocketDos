# PocketDOS — Product Spec (working draft)

> A not-for-profit, GPL-2-compliant iOS app to play DOS games and run DOS/Windows-9x
> software on iPhone (iPad in V2). Repo: `git@github.com:Mantene/PocketDos.git`

> **Phase 0 status (2026-06-14):** Track A spike COMPLETE on device. js-dos runs fully
> offline in a `WKWebView`: Wolf3D plays (dosbox), and **Win 3.11 + DOS 7.1 hit 60 FPS**
> on the `dosbox-x` backend mounting local qcow2 images. **M65 ANSWERED:** heavy Win9x
> (95/98) **crashes the WebContent process (OOM/Jetsam)** — light dosbox-x works, heavy
> does not → **Win9x belongs to Track B (native).** Two-track architecture validated.
> Secondary finding: in-app cross-origin bundle downloads fail ("Load failed") from the
> custom `pocketdos://` origin — local-file import works; URL download needs a native
> proxy (spec G38). See branch `spike/track-a-wkwebview`.

## Architecture (decided)

Two-track, each engine matched to its distribution channel:
- **Track A — App Store:** js-dos (WASM DOSBox-X) in a `WKWebView` (borrows WebKit's JIT legally; runs Win9x; fully offline via bundled assets + `WKURLSchemeHandler`).
- **Track B — Sideload (AltStore/SideStore):** native **DOSBox Pure** libretro core with real x86→ARM dynarec (JIT via AltJIT/StikDebug); GPL-clean; Pure's save-states + ZIP/ISO mount + disk-swap replace sockdrive.
- Staging rejected (Win9x non-goal). dospad reused for UX patterns only, not as engine. Sockdrive dropped (optional in Track A).

---

## A. Product & Scope (decided)

| # | Decision |
|---|---|
| A1 | **iPhone-only V1**; iPad in V2 (Stage Manager, external display, pointer later). |
| A2 | **Minimum iOS 17+** (modern GameController, Metal, OPFS, cleanest APIs). |
| A5 | App name: **PocketDOS** (from repo). |
| A6 | **IPX multiplayer out of scope for V1.** |
| A7 | **Public Git repo from day 1**: `git@github.com:Mantene/PocketDos.git` (SSH push available on dev machine). |

| A4a | **Hero DOS title:** a LucasArts/Sierra point-and-click adventure (mouse-driven; showcases touch point-and-click UX). |
| A4b | **Win9x acceptance bar:** Win98SE boots to desktop **and** launches an app/game at usable speed. |

_Open in A:_ A3 must-have vs nice-to-have feature list; A5 branding/icon details; exact hero adventure title.

---

## B. Distribution & Legal (decided)

| # | Decision |
|---|---|
| B8 | **Paid Apple Developer account** (already held) → enables App Store + TestFlight + 1-yr sideload signing. |
| B10 | **Sideload via both AltStore + SideStore** (SideStore = on-device refresh, no PC). |

| B9 | **Seek caiiiycuk's (js-dos author) consent** before App Store distribution of Track A. → *App Store Track A is gated on this; sideload + spike proceed regardless.* |
| B11 | GPL source obligation met via the public repo + in-app license/source links. |
| B12 | Replace **all** non-free assets (dospad art/audio are "personal use only"; js-dos branding) with original art. |
| B13 | App ships **no copyrighted games or MS OS images**; users supply their own (surfaced in onboarding + store text). |
| B14 | **Lockdown Mode (Track A): detect and warn gracefully** (point users to disable it for the app or use the sideload build). |

---

## C. Engine & Emulation (decided so far)

| # | Decision |
|---|---|
| C16 | Track A backend: **per-content auto-select** (DOSBox for plain DOS, DOSBox-X auto when Win9x/qcow2/sockdrive needed). |
| C21 | **Full audio:** built-in OPL/AdLib + SoundBlaster, **General MIDI via user-supplied SoundFont**, **MT-32 emulation via user-supplied ROMs** (important for the Sierra/LucasArts hero genre). |

| C15 | Pin js-dos v8.x + a fixed `emulators` version; **self-host all WASM offline** (no js-dos.com CDN). |
| C17 | Track B: **DOSBox Pure as a git submodule, tracking upstream** (pin to release, pull updates). |
| C22 | **Settings UI + an Advanced raw `dosbox.conf` editor** per game (power-user control). |

_Open in C:_ C18 dual build configs (DISABLE_DYNAREC vs dynarec); C19 per-game cycles auto-detect; C20 default machine profiles.

---

## D. Performance (decided so far)

| # | Decision |
|---|---|
| D24 | **Require A14 / iPhone 12 or newer** (consistent Win9x/interpreter performance). |
| D26 | **Pause on background** + auto-save state; resume on return (battery-friendly). |

_Open in D:_ D23 FPS/cycle acceptance targets; D25 frame pacing/vsync + thermal strategy.

---

## E. Frontend / UI / UX (decided)

| # | Decision |
|---|---|
| E27 | Native SwiftUI/UIKit chrome around the engine (WKWebView for Track A; native host for Track B). |
| E28 | **Cover-art grid** library (uses per-game cover/screenshot art), with search + categories. |
| E29 | In-game menu via a **small draggable floating button** (pause/save/settings/keyboard/quit). |
| E30 | **Sharp pixels by default** (integer/nearest-neighbor), with optional smoothing + CRT shader in settings. |
| E31 | **Landscape-locked gameplay** (4:3 content); library/menus allow portrait + landscape. |
| E32 | First-run onboarding: import first game + brief controls tutorial. |

---

## F. Input (decided)

| # | Decision |
|---|---|
| F33 | On-screen controls: **preset layouts + per-game editor** (reposition/customize; reuse js-dos layers / dospad configs). |
| F34 | Controller: **auto-default mappings + per-game remap UI** (D-pad→arrows, face→keys, sticks→mouse). |
| F35 | **Hardware/Bluetooth keyboard** mapped to DOS keys; **customizable on-screen soft keyboard** (in-game menu toggle). |
| F36 | **All three mouse modes:** direct/absolute touch (default, for point-and-click), trackpad/relative, joystick-as-mouse. |
| F37 | **Haptic feedback** on virtual button presses. |

---

## G. Content & Game Management (decided)

| # | Decision |
|---|---|
| G38 | Import via **Files/iCloud, 'Open in PocketDOS' share sheet, AirDrop, and in-app URL download**; expose Documents folder for drag-in (like dospad). |
| G39 | Accept **.jsdos, .zip, .iso/.cue/.img, raw folders, .idos, .qcow2**. |
| G40 | Internal package format: **extended `.idos`-style** (folder + config + cover art). |
| G42 | **Create blank HDD + guided Win9x install wizard** (boot user-supplied CD/floppy); CD mounting + **mid-game disc swap**. |
| G44 | **Bundle a few freeware/shareware games** for first-run (verify each title's redistribution license). |

---

## H. Storage & Saves (decided)

| # | Decision |
|---|---|
| H45 | **Both save states + in-game (disk) saves** (Track B save states via DOSBox Pure; flag weaker js-dos save-state parity in Track A). |
| H46 | **iCloud: sync saves only** (states + game saves); large game/disk images stay local. |
| H47 | Track A persistence: prefer **native bridge** for saves/changes (OPFS as fallback) via js-dos `fsChanges`. |
| H48 | **Auto-save state on exit/background** + restore on return; manual **quick-save/load hotkeys** (F6/F7). |
| H49 | **Per-game size accounting + cleanup tools** (delete games, free space). |

---

## I. Networking (decided)

| # | Decision |
|---|---|
| I50 | **Sockdrive dropped for V1** (Pure's ZIP/ISO mount + local import cover content; removes network + subscription dependency). |
| I51 | IPX multiplayer out of scope V1 (see A6). |
| I52 | **No telemetry / analytics / phone-home.** |

---

## J. Audio & Video (decided)

| # | Decision |
|---|---|
| J53 | Audio: low-latency interactive — Track A Web Audio (`ScriptProcessor`/`webkitAudioContext` fallback present), Track B CoreAudio. |
| J54 | Video: Track A WebGL/Canvas, Track B Metal; scaling/shaders per E30. |
| J55 | **No capture features in V1** (rely on iOS system screenshot/recorder; revisit screenshot via `ci.screenshot()` later). |

---

## K. Build, CI & Tooling (decided so far)

| # | Decision |
|---|---|
| K56 | **Two repos** (per-track). `git@github.com:Mantene/PocketDos.git` is one of them — *track assignment + second repo name: OPEN*. |
| K59 | WASM (`emulators`) vendored + pinned, self-hosted (per C15). |

| K-repo | **`PocketDos` = Track A** (App Store / js-dos WKWebView, spike-first). **`PocketDos-Native` = Track B** (native DOSBox Pure libretro). |
| K57 | CI per repo: Track A builds js-dos with vendored WASM + the WKWebView app; Track B cross-compiles the Pure libretro core for iOS arm64 + the native host. _(default — confirm)_ |
| K58 | Pipelines: Track A → TestFlight/App Store; Track B → signed `.ipa` for AltStore/SideStore. _(default — confirm)_ |
| K60 | Code-signing via the existing paid account; automatic signing for dev/TestFlight, manual for sideload `.ipa`. _(default — confirm)_ |

---

## L. Accessibility, Localization, QA (decided)

| # | Decision |
|---|---|
| L61 | **English-only app UI**; keep js-dos **multi-language soft-keyboard** layouts. |
| L62 | **VoiceOver + Dynamic Type** for native library/menus (emulated game surface exempt). |
| L63 | QA matrix: A14+ iPhones on iOS 17+, incl. a **Lockdown-Mode degradation check** (Track A) and a **Win98SE regression** case. _(default — confirm)_ |
| L64 | Betas: **TestFlight** (Track A) + **AltStore/SideStore** channel (Track B). |

---

## M. Open Risks (track through the spike)

| # | Risk |
|---|---|
| M65 | **RESOLVED (2026-06-14):** heavy Win9x (95/98) OOM-crashes the WKWebView WebContent process; light dosbox-x (Win 3.11, DOS 7.1) runs at 60 FPS. → Track A = DOS + light Windows; **Win9x (95/98) → Track B (native)**. |
| M65b | In-app cross-origin bundle download fails from the `pocketdos://` origin ("Load failed"); local-file import works. Fix for spec G38 = native URLSession proxy that downloads then serves via the bundle scheme. |
| M66 | **App Review** acceptance of a user-content emulator (iDOS history) — re-check Guideline 4.7 before submitting Track A. |
| M67 | Confirm DOSBox Pure's exact license file/text and that `DISABLE_DYNAREC` builds cleanly for iOS arm64 today. |
| M68 | Confirm no GPL contributor objects to App Store distribution — **gated on caiiiycuk consent (B9)** for Track A. |
| M-assets | Verify redistribution license for each bundled freeware/shareware starter game (G44). |

---

## Asserted technical defaults (confirm later)

- **C18:** Track B maintains two build configs — `DISABLE_DYNAREC` (App-Store-legal interpreter) and dynarec-enabled (sideload). _Track B is sideload-first, so dynarec is primary._
- **C19:** Per-game cycles/CPU auto-detected (Pure auto-maps; js-dos via `dosboxConf`), overridable in Advanced settings.
- **C20:** Default machine profiles per era — DOS (SB16, ~Pentium cycles) and Win9x (DOSBox-X, Voodoo + S3 Trio64, 128 MB).
- **D23:** Target on-screen 60 fps with era-appropriate emulated cycles; accept lower for heavy Win9x.
- **D25:** VSync to display; rely on auto-cycles to manage thermals on long sessions.

---

## Next step

Phase 0 spike in **`PocketDos`** (Track A): minimal WKWebView app + `WKURLSchemeHandler` serving vendored js-dos + WASM offline → boot the hero adventure and Win98SE on an A14+ device, record FPS. This de-risks M65 before full build-out.
