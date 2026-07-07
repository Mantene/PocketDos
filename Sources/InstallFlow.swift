import Foundation

// The PURE half of the Windows 98 install orchestration: everything here is
// deterministic, WebView-free, and unit-tested. `InstallOrchestrator` is the
// effectful interpreter that feeds these types real console lines and timers.
//
// The mechanics they encode are the Chrome-proven runbook (wizard-s0),
// hardened by the first device run:
//   stage 1  boot the CD's floppy → unattended Setup phase-1 (file copy)
//   stage 2  boot C: → Setup's info-collection pages advanced by REPEATED
//            keystroke cycles (device Setup paints far slower than Chrome —
//            nothing is timed absolutely) → unattended hardware setup →
//            guest shutdown KILLS the WASM (expected!). An EARLY death here
//            is an engine crash, not the shutdown, and re-runs the stage.
//   stage 3  recovery boot C: (hands-off) → desktop → final capture, with
//            every write plateau PROBED before it is trusted as the desktop
// with the install state carried between stages as the target sockdrive's
// write-overlay blob, captured in-page via `ci.persist(true)` every 4.5 s and
// re-seeded LIVE into IndexedDB (that re-seed is what lets warm reboots and
// page reloads continue instead of restarting).

// MARK: - Breadcrumb parsing

/// One parsed `[pdos-install]` console line. The install page (and the
/// injected capture loop) narrate progress on the console; the native side
/// hears them through the existing console message bridge.
enum InstallBreadcrumb: Equatable {
    /// The emulator booted and `window.ci` is live (arm the capture loop).
    case ciReady
    /// `?instwait=1` parked the boot behind `pdosInstallGo()` (re-seed now).
    case waitingForGo
    /// The capture loop accepted a persist pass: `count` = u32le sector-record
    /// count at overlay byte 0, `bytes` = whole blob length.
    case captured(count: Int, bytes: Int)
    /// The capture loop saw a persist BELOW the accepted floor and dropped it
    /// (normal around guest reboots — persist can return a partial set).
    case captureRegressed
    /// The engine died ([panic] re-emitted under the install prefix, or a
    /// bare [panic] line from the engine itself).
    case panic(String)

    static let prefix = "[pdos-install]"

    /// Parses one console line (as delivered by the console bridge, i.e. with
    /// a "log: " / "error: " level prefix — matched anywhere in the line).
    /// Unknown install breadcrumbs (phase banners, capture-error notes, …)
    /// and unrelated lines return nil.
    static func parse(_ line: String) -> InstallBreadcrumb? {
        if let r = line.range(of: prefix) {
            let tail = line[r.upperBound...].trimmingCharacters(in: .whitespaces)
            if tail == "ci-ready" { return .ciReady }
            if tail == "waiting for go" { return .waitingForGo }
            if tail.hasPrefix("captured ") {
                let parts = tail.split(separator: " ")
                guard parts.count >= 3, let count = Int(parts[1]), let bytes = Int(parts[2]),
                      count >= 0, bytes >= 0 else { return nil }
                return .captured(count: count, bytes: bytes)
            }
            if tail.hasPrefix("capture-regressed") { return .captureRegressed }
            if tail.contains("[panic]") { return .panic(String(tail)) }
            return nil
        }
        // Engine panics that predate the install page's console.error re-emit
        // hook (e.g. during bundle build) arrive without the install prefix.
        if line.contains("[panic]") { return .panic(line) }
        return nil
    }
}

// MARK: - Capture plateau detection

/// Decides when a stage's disk writes have SETTLED, from the stream of
/// accepted capture counts. Runbook rule: the same count on ≥4 consecutive
/// ticks, after the count passed 300,000 (phase-1's file copy is well past
/// that; earlier plateaus are just Setup not having started yet).
///
/// Two guards beyond the raw rule:
///  - MONOTONIC: a count below the accepted floor is rejected outright (a
///    persist racing a guest reboot can return a partial set — accepting it
///    would regress the held state). Rejections do NOT break a plateau run.
///  - GROWTH ARMING (`requireGrowth`): the plateau only fires after the count
///    has strictly INCREASED at least once within this detector's lifetime.
///    Stages 2/3 (and stage-1 retries) boot with the count already above the
///    minimum — without arming, the first four idle boot ticks would read as
///    "installation settled" before Setup wrote anything.
struct CapturePlateauDetector: Equatable {
    enum Verdict: Equatable {
        case rejected   // below the monotonic floor — discard
        case accepted   // fresh data, no plateau yet
        case plateau    // the stage's writes have settled
    }

    let minimumCount: Int
    let plateauTicks: Int
    let requireGrowth: Bool

    private(set) var lastAccepted: Int?
    private(set) var firstAccepted: Int?
    private(set) var consecutiveSame = 0
    private(set) var hasGrown = false

    /// Sectors written since this detector's FIRST accepted capture — i.e.
    /// since its stage boot. Stage 2's death classifier reads this as "how
    /// much did Setup actually do this session" (the first accepted capture
    /// reports the re-seeded checkpoint's count, so growth measures new work).
    var growthSinceFirstAccepted: Int {
        guard let first = firstAccepted, let last = lastAccepted else { return 0 }
        return last - first
    }

    init(minimumCount: Int = 300_000, plateauTicks: Int = 4, requireGrowth: Bool = true) {
        self.minimumCount = minimumCount
        self.plateauTicks = plateauTicks
        self.requireGrowth = requireGrowth
    }

    mutating func ingest(_ count: Int) -> Verdict {
        if let last = lastAccepted, count < last { return .rejected }
        if firstAccepted == nil { firstAccepted = count }
        if let last = lastAccepted, count == last {
            consecutiveSame += 1
        } else {
            if lastAccepted != nil { hasGrown = true }
            lastAccepted = count
            consecutiveSame = 1
        }
        if consecutiveSame >= plateauTicks, count > minimumCount, hasGrown || !requireGrowth {
            return .plateau
        }
        return .accepted
    }
}

// MARK: - Stage state machine

/// What stage 2 accomplished before it died — the discriminator between the
/// EXPECTED finalize restart (Windows' first shutdown kills the WASM at the
/// end of hardware setup, 13-17 min in) and an early engine crash (the device
/// run OOM-killed the WebContent process ~3 captures into GUI Setup, and
/// misreading that as the finalize stranded stage 3 on an unadvanced wizard
/// page). Either arm suffices: real Setup work takes TIME and writes HEAVILY,
/// while a death on the wizard's opening pages shows neither.
struct Stage2DeathEvidence: Equatable {
    /// Seconds stage 2 ran (from its go release) before the death.
    var runtime: TimeInterval
    /// Sectors added since stage 2's first accepted capture this boot.
    var captureGrowth: Int

    /// The finalize shutdown lands 13-17 min in; the scripted wizard pages
    /// never legitimately take 8. Strictly MORE is required.
    static let finalizeMinRuntime: TimeInterval = 8 * 60
    /// Wizard page flips write ~nothing; Setup's copy/hardware phases write
    /// tens of thousands of sectors. Strictly MORE is required.
    static let finalizeMinGrowth = 10_000

    var indicatesFinalizeRestart: Bool {
        runtime > Self.finalizeMinRuntime || captureGrowth > Self.finalizeMinGrowth
    }
}

/// The stage-progression + retry authority. The orchestrator reports what
/// happened (boot outcome, plateau, death) and this answers with the ONE next
/// move, so the retry budgets live — and are tested — in one place.
///
/// Budgets, from the runbook:
///  - a stage load that never reaches ci-ready (90 s timeout or an instant
///    [panic]) is retried on the SAME stage, ≤3 attempts per boot episode;
///  - a mid-stage death in stage 2 WITH finalize-shaped evidence is EXPECTED
///    (Windows' first shutdown kills the WASM) and transitions to stage 3
///    free of charge;
///  - any other mid-stage death (stage 1, stage 3, an EARLY stage-2 crash,
///    or capture silence >5 min) re-boots that stage — for stage 2 that
///    means re-seeding the checkpoint and RE-RUNNING the keystroke script —
///    drawing on a shared recovery budget of 3.
struct InstallFlow: Equatable {
    enum Stage: String, Equatable {
        case stage1   // floppy boot: unattended Setup phase-1 (file copy)
        case stage2   // boot C: + scripted keystrokes + hardware setup
        case stage3   // recovery boot C:, hands-off, to the desktop
    }

    enum Next: Equatable {
        case bootStage(Stage, attempt: Int)
        case finalizeReady
        case failed(String)
    }

    static let maxBootAttempts = 3
    static let maxRecoveryBoots = 3

    private(set) var stage: Stage = .stage1
    private(set) var bootAttempt = 1
    private(set) var recoveryBoots = 0

    /// The opening move (after media build): boot stage 1, attempt 1.
    func begin() -> Next { .bootStage(.stage1, attempt: 1) }

    /// The current stage's page never reached ci-ready (timeout / instant panic).
    mutating func bootFailed() -> Next {
        bootAttempt += 1
        guard bootAttempt <= Self.maxBootAttempts else {
            return .failed("\(stage.rawValue) never booted after \(Self.maxBootAttempts) attempts")
        }
        return .bootStage(stage, attempt: bootAttempt)
    }

    /// ci-ready arrived — this boot episode's budget is settled.
    mutating func bootSucceeded() {
        bootAttempt = 1
    }

    /// The stage reached its capture plateau (its writes settled) and any
    /// required pull completed.
    mutating func stageEnded() -> Next {
        switch stage {
        case .stage1:
            stage = .stage2
            bootAttempt = 1
            return .bootStage(.stage2, attempt: 1)
        case .stage2:
            // Not reached in practice (stage 2 ends by dying), but a stage 2
            // that settles without dying still wants the same recovery boot.
            stage = .stage3
            bootAttempt = 1
            return .bootStage(.stage3, attempt: 1)
        case .stage3:
            return .finalizeReady
        }
    }

    /// The stage died mid-run: engine [panic], WebContent process gone, or
    /// capture silence past the watchdog.
    ///
    /// Stage 2's death is AMBIGUOUS, so its caller passes what the stage
    /// actually DID: only a death that looks like the end of real Setup work
    /// (`indicatesFinalizeRestart`) advances to stage 3. An early death —
    /// including nil evidence — re-runs stage 2 on the shared recovery
    /// budget, which re-seeds the checkpoint and re-runs the keystrokes.
    mutating func died(stage2Evidence evidence: Stage2DeathEvidence? = nil) -> Next {
        if stage == .stage2, evidence?.indicatesFinalizeRestart == true {
            // THE expected death: "Windows is shutting down" kills the WASM.
            stage = .stage3
            bootAttempt = 1
            return .bootStage(.stage3, attempt: 1)
        }
        recoveryBoots += 1
        guard recoveryBoots <= Self.maxRecoveryBoots else {
            return .failed("\(stage.rawValue) kept dying after \(Self.maxRecoveryBoots) recovery reboots")
        }
        bootAttempt = 1
        return .bootStage(stage, attempt: 1)
    }
}

// MARK: - Stage-2 keystroke loop & stage-3 desktop probe (pure halves)

/// One native-driven keystroke step: evaluate `js` in the page, or idle.
/// The orchestrator interprets these SWIFT-side (so the timing logic stays
/// out of the page and the shapes stay unit-testable); the only in-page
/// timer remains the capture loop.
enum ScriptStep: Equatable {
    case press(js: String)
    case wait(seconds: TimeInterval)
}

/// Stage 2's wizard-advancing script. The device run killed the old
/// fixed-delay keystroke table (device Setup paints far slower than the
/// Chrome runbook timings it encoded), so the pages are now advanced by
/// REPEATED cycles that are safe wherever Setup happens to be: pre-filled
/// pages advance on Enter, a disabled Next button no-ops, and only the
/// License page needs the Alt+A accept chord before its Enter. The loop
/// exits on EVIDENCE — capture growth proving Setup moved into its
/// copy/hardware work — never on elapsed time.
enum SetupScript {
    /// Idle lead-in after the go release: the C: boot plus Setup's first
    /// wizard paint.
    static let leadInSeconds: TimeInterval = 60
    /// Hard cap on cycles per stage-2 boot (each cycle is breadcrumbed:
    /// "[pdos-install] script-cycle N").
    static let maxCycles = 12
    /// Setup advanced once the count grew this far past the loop-start
    /// baseline (strictly more): page flips write ~nothing, while the
    /// copy/hardware phases write thousands of sectors.
    static let advancedGrowth = 3_000

    /// Enter (advance page) → settle → Alt+A (License accept) → beat →
    /// Enter (License Next) → settle; the caller then checks growth.
    static let cycle: [ScriptStep] = [
        .press(js: InstallJS.pressEnter), .wait(seconds: 8),
        .press(js: InstallJS.pressAltA), .wait(seconds: 1.5),
        .press(js: InstallJS.pressEnter), .wait(seconds: 8),
    ]

    static func hasAdvanced(baseline: Int, latest: Int) -> Bool {
        latest - baseline > advancedGrowth
    }
}

/// Stage 3's "is that plateau really the desktop?" probe. The device run
/// plateaued on a WAITING wizard page and declared done — so a plateau is
/// now poked before it is trusted: a real desktop swallows the keys with
/// zero disk writes (flat → done), a waiting wizard page advances and
/// writes (grew → keep watching for the next plateau). Breadcrumbed as
/// "[pdos-install] desktop-probe flat|grew".
enum DesktopProbe {
    /// Probes per stage-3 boot; a plateau after the budget is trusted
    /// (finalize's mouse-fix guard stays the last backstop).
    static let maxProbes = 3
    /// Accepted-capture ticks to let the poked page settle before the
    /// flat-or-grew comparison.
    static let settleTicks = 3

    /// Same key pattern as a script cycle, compressed: anything a wizard
    /// page could be waiting on, harmless on a desktop.
    static let cycle: [ScriptStep] = [
        .press(js: InstallJS.pressEnter), .wait(seconds: 2),
        .press(js: InstallJS.pressAltA), .wait(seconds: 1.5),
        .press(js: InstallJS.pressEnter),
    ]

    /// Counts are monotonic (the in-page floor guards regressions), so
    /// "didn't grow" IS "stayed flat".
    static func isFlat(baseline: Int, latest: Int) -> Bool {
        latest <= baseline
    }
}

// MARK: - Injected JavaScript

/// The JS the orchestrator injects into the install page. Kept as pure string
/// builders so tests can pin the load-bearing pieces (the persist call, the
/// monotonic floor, the live re-seed, the breadcrumb format).
enum InstallJS {

    /// js-dos key codes (src/window/dos/controls/keys.ts — the same table
    /// EmulatorController's key helpers use).
    static let pressEnter = "window.ci && window.ci.simulateKeyPress(257)"
    /// Alt+A chord (License page's "I accept" accelerator): simulateKeyPress
    /// with two codes presses them together.
    static let pressAltA = "window.ci && window.ci.simulateKeyPress(342, 65)"

    /// Console breadcrumb for NATIVE-driven moves (script cycles, desktop
    /// probes): same prefix, same stream as the page's own breadcrumbs, so a
    /// pulled device log reads as ONE interleaved story. These tails parse
    /// to nil natively (informational only).
    static func logBreadcrumb(_ tail: String) -> String {
        "console.log(\(quoted("\(InstallBreadcrumb.prefix) \(tail)")));"
    }

    /// Stops the capture loop (set before the FINAL pull so no fresher persist
    /// replaces `__lastGood` while the finalize is deciding).
    static let stopCaptureLoop =
        "window.__pdosCapStop = true; "
        + "if (window.__pdosCapTimer) { clearInterval(window.__pdosCapTimer); window.__pdosCapTimer = null; } "
        + "true;"

    /// Minimal string escape for embedding orchestrator-built values (custom-
    /// scheme URLs — controlled charset, but escape defensively anyway).
    static func quoted(_ s: String) -> String {
        var out = "\""
        for ch in s.unicodeScalars {
            switch ch {
            case "\"": out += "\\\""
            case "\\": out += "\\\\"
            case "\n": out += "\\n"
            case "\r": out += "\\r"
            default: out.unicodeScalars.append(ch)
            }
        }
        return out + "\""
    }

    /// The in-page capture loop, armed after each stage's ci-ready. Every
    /// 4.5 s it runs `ci.persist(true)`, picks the TARGET drive's serialized
    /// sector-diff (matched by exact base URL — two sockdrives are mounted in
    /// stages 1/2, so a positional fallback could grab the CAB source), reads
    /// the u32le record count at byte 0, and — monotonic guard — if the count
    /// is >= the accepted floor: holds the blob as `window.__lastGood`, re-
    /// seeds it LIVE into IndexedDB (`pdosReseed`), and logs
    /// `[pdos-install] captured <count> <bytes>` for the native watcher.
    ///
    /// `floor` seeds the monotonic guard ACROSS page reloads: the page-local
    /// floor dies with the page, so a partial persist on the first tick of a
    /// recovery boot could otherwise be accepted and re-seeded — regressing
    /// IndexedDB. The orchestrator passes the highest count it has ever seen.
    ///
    /// The pull channel (`pdosCapPullBegin/Chunk/End`) mirrors the
    /// pdosPersistBegin/Chunk/End transport shape: begin pins the CURRENT
    /// `__lastGood` reference (persist passes replace, never mutate, so the
    /// pinned blob stays coherent while ticks continue), chunks stream base64.
    static func captureLoop(targetBase: String, floor: Int) -> String {
        """
        (function () {
          if (window.__pdosCapTimer) { clearInterval(window.__pdosCapTimer); window.__pdosCapTimer = null; }
          window.__pdosCapStop = false;
          var TARGET = \(quoted(targetBase));
          var last = \(max(0, floor));
          var busy = false;
          function b64(u8) {
            var s = "", CHUNK = 0x8000;
            for (var i = 0; i < u8.length; i += CHUNK) {
              s += String.fromCharCode.apply(null, u8.subarray(i, i + CHUNK));
            }
            return btoa(s);
          }
          window.pdosCapPullBegin = function () {
            window.__pdosPull = window.__lastGood || null;
            return window.__pdosPull ? window.__pdosPull.length : 0;
          };
          window.pdosCapPullChunk = function (off, len) {
            var p = window.__pdosPull;
            if (!p) return "";
            var end = Math.min(off + len, p.length);
            if (off >= end) return "";
            return b64(p.subarray(off, end));
          };
          window.pdosCapPullEnd = function () { window.__pdosPull = null; return true; };
          async function tick() {
            if (busy || window.__pdosCapStop) return;
            busy = true;
            try {
              if (!window.ci || typeof window.ci.persist !== "function") return;
              var out = await Promise.race([
                window.ci.persist(true),
                new Promise(function (resolve, reject) {
                  setTimeout(function () { reject(new Error("persist timeout")); }, 60000);
                })
              ]);
              var bytes = null;
              if (out && out.drives) {
                for (var i = 0; i < out.drives.length; i++) {
                  if (out.drives[i].url === TARGET) { bytes = out.drives[i].persist; break; }
                }
              }
              if (!bytes || !bytes.subarray || bytes.length < 4) {
                console.log("[pdos-install] capture-miss");
                return;
              }
              var count = (bytes[0] | (bytes[1] << 8) | (bytes[2] << 16) | (bytes[3] << 24)) >>> 0;
              if (count >= last) {
                last = count;
                window.__lastGood = bytes;
                await window.pdosReseed(TARGET, bytes);
                console.log("[pdos-install] captured " + count + " " + bytes.length);
              } else {
                console.log("[pdos-install] capture-regressed " + count + " " + last);
              }
            } catch (e) {
              console.log("[pdos-install] capture-error " + (e && e.message ? e.message : e));
            } finally { busy = false; }
          }
          window.__pdosCapTimer = setInterval(tick, 4500);
        })();
        """
    }

    /// Stage 2/3 launch: on "[pdos-install] waiting for go", fetch the pulled
    /// stage checkpoint and re-seed it into IndexedDB BEFORE the sockdrive
    /// mounts, then release the parked boot. A failed fetch does NOT wedge the
    /// stage: the capture loop re-seeded IndexedDB live on every accepted
    /// capture, so the store already holds the last good state — log and go.
    static func reseedAndGo(stageBinURL: String, targetBase: String) -> String {
        """
        (async function () {
          try {
            var r = await fetch(\(quoted(stageBinURL)), { cache: "no-store" });
            if (r.ok) {
              var bytes = new Uint8Array(await r.arrayBuffer());
              if (bytes.length >= 4) { await window.pdosReseed(\(quoted(targetBase)), bytes); }
            } else {
              console.log("[pdos-install] reseed-skip HTTP " + r.status);
            }
          } catch (e) {
            console.log("[pdos-install] reseed-skip " + (e && e.message ? e.message : e));
          }
          if (window.pdosInstallGo) { window.pdosInstallGo(); }
          else { console.log("[pdos-install] go-missing"); }
        })();
        """
    }
}

// MARK: - Overlay header

/// The u32le sector-record count at byte 0 of a serialized sockdrive write
/// overlay — the same field the in-page capture loop reads. The orchestrator
/// floors each stage-2/3 boot's capture loop at the count of the checkpoint
/// it just re-seeded: a stage-2 retry deliberately restores an OLDER
/// checkpoint, and flooring at the run's global high water would make the
/// page reject every persist (no accepted captures → no live re-seed, and a
/// spurious silence death) until Setup re-crossed the stale mark.
func sockdriveOverlayRecordCount(_ header: Data) -> Int? {
    guard header.count >= 4 else { return nil }
    let b = [UInt8](header.prefix(4))
    return Int(b[0]) | Int(b[1]) << 8 | Int(b[2]) << 16 | Int(b[3]) << 24
}

// MARK: - Final game shape

/// The library entry an installed machine becomes: a bundle-less sockdrive
/// game (chunks in `drive/`, install writes in `sockdrive-write.bin`), mouse
/// controls (it's a desktop OS), 64 MB emulated RAM (the memsize the whole
/// install ran with), identity = SHA256 of the small deterministic metaj —
/// exactly the shape `GameStore.loadGame` reads back.
func installedWin98Game(id: String, folderURL: URL) -> Game {
    var game = Game(id: id, title: "Windows 98", bundleFileName: "",
                    folderURL: folderURL, controlProfile: .mouse)
    game.memoryMB = 64
    game.contentHash = sha256Hex(ofFileAt: folderURL.appendingPathComponent("drive/sockdrive.metaj"))
    return game
}
