# App Store screenshots — shot list and capture commands

Commands are tailored to **this machine as of 2026-07-07** (checked with
`xcrun simctl list devices available` / `list runtimes` / `list devicetypes`):

- Installed runtimes: **iOS 26.4**, **iOS 26.5**. No `xcode-select` default —
  every `xcrun`/`xcodebuild` below needs the
  `DEVELOPER_DIR=/Applications/Xcode-beta.app/Contents/Developer` prefix.
- Existing devices: iPhone 17 Pro (iOS 26.4, 1206×2622 — **wrong size class
  for ASC, don't use it for store shots**), iPad Pro 13-inch (M4) and iPad
  Air 11-inch (iOS 26.5).
- The required 6.9-inch iPhone device does **not** exist yet — it is created
  in step 1 (the `iPhone 16 Pro Max` devicetype is available).

## What App Store Connect requires

| Slot | Accepted pixel sizes | Produce with |
|---|---|---|
| **iPhone 6.9" (required)** | 1320×2868 portrait / 2868×1320 landscape (also accepts 1290×2796 / 2796×1290) | iPhone 16 Pro Max sim (1320×2868) |
| iPhone 6.5"/6.7" (optional legacy) | 1284×2778 / 1242×2688 (6.5"); 1290×2796 (6.7") | iPhone 16 Plus sim (1290×2796) or downscale — see step 6 |
| **iPad 13" (required while the app targets iPad)** | 2064×2752 / 2048×2732 | existing iPad Pro 13-inch (M4) sim |

Smaller iPhone/iPad tiers are auto-scaled by Apple from the 6.9" (and 13")
uploads unless you provide them. The iPad row applies because `project.yml`
ships `TARGETED_DEVICE_FAMILY: "1,2"`; if V1 goes iPhone-only (family `"1"`),
skip it.

1–10 screenshots per slot; PNG or high-quality JPEG, no alpha.

## Shot list

| # | Shot | Where in the app | Orientation | Content needed on the sim first |
|---|---|---|---|---|
| 1 | Library grid | launch screen (tile grid) | Portrait | **Yes** — import 4–6 games so the grid looks alive (step 4) |
| 2 | DOS game running w/ touch controls | any imported game, `fps` profile showing D-pad + action cluster | **Landscape** (gameplay locks to landscape at runtime → 2868×1320) | **Yes** — a running game |
| 3 | Config editor | game tile → settings → DOS config / RAM + presets | Portrait | Only one imported game |
| 4 | Win98 install wizard form | library **+** menu → *New Windows 98 machine* (ISO picker + key form) | Portrait | **No** — the empty form is the shot; do not show a real product key |
| 5 | Windows 98 desktop | boot the wizard-built machine | Landscape | **Yes** — a completed Win98 install (see "Staging content") |

**IP note (App-Review-relevant):** screenshots are metadata Apple reviews
(guideline 2.3). Do not show commercial game IP you have no rights to display
— use freely licensed titles (e.g. FreeDOOM, BSD; or open-source/homebrew DOS
titles) for shots 1–3. Shot 5 displays Microsoft's Win98 desktop trademarks:
there is precedent (UTM SE's listing shows retro OS screens), but it is the
riskiest shot — if App Review objects, drop it and let shot 4 tell the wizard
story. Shot 4 must show a placeholder/redacted key field, never a real key.

## Commands

All blocks assume:

```sh
export DEVELOPER_DIR=/Applications/Xcode-beta.app/Contents/Developer
cd /Users/mhood/projects/dosjar/PocketDos
mkdir -p ~/Downloads/pocketdos-shots   # never /tmp
```

### 1. Create the store-size simulators (one-time)

```sh
UDID_69=$(xcrun simctl create "PDOS-6.9-16ProMax" \
  com.apple.CoreSimulator.SimDeviceType.iPhone-16-Pro-Max \
  com.apple.CoreSimulator.SimRuntime.iOS-26-5)
# Optional 6.7" fallback device:
UDID_67=$(xcrun simctl create "PDOS-6.7-16Plus" \
  com.apple.CoreSimulator.SimDeviceType.iPhone-16-Plus \
  com.apple.CoreSimulator.SimRuntime.iOS-26-5)
# Existing 13" iPad (from `simctl list devices available`):
UDID_IPAD=4C45C072-C803-408F-94D7-9B1A4588345B
xcrun simctl boot "$UDID_69"
open -a Simulator   # so you can drive the UI
```

### 2. Build and install the app

```sh
xcodegen generate
xcodebuild build -scheme PocketDOS \
  -destination "platform=iOS Simulator,id=$UDID_69" \
  -derivedDataPath build CODE_SIGNING_ALLOWED=NO
xcrun simctl install "$UDID_69" \
  build/Build/Products/Debug-iphonesimulator/PocketDOS.app
xcrun simctl launch "$UDID_69" com.mantene.pocketdos
```

(Repeat install/launch per device; add `-destination` per UDID or reuse the
same build product — it is simulator-generic.)

### 3. Clean status bar (marketing polish, one-time per boot)

```sh
xcrun simctl status_bar "$UDID_69" override \
  --time "9:41" --batteryLevel 100 --batteryState charged \
  --cellularBars 4 --wifiBars 3 --operatorName ""
```

### 4. Staging content (before shots 1–3 and 5)

- **Games (shots 1–3):** drag freely-licensed `.zip`/`.jsdos` files from
  Finder onto the booted Simulator window (they land in Files → Downloads),
  then import each via the app's **+** menu. The library is folder-based
  under the app's `Documents/Games/`, visible via
  `xcrun simctl get_app_container "$UDID_69" com.mantene.pocketdos data`.
- **Win98 machine (shot 5):** run the wizard end-to-end on the simulator
  with your own ISO + key (30–60 min unattended; the simulator has more
  memory headroom than a device). There is no supported shortcut: seeding a
  previously-built machine by copying an existing `Documents/Games/<id>/`
  folder from a device backup *may* work (the library scans folders) but is
  unverified — budget for the real install.
- Shot 4 needs nothing staged — open the wizard form and shoot it empty.

### 5. Capture

```sh
# Portrait shots (1, 3, 4) — navigate the app to the screen, then:
xcrun simctl io "$UDID_69" screenshot ~/Downloads/pocketdos-shots/69-01-library.png
xcrun simctl io "$UDID_69" screenshot ~/Downloads/pocketdos-shots/69-03-config.png
xcrun simctl io "$UDID_69" screenshot ~/Downloads/pocketdos-shots/69-04-wizard.png

# Landscape shots (2, 5): launching a game rotates the app itself; rotate the
# device too (Device → Rotate Left, or Cmd-Left in Simulator) so the capture
# is 2868×1320, then:
xcrun simctl io "$UDID_69" screenshot ~/Downloads/pocketdos-shots/69-02-dosgame.png
xcrun simctl io "$UDID_69" screenshot ~/Downloads/pocketdos-shots/69-05-win98.png

# Verify sizes ASC will accept:
sips -g pixelWidth -g pixelHeight ~/Downloads/pocketdos-shots/*.png
```

Repeat on `$UDID_IPAD` (expect 2064×2752 portrait) for the required iPad set,
and optionally on `$UDID_67` (1290×2796).

### 6. Optional literal 6.5" set

No installed runtime supports a native 6.5" device (oldest devicetype is
iPhone 15). If you want the legacy 6.5" slot filled exactly rather than
auto-scaled, downscale the 6.7" captures:

```sh
for f in ~/Downloads/pocketdos-shots/67-*.png; do
  sips -z 2778 1284 "$f" --out "${f/67-/65-}"
done
```

(0.2% aspect distortion — invisible in practice; skip this step unless ASC
complains.)

### 7. Cleanup

```sh
xcrun simctl shutdown "$UDID_69"; xcrun simctl delete "$UDID_69"
xcrun simctl shutdown "$UDID_67"; xcrun simctl delete "$UDID_67"
```
