# PocketDOS Privacy Policy

*Effective 2026-07-07. Applies to the PocketDOS iOS app.*

**Short version: PocketDOS collects nothing.**

## What we collect

Nothing. PocketDOS has:

- **No telemetry, no analytics, no crash reporting, no advertising, no
  tracking.** There is no data-collection code in the app, first- or
  third-party. Its only library dependency (ZIPFoundation) is local archive
  code with no network capability.
- **No accounts.** There is nothing to sign in to and no server to sign in
  to — the developer operates no backend of any kind.
- **No network use.** The app makes no network requests of its own, and its
  web layer is code-locked to the app's local bundled content: any navigation
  outside the app's own custom URL scheme is refused
  (`Sources/EmulatorWebView.swift` — the app is open source, so this is
  auditable, not just asserted).

## Your content stays on your device

- Games, disk images, machines, and save data you import or create live in
  the app's Documents folder on your device (visible in the Files app, under
  your control).
- The Windows 98 install wizard reads **your** CD image on-device and never
  copies it anywhere else. Your product key is held in memory only — never
  stored, logged, or transmitted.

## iCloud (optional)

If your device is signed into iCloud with iCloud Drive enabled, PocketDOS
syncs small save-game deltas through **your own iCloud account** (Apple's
service, governed by [Apple's privacy policy](https://www.apple.com/legal/privacy/)).
That data belongs to you, lives in your private iCloud container, and is not
accessible to the developer — again, there is no developer server. Without
iCloud the app is fully functional and entirely local.

## App Store privacy label

**Data Not Collected.**

## Children

PocketDOS collects no data from anyone, including children.

## Changes

Any change to this policy is made in the app's public source repository,
where its full history is visible:
<https://github.com/Mantene/PocketDos>

## Contact

Questions: open an issue at
<https://github.com/Mantene/PocketDos/issues>.
