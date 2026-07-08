# App Store Connect metadata — copy-paste package

Everything below is ready to paste into App Store Connect (ASC). Character
counts are against ASC limits and were verified at authoring time. Items in
**[BRACKETS]** must be resolved before submitting — they are collected in the
[pre-submission checklist](#pre-submission-checklist) at the bottom.

---

## App Information

| Field | Value |
|---|---|
| **Name** (30 max) | `PocketDOS` (9/30) |
| **Subtitle** (30 max) | `DOS & retro PC emulator` (23/30) |
| **Bundle ID** | `com.mantene.pocketdos` |
| **SKU** | `pocketdos-ios` (any unique string) |
| **Primary language** | English (U.S.) |
| **Primary category** | **Entertainment** |
| **Secondary category** | Utilities (optional) |
| **Price** | Free (not-for-profit, GPL-2.0) |
| **Content rights** | "Yes, it contains third-party content" — and you have the rights: everything bundled is GPL/LGPL/MIT-licensed (see `THIRD_PARTY.md`); user-imported content is the user's own |

**Category rationale (one line):** shipped App Store emulators without bundled
game content live in **Entertainment** — verified July 2026 on the US store
pages of both [UTM SE](https://apps.apple.com/us/app/utm-se-retro-pc-emulator/id1564628856)
(the closest precedent: a retro PC emulator) and
[Delta](https://apps.apple.com/us/app/delta-game-emulator/id1048524688);
*Games* implies playable content in the box (PocketDOS ships none), and
*Utilities* forfeits discoverability with no precedent among approved
emulators.

**Name-collision caveat:** "PocketDOS" was also the name of a discontinued
commercial DOS emulator for Windows CE/Pocket PC (pocketdos.com). App name
availability is only checked when you reserve the name in ASC; if it is taken
or trademark-challenged, fall back to e.g. `PocketDOS — Retro PC` (20/30).

---

## Version Information

### Promotional text (170 max — editable without review)

> Play the DOS classics you already own — on-device, offline, open source.
> Now with an experimental wizard that installs Windows 98 from your own CD
> image.

(153/170)

### Description (4000 max)

Paste as plain text (ASC does not render markdown):

```
PocketDOS plays the DOS and Windows 9x software you already own, on your iPhone. Import your games and programs from the Files app and they run entirely on-device, offline, at usable speed — no account, no ads, no data collection.

PocketDOS ships no games and no Microsoft software. Everything it runs comes from media you supply and are licensed to use.

FEATURES

- Game library: import .jsdos bundles, .zip archives, or chunked hard-disk machines. Rename, delete, and tune each entry. Your library lives in the Files app, so you can back it up yourself.
- Session persistence: autosave every 3 minutes, save on quit and when backgrounding, quick save/load (F6/F7) on a hardware keyboard, and per-game "reset saved session".
- iCloud save sync (optional): small save files follow you between installs via your own iCloud Drive. The app works fully offline without it.
- Touch controls, three per-game profiles: a D-pad with an action cluster for keyboard-driven games; a tap-to-click mouse mode with a dedicated right-click button for point-and-click adventures; or none.
- Hardware keyboards and game controllers are supported, with per-game remapping.
- Per-game settings: emulated RAM size and an editable DOS configuration with one-tap presets (Sound Blaster IRQ, General MIDI, MT-32, FM-only).
- Sound: Sound Blaster digital audio and AdLib/OPL FM synthesis out of the box, General MIDI via a bundled SoundFont, and Roland MT-32 music with ROMs you supply.
- Private by design: every asset is served from inside the app and the emulator cannot reach the network. No telemetry, no analytics. The privacy policy fits on one screen.

WINDOWS 98 INSTALL WIZARD (EXPERIMENTAL)

Build a real, bootable Windows 98 SE machine from your own Windows 98 SE CD image and your own product key. Entirely on your device, the wizard reads the CD image, extracts its boot floppy, and runs Microsoft Setup unattended — file copy, wizard pages, first boot to the desktop — then installs a mouse-integration driver so your touch input works on the Windows desktop. The finished machine appears in your library like any other entry, with persistent disk state.

Honest expectations: a full install runs unattended for 30-60 minutes, and the feature is young — it is labeled Experimental because it means it. If an install fails, it fails cleanly and you can try again. Your CD image is read on-device and never uploaded; your product key is held in memory only and is never stored, logged, or transmitted.

OPEN SOURCE

PocketDOS is free software (GPL-2.0) built on DOSBox, DOSBox-X, and js-dos. The complete source code, including the exact emulator build recipe, is public: https://github.com/Mantene/PocketDos

WHAT POCKETDOS DOES NOT INCLUDE

No game content, no operating systems, no product keys, no MT-32 ROMs. You supply your own legally obtained software. DOS, Windows, and all emulated software remain the property of their respective owners.

Requires iOS 17 or later. iPhone-first; iPad support is planned.
```

(3005/4000)

### Keywords (100 max, comma-separated, no wasted spaces)

```
dosbox,win98,windows,98,games,classic,vintage,486,midi,soundblaster,mt32,floppy,x86,jsdos,shareware
```

(99/100.) Notes: never repeat words already indexed from name/subtitle
(`pocketdos`, `dos`, `retro`, `pc`, `emulator` are free); ASC combines
keywords with each other and with the name, so `games` + name yields
"dos games", `windows` + `98` yields "windows 98". **Mild 2.3.7 risk:**
`windows`/`win98` are trademarked terms used as compatibility keywords —
standard practice for shipped emulators, but drop them first if metadata is
rejected.

### URLs

| Field | Value |
|---|---|
| **Support URL** | `https://github.com/Mantene/PocketDos/issues` |
| **Marketing URL** (optional) | `https://github.com/Mantene/PocketDos` |
| **Privacy Policy URL** | `https://github.com/Mantene/PocketDos/blob/main/PRIVACY.md` **[SEE CAVEAT]** |

**[PRIVACY URL CAVEAT]** — the repo's default branch (`main`) currently holds
only the initial commit; `PRIVACY.md` exists on `spike/track-a-wkwebview`.
Before submitting, either **merge the spike branch into `main`** (then the URL
above is correct) or paste the branch-qualified URL into ASC:
`https://github.com/Mantene/PocketDos/blob/spike/track-a-wkwebview/PRIVACY.md`.
The URL must resolve publicly (the repo is public, so a blob URL qualifies).

### Copyright

```
© 2026 Mantene — free software, GPL-2.0
```

### Version

ASC version string should be `1.0`. **[BUMP `MARKETING_VERSION` in
`project.yml` from `0.0.1` to `1.0` before archiving.]**

---

## App Privacy (nutrition label)

- Data collection: **"Data Not Collected"** — answer **No** to every
  collection question. There is no telemetry, analytics, tracking, account,
  or developer server; iCloud save-sync writes to the user's own private
  iCloud Drive container and is not developer-accessible.
- Privacy policy URL: see [URLs](#urls) above (same caveat).

## Age rating questionnaire

Answer **None / No** to everything. Verified precedent: UTM SE and Delta,
identical fact pattern (emulator, zero bundled content), both rate **4+**.

| Question | Answer |
|---|---|
| Cartoon or fantasy violence | None |
| Realistic violence | None |
| Prolonged graphic or sadistic realistic violence | None |
| Profanity or crude humor | None |
| Mature or suggestive themes | None |
| Horror or fear themes | None |
| Medical or treatment information | None |
| Alcohol, tobacco, or drug use or references | None |
| Simulated gambling | None |
| Sexual content or nudity | None |
| Graphic sexual content and nudity | None |
| Contests | None |
| Gambling with real money | No |
| Unrestricted web access | **No** — the WKWebView is hard-locked to the app's bundled custom scheme; it cannot browse the web (`Sources/EmulatorWebView.swift`) |
| User-generated / shared content, messaging, social features | No — nothing is shared between users; imported content stays on the user's device |
| Advertising | No |
| Made for Kids | No |

**Caveat to keep in mind (and in App Review notes):** the rating covers what
the app *ships* — nothing. Content the user imports is their own, outside the
app's rating, exactly like a document viewer; this is the same posture UTM SE
and Delta shipped with at 4+.

## Export compliance

- ASC question "Does your app use non-exempt encryption?" → **No.**
- `ITSAppUsesNonExemptEncryption` is already `false` in `Sources/Info.plist`,
  so ASC should not even prompt at upload.
- Rationale: the app implements no proprietary or custom cryptography; it
  uses at most the OS-provided standard encryption (exempt under EAR
  §740.17(b)(1) / category 5D992.c mass-market provisions). No French
  declaration needed.

## App Review notes (paste into "Notes" in the Review section)

> PocketDOS is a free, open-source (GPL-2.0) retro PC emulator in the spirit
> of UTM SE (App Store id 1564628856, approved 2024). The complete source of
> this exact app is public — https://github.com/Mantene/PocketDos — so every
> claim below can be audited rather than taken on trust.
>
> 1. NOTHING COPYRIGHTED SHIPS IN THE APP. The binary contains no games, no
> ROMs, no Microsoft software, and no product keys (see THIRD_PARTY.md in the
> repo for the audited third-party manifest). Like a document viewer, the app
> only runs software the user already owns and imports from their own Files.
>
> 2. NO DOWNLOADED CODE, NO NETWORK. The emulator core (DOSBox/DOSBox-X from
> the GPL js-dos project, compiled to WebAssembly) is embedded in the app
> bundle and executed by Apple's own WebKit inside WKWebView. The web view
> refuses navigation to anything but the app's bundled custom URL scheme; the
> app makes no network requests, has no analytics, and collects no data.
>
> 3. THE WINDOWS 98 INSTALL WIZARD (labeled "Experimental" in-app) requires
> the USER'S OWN licensed Windows 98 SE CD image and the USER'S OWN product
> key. Both are processed entirely on-device: the CD image is read locally to
> build the install media, and the key is held in memory only — never stored,
> logged, or transmitted. Microsoft Setup then runs inside the emulator from
> the user's own media. The app ships zero bytes of Microsoft content.
>
> 4. UPSTREAM CONSENT: PocketDOS is a GPL-2.0 derivative of js-dos; its
> author (github.com/caiiiycuk) consents to this App Store distribution.
> **[CONFIRM BEFORE SUBMITTING — SPEC.md gate B9/M68 is still open. Do not
> submit this sentence, or the app, until consent is actually in hand; edit
> the sentence to describe the form the consent took.]**
>
> 5. TO EXERCISE THE APP: the library starts empty by design (see point 1).
> Import any DOS program as a .zip or .jsdos bundle via the "+" button —
> e.g. a freely licensed title such as FreeDOOM (BSD license). A short demo
> video of the library, gameplay, and the Win98 wizard is available at
> **[RECORD AND LINK A DEMO VIDEO — strongly recommended so the reviewer
> is never stuck at an empty library]**.

## Pre-submission checklist

1. **[BLOCKING] js-dos author consent (SPEC.md B9/M68)** — obtain it, then
   rewrite review-note point 4 to state its form (issue link, email, etc.).
2. **Privacy URL** — merge `spike/track-a-wkwebview` → `main`, or use the
   branch-qualified URL (see caveat above).
3. **iPad**: `project.yml` sets `TARGETED_DEVICE_FAMILY: "1,2"`. Shipping
   with iPad support makes **13-inch iPad screenshots required** (the local
   iPad Pro 13-inch (M4) simulator covers this — see
   [screenshots.md](screenshots.md)). Alternatively set the family to `"1"`
   for an iPhone-only V1 (README calls iPad "V2").
4. **Bump `MARKETING_VERSION`** to `1.0` and set a real
   `DEVELOPMENT_TEAM` before archiving.
5. **Screenshots show only content you may show** — no commercial game IP;
   see the IP note in [screenshots.md](screenshots.md).
6. **Reserve the name early** ("PocketDOS" collision caveat above).
7. Record the reviewer demo video (review-note point 5).
