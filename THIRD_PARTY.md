# Third-party notices

PocketDOS is free software under the GNU General Public License, version 2
(see [LICENSE](LICENSE)). It bundles, links, or depends on the third-party
components below. Every license claim here was verified against the actual
license file or source header of the component named.

## Summary table

| Component | Where in this repo | License | Upstream / source |
|---|---|---|---|
| js-dos v8 | `Web/js-dos.js`, `Web/js-dos.css`, `Web/emulators/` (incl. `emulators.js`, the file-explorer UI and its font/sprite assets) | GPL-2.0 | [caiiiycuk/js-dos](https://github.com/caiiiycuk/js-dos) |
| emulators (js-dos backends) | `Web/emulators/wdosbox*`, `wlibzip*`, `webrtcnet*` | GPL-2.0 | [caiiiycuk/emulators](https://github.com/caiiiycuk/emulators) |
| DOSBox | compiled into `Web/emulators/wdosbox.wasm` | GPL-2.0 | [dosbox.com](https://www.dosbox.com) |
| DOSBox-X | compiled into `Web/emulators/wdosbox-x.wasm` | GPL-2.0 | [joncampbell123/dosbox-x](https://github.com/joncampbell123/dosbox-x) |
| FluidSynth | statically linked into the custom `wdosbox-x.wasm` | LGPL-2.0-or-later | vendored in DOSBox-X `src/libs/fluidsynth/` (© 2003 Peter Hanappe and others) |
| munt / mt32emu | statically linked into the custom `wdosbox-x.wasm` | LGPL-2.1-or-later | [munt/munt](https://github.com/munt/munt), vendored in DOSBox-X `src/libs/mt32/` (© Dean Beeler, Jerome Fisher, Sergey V. Mikayev) |
| TimGM6mb SoundFont | `Web/soundfont.zip` (`TIMGM6MB.SF2`) | GPL-2.0 | © 2004 Tim Brechbill, © 2010 David Bolton; packaged from Debian `timgm6mb-soundfont` |
| DOSLIB `dboxmpi` mouse driver | `Web/install/dboxmpi.drv`, `Web/install/dboxmpi.inf` | LGPL-2.1 | [joncampbell123/doslib](https://github.com/joncampbell123/doslib), `windrv/dosboxpi/` ("Copyright 2017 DOSLIB") |
| ZIPFoundation | Swift Package Manager dependency (fetched at build time, not vendored) | MIT | [weichsel/ZIPFoundation](https://github.com/weichsel/ZIPFoundation) (© 2017–2025 Thomas Zoechling) |

## The vendored js-dos runtime (`Web/`)

`Web/js-dos.js`, `Web/js-dos.css`, and everything under `Web/emulators/` are
build outputs of [js-dos v8](https://github.com/caiiiycuk/js-dos) (GPL-2.0,
per its `package.json`) and its
[emulators](https://github.com/caiiiycuk/emulators) backends repo (GPL-2.0,
per its `LICENSE`). They are committed so the app builds without a Node
toolchain; `scripts/sync-jsdos.sh` refreshes them from a sibling js-dos
checkout. The emulator binaries compile DOSBox and DOSBox-X, both GPL-2.0
(each project's `COPYING`).

## The custom `wdosbox-x.wasm` — corresponding source

`Web/emulators/wdosbox-x.wasm` (and its matching `.js` loader) is **not** the
stock js-dos artifact: it is rebuilt with two software synthesizers linked in —
FluidSynth (General MIDI) and mt32emu (Roland MT-32). Under GPL-2.0 §3, the
complete corresponding source for this modified binary is provided in-repo:

- **[`tools/midi-build/BUILD.md`](tools/midi-build/BUILD.md)** — the full,
  reproducible recipe: exact upstream repos, submodules, toolchain
  (Emscripten 6.0.0), build commands, and install steps.
- **[`tools/midi-build/patches/`](tools/midi-build/patches/)** — the two
  patches applied on top of the upstream trees
  (`dosbox-x-fluidsynth.patch`, `emulators-jsdos.patch`).

FluidSynth is vendored inside DOSBox-X under LGPL-2.0-or-later; mt32emu (the
MUNT library) under LGPL-2.1-or-later. Both are license-compatible with the
GPL-2.0 whole. You can confirm the shipped binary is the synth-enabled build:
`strings Web/emulators/wdosbox-x.wasm | grep -ciE 'fluid'` and
`… | grep -ciE 'mt32emu'` are both non-zero.

## SoundFont

`Web/soundfont.zip` contains `TIMGM6MB.SF2` (TimGM6mb), a GPL-2.0 General MIDI
SoundFont by Tim Brechbill (© 2004; © 2010 David Bolton), obtained via the
Debian `timgm6mb-soundfont` package. It is the only sound data shipped with
the app; MT-32 ROMs are **not** included (see below).

## Windows 9x guest mouse driver (`Web/install/`)

`dboxmpi.drv` + `dboxmpi.inf` are the "DOSBox-X Mouse Pointer Integration"
Windows 9x guest driver from [DOSLIB](https://github.com/joncampbell123/doslib)
(`windrv/dosboxpi/`), marked "Copyright 2017 DOSLIB" in the `.inf`. DOSLIB is
LGPL-2.1. The install wizard writes this driver into the Windows machine it
builds so the host cursor maps to the guest cursor.

## Swift package dependencies

- **ZIPFoundation** — MIT, © 2017–2025 Thomas Zoechling. Declared in
  `project.yml`; resolved by SwiftPM at build time, never vendored into this
  repo.

## Sockdrive format compatibility

Large disk images use the *sockdrive* chunked-drive layout so js-dos can
stream them. The reading client is part of the GPL-2.0 js-dos bundle above.
On the Swift side, `Sources/SockdriveChunker.swift` is a from-scratch Swift
implementation of the format produced by the
[sockdrive](https://github.com/caiiiycuk/sockdrive) CLI's `mkd` command
(256 KiB `<range>.raw` chunks + a `sockdrive.metaj` manifest); no code from
that repository is included here. The upstream sockdrive repository publishes
no license file; only its on-disk file format is implemented, for
interoperability.

## First-party assets that look third-party (but aren't)

- **`Web/install/win98-blank-c.zip`** — a pre-formatted, *empty* FAT32 drive
  template (an MBR, a boot-parameter block, empty FATs, an empty root
  directory). It is generated from `/dev/zero` with GNU mtools
  (`mpartition`/`mformat`) and chunked — see
  `tools/make-win98-install-media.sh`. It contains **no Microsoft code or
  data** (verifiably: its two 256 KiB chunks carry only self-made filesystem
  structures).
- **`Assets.xcassets/AppIcon.appiconset/`** — original PocketDOS artwork.
- All Swift sources, the `Web/index.html` harness, and the shell/JS tooling
  are first-party PocketDOS code, GPL-2.0.

## What is deliberately absent

PocketDOS ships **zero Microsoft content** — no Windows CD images, no boot
floppies, no MS-DOS system files, no product keys. Everything the Windows 98
install wizard consumes is derived *on-device, at install time* from the
user's own CD image and license (see the README's
[Legal & licensing](README.md#legal--licensing) section). The `.gitignore`
additionally quarantines local spike artifacts (`Web/drive/`, screenshots,
scratch zips) so they can never be committed, and the repo's git history
contains none.
