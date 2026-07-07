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
// In stages 2/3, a guest reboot the page SURVIVES (no panic — frequent on
// device) remounts STALE boot-boundary IndexedDB; two consecutive regressed
// captures detect it and the stage reloads on the freshest pulled
// checkpoint, unbudgeted (RegressedRunDetector — the device-run-#3 fix),
// with the install state carried between stages as the target sockdrive's
// write-overlay blob, captured in-page via `ci.persist(true)` on a per-stage
// cadence (CaptureCadence). Stage 1's capture loop is TWO-PHASE (the
// device-run-#4 fix): while the overlay is small it re-seeds every accepted
// capture LIVE into IndexedDB (that re-seed is what makes early warm reboots
// and page reloads free), and past 200k sectors it switches in-place to the
// slow persist-only cadence stages 2/3 always run — per-tick serialize AND
// IndexedDB copy of a 120-150 MB overlay is ≈300+ MB of transient allocation
// per tick, the exact churn that Jetsam-killed run #2's stage 2 and run #4's
// stage-1 tail. Past the switch IndexedDB is deliberately stale, so stage
// 1's ends change too: its phase-1 completion warm reboot now surfaces as a
// REGRESSED run (the remount re-reads the stale store) and is treated like
// the plateau, and its mid-stage death recoveries boot parked and re-seed
// the pulled checkpoint exactly like stages 2/3 boot boundaries.

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
    /// The capture loop saw a persist BELOW the accepted floor and dropped it.
    /// ONE is noise (a persist racing a guest reboot can return a partial
    /// set); a RUN of them in stages 2/3 is the in-page guest-reboot signal
    /// (RegressedRunDetector — the device-run-#3 fix).
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

// MARK: - In-page guest-reboot detection (device run #3 fix)

/// Detects a guest reboot the PAGE SURVIVED, from the capture-verdict
/// breadcrumb stream (`captured` vs `capture-regressed`).
///
/// Stages 2/3 re-seed IndexedDB only at boot boundaries (the OOM fix), so
/// when Setup's mid-phase-2/3 reboot does NOT panic the engine — common on
/// device — the sockdrive remount re-reads the STALE boot-boundary state.
/// The guest then re-runs already-finished work while the monotonic floor
/// correctly rejects every persist: device run #3 sat through 15 consecutive
/// `capture-regressed` ticks (300 s) until the silence watchdog fired, and
/// the wasted re-climbs panicked mid-way often enough ("Out of bounds
/// call_indirect" at 424,289, just shy of the 424,539 floor) to leave the
/// FAT dirty — the ScanDisk complaints on later boots were this, not a
/// separate bug. Through all of it the page stays ALIVE and
/// `window.__lastGood` still holds the newest good pre-reboot snapshot
/// (the floor rejected the regressed captures, so it was never clobbered) —
/// exactly what the stage reload should pull and re-seed.
///
/// The in-memory sector store only ever GROWS between mounts, so while one
/// rejection is normal reboot-race noise, two consecutive rejections mean a
/// remount happened: answer with an IMMEDIATE stage reload on the freshest
/// checkpoint. The 5-minute silence watchdog stays as the fallback, never
/// the plan.
struct RegressedRunDetector: Equatable {
    /// Consecutive rejected persists that mean "the guest rebooted in-page".
    static let bootBoundaryRun = 2

    /// Stage 1's regressed run only means something LATE: past the cadence
    /// switch IndexedDB is deliberately stale, so phase-1's completion warm
    /// reboot (the one-shot park) remounts BELOW the floor and regresses —
    /// the file copy is well past this mark by then (the same bar as the
    /// plateau's minimumCount). Below it, regressions are early-boot noise.
    static let stage1CompleteFloor = 300_000

    /// Whether a regressed run may fire for `stage`.
    ///
    /// Stages 2/3 always arm (the device-run-#3 fix: a surviving guest
    /// reboot remounts stale boot-boundary IndexedDB and the floor rejects
    /// every persist until the stage reloads).
    ///
    /// Stage 1 arms only for its phase-1 COMPLETION signal (device run #4:
    /// with the two-phase capture loop, IndexedDB goes stale past the
    /// switch, so the completion warm reboot regresses instead of
    /// plateauing): the run's monotonic floor must be PAST the file copy
    /// (`floor > stage1CompleteFloor`, strictly) AND this boot must have
    /// accepted at least one capture — acceptance is what proves the page
    /// still holds a fresh post-floor `window.__lastGood` to pull. A fresh
    /// recovery boot re-climbing toward a high floor regresses for a while
    /// without ever having accepted; firing there would pull an EMPTY
    /// `__lastGood` and advance to stage 2 on a half-copied Windows.
    static func arms(for stage: InstallFlow.Stage, floor: Int, acceptedThisBoot: Bool) -> Bool {
        if stage != .stage1 { return true }
        return floor > Self.stage1CompleteFloor && acceptedThisBoot
    }

    private(set) var consecutiveRegressed = 0

    /// Ingests one `capture-regressed` breadcrumb. True = boundary reached
    /// (and it stays reached until an accepted capture breaks the run).
    mutating func regressed() -> Bool {
        consecutiveRegressed += 1
        return consecutiveRegressed >= Self.bootBoundaryRun
    }

    /// Ingests one accepted capture: any acceptance breaks the run.
    mutating func accepted() {
        consecutiveRegressed = 0
    }
}

/// How a running stage stopped early, in PRIORITY order: a death (panic /
/// process kill) arriving during or after a fired regressed run is the SAME
/// reboot boundary — the stale re-climb panicking mid-way was device run
/// #3's signature — so it reloads with the freshest checkpoint instead of
/// double-counting against the recovery budget.
enum StageInterruption: Equatable {
    /// Reload the stage, unbudgeted (the stage deadline is the only bound).
    case guestReboot
    /// Budgeted recovery (panic / process kill / capture silence).
    case death

    static func classify(rebootBoundary: Bool, death: Bool) -> StageInterruption? {
        if rebootBoundary { return .guestReboot }
        if death { return .death }
        return nil
    }
}

/// What a FIRED reboot boundary means, per stage. Stages 2/3 reload the same
/// stage on the freshest pulled checkpoint (device run #3). Stage 1's is the
/// phase-1 COMPLETION signal (device run #4): with the two-phase capture
/// loop, IndexedDB is stale past the cadence switch, so Setup's end-of-copy
/// warm reboot into the one-shot park remounts below the floor and REGRESSES
/// where it used to plateau — the orchestrator answers it exactly like the
/// plateau (snapshot-pin + pull `__lastGood` → stage.bin → stage 2). The
/// plateau path itself stays: it still fires when the store happened to be
/// fresh at the reboot (e.g. right after a recovery boot's re-seed).
enum RebootBoundaryResponse: Equatable {
    case phase1Complete   // stage 1: pull __lastGood → stage.bin → stage 2
    case reloadStage      // stages 2/3: reload on the freshest checkpoint

    static func response(for stage: InstallFlow.Stage) -> RebootBoundaryResponse {
        stage == .stage1 ? .phase1Complete : .reloadStage
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
///  - a mid-stage guest reboot the PAGE survived (2 consecutive regressed
///    captures in stages 2/3, RegressedRunDetector) reloads the SAME stage
///    free of charge too — a Win98 install legitimately reboots 2-3 times
///    mid-phase-2/3, plus panic flake — bounded only by the stage deadline,
///    which reboot-boundary reloads deliberately do NOT restart;
///  - any other mid-stage death (stage 1, stage 3, an EARLY stage-2 crash,
///    or capture silence >5 min) re-boots that stage — for stage 2 that
///    means re-seeding the checkpoint and RE-RUNNING the keystroke script —
///    drawing on a shared recovery budget of 5 (device run #4 burned 4
///    productive deaths mid-stage-1, each of which demonstrably resumed
///    from its checkpoint and progressed; failing a 30-60 min run at 3
///    was too tight).
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
    static let maxRecoveryBoots = 5

    private(set) var stage: Stage = .stage1
    private(set) var bootAttempt = 1
    private(set) var recoveryBoots = 0
    /// In-page guest reboots answered with an unbudgeted stage reload —
    /// counted for forensics only (the stage deadline bounds them, not this).
    private(set) var rebootBoundaries = 0

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

    /// The guest rebooted IN-PAGE and the page survived (stages 2/3: the
    /// remount re-read stale boot-boundary IndexedDB, so the stage must
    /// reload on the freshest pulled checkpoint). This is EXPECTED
    /// Windows-Setup behavior — phase 2/3 legitimately reboots 2-3 times —
    /// so it draws on NO death/recovery budget and resets the boot-attempt
    /// episode; the stage deadline (not restarted by these) is the bound.
    mutating func guestRebooted() -> Next {
        rebootBoundaries += 1
        bootAttempt = 1
        return .bootStage(stage, attempt: 1)
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

// MARK: - Capture transport cadence (per stage — device OOM fix)

/// Per-stage parameters for the injected capture loop. The second device run
/// proved the STATE MACHINE right (three clean stage-2 recovery boots) and
/// the TRANSPORT fatal: every 4.5 s tick ran `ci.persist(true)` AND a live
/// IndexedDB re-seed, so with stage 2's ~150 MB overlay each tick transiently
/// allocated 300+ MB on top of the overlay map + wasm heap — iOS Jetsam
/// killed WebContent ~50-60 s after ci-ready, every boot. Run #4 showed
/// stage 1's TAIL hits the same wall (OOM-cycling at 120-148 MB, tick-ms
/// 1.4-2.0 s of serialize alone — earlier runs were winning Jetsam
/// roulette). Only the transport gets cheaper here; growth detection,
/// plateau, and lastGood recovery semantics are unchanged.
///  - Stage 1 is TWO-PHASE, switched in-place by the injected loop itself:
///    it starts at 4.5 s + live re-seed (early overlays are small, and the
///    re-seed is what makes early in-page warm reboots free), then past
///    `stage1SwitchCount` accepted sectors it flips to the slow persist-only
///    cadence — same transport as stages 2/3 — breadcrumbing one
///    "[pdos-install] cadence-switch".
///  - Stages 2/3 tick every 20 s with NO per-tick re-seed (persist only,
///    `__lastGood` held in page memory): live re-seed only serves in-page
///    guest warm reboots, stage-2/3's only reboot (the finalize restart)
///    kills the process anyway, and every boot boundary explicitly re-seeds
///    the pulled checkpoint (reseedAndGo).
///  - Plateau = 3 equal ticks ≈ 60 s at the 20 s cadence, for stage 1 too:
///    a plateau only ever FIRES above the 300k minimum, which is past the
///    200k switch — so the plateau-relevant cadence is always the slow one
///    (sub-switch plateaus don't occur, and wouldn't fire if they did).
enum CaptureCadence {
    /// Stage 1's in-place switch point (accepted sectors): past this the
    /// overlay is ~76 MB+ and per-tick re-seed churn becomes Jetsam bait.
    static let stage1SwitchCount = 200_000
    /// The slow persist-only tick (stages 2/3 always; stage 1 post-switch).
    static let slowTickSeconds: TimeInterval = 20

    static func tickSeconds(for stage: InstallFlow.Stage) -> TimeInterval {
        stage == .stage1 ? 4.5 : slowTickSeconds
    }
    static func liveReseed(for stage: InstallFlow.Stage) -> Bool {
        stage == .stage1
    }
    /// The two-phase switch threshold, nil = single-phase (stages 2/3).
    static func switchCount(for stage: InstallFlow.Stage) -> Int? {
        stage == .stage1 ? stage1SwitchCount : nil
    }
    static func plateauTicks(for stage: InstallFlow.Stage) -> Int {
        3
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
    /// wizard paint. Kept short — the cycle loop is idempotent, so keys that
    /// land before Setup's first page are safe, and a shorter lead-in gets
    /// the evidence (captures) flowing sooner.
    static let leadInSeconds: TimeInterval = 30
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
///
/// Incidental cover, known and relied on: if a dirty boot parks ScanDisk's
/// "check the drive?" prompt at a plateau, the probe's Enter presses
/// dismiss it and the boot continues (finalize's AutoScan=0 patch keeps
/// the prompt from recurring on the SHIPPED machine).
enum DesktopProbe {
    /// Probes per stage-3 boot; a plateau after the budget is trusted
    /// (finalize's mouse-fix guard stays the last backstop).
    static let maxProbes = 3
    /// Accepted-capture ticks to let the poked page settle before the
    /// flat-or-grew comparison (≈ 40 s at stage 3's 20 s capture cadence).
    static let settleTicks = 2

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
    /// `tickSeconds` it runs `ci.persist(true)`, picks the TARGET drive's
    /// serialized sector-diff (matched by exact base URL — two sockdrives are
    /// mounted in stages 1/2, so a positional fallback could grab the CAB
    /// source), reads the u32le record count at byte 0, and — monotonic
    /// guard — if the count is >= the accepted floor: holds the blob as
    /// `window.__lastGood` and logs `[pdos-install] captured <count> <bytes>`
    /// for the native watcher. Every persist also logs
    /// `[pdos-install] tick-ms <ms>` — the serialize cost — so pulled device
    /// logs show what each tick spent (the OOM forensic that was missing).
    ///
    /// `liveReseed` additionally copies each accepted blob into IndexedDB
    /// (`pdosReseed`). Stage 1 wants that EARLY: the re-seed is what lets
    /// phase-1's in-page warm reboots resume, and stage-1 overlays start
    /// small. It must not keep it LATE (device run #4): past
    /// `reseedSwitchCount` accepted sectors the loop switches itself —
    /// clearInterval + setInterval, no Swift round-trip — to
    /// `switchedTickSeconds` persist-only ticks, logging one
    /// `[pdos-install] cadence-switch`, because serialize + IndexedDB copy
    /// of a 120-150 MB overlay every 4.5 s is ≈300+ MB of transient
    /// allocation per tick and Jetsam kills WebContent for it. The `live`
    /// flag is BAKED from the floor, so a recovery boot floored past the
    /// switch starts slow/persist-only outright. Stages 2/3 run persist-only
    /// at the slow tick always (CaptureCadence, `reseedSwitchCount` nil):
    /// their only reboot (the finalize restart) kills the process anyway,
    /// and every boot boundary explicitly re-seeds the pulled checkpoint
    /// (reseedAndGo).
    ///
    /// `floor` seeds the monotonic guard ACROSS page reloads: the page-local
    /// floor dies with the page, so a partial persist on the first tick of a
    /// recovery boot could otherwise be accepted and re-seeded — regressing
    /// IndexedDB. The orchestrator passes the count of the checkpoint this
    /// boot actually resumes from (captureFloor).
    ///
    /// The pull channel (`pdosCapPullBegin/Chunk/End`) mirrors the
    /// pdosPersistBegin/Chunk/End transport shape: begin pins the CURRENT
    /// `__lastGood` reference (persist passes replace, never mutate, so the
    /// pinned blob stays coherent while ticks continue), chunks stream base64.
    static func captureLoop(targetBase: String, floor: Int,
                            tickSeconds: TimeInterval, liveReseed: Bool,
                            reseedSwitchCount: Int? = nil,
                            switchedTickSeconds: TimeInterval = CaptureCadence.slowTickSeconds) -> String {
        let tickMs = Int((tickSeconds * 1000).rounded())
        let slowMs = Int((switchedTickSeconds * 1000).rounded())
        let phaseLine: String
        let reseedLine: String
        let switchLine: String
        let armExpr: String
        if liveReseed, let cut = reseedSwitchCount {
            // Two-phase (stage 1): fast + live re-seed while small, then an
            // in-place flip to slow persist-only. `live` bakes from the floor
            // so a checkpoint-floored recovery boot starts already switched.
            phaseLine = "var live = \(floor < cut);"
            reseedLine = "if (live) { await window.pdosReseed(TARGET, bytes); }"
            switchLine = "if (live && count >= \(cut)) { live = false; "
                + "clearInterval(window.__pdosCapTimer); "
                + "window.__pdosCapTimer = setInterval(tick, \(slowMs)); "
                + "console.log(\"[pdos-install] cadence-switch\"); }"
            armExpr = "live ? \(tickMs) : \(slowMs)"
        } else if liveReseed {
            phaseLine = ""
            reseedLine = "await window.pdosReseed(TARGET, bytes);"
            switchLine = ""
            armExpr = "\(tickMs)"
        } else {
            phaseLine = ""
            reseedLine = "/* no per-tick re-seed (device OOM fix): boot boundaries re-seed the pulled checkpoint */"
            switchLine = ""
            armExpr = "\(tickMs)"
        }
        return """
        (function () {
          if (window.__pdosCapTimer) { clearInterval(window.__pdosCapTimer); window.__pdosCapTimer = null; }
          window.__pdosCapStop = false;
          var TARGET = \(quoted(targetBase));
          var last = \(max(0, floor));
          var busy = false;
          \(phaseLine)
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
              var t0 = performance.now();
              var out = await Promise.race([
                window.ci.persist(true),
                new Promise(function (resolve, reject) {
                  setTimeout(function () { reject(new Error("persist timeout")); }, 60000);
                })
              ]);
              console.log("[pdos-install] tick-ms " + Math.round(performance.now() - t0));
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
                \(reseedLine)
                console.log("[pdos-install] captured " + count + " " + bytes.length);
                \(switchLine)
              } else {
                console.log("[pdos-install] capture-regressed " + count + " " + last);
              }
            } catch (e) {
              console.log("[pdos-install] capture-error " + (e && e.message ? e.message : e));
            } finally { busy = false; }
          }
          window.__pdosCapTimer = setInterval(tick, \(armExpr));
        })();
        """
    }

    /// Parked-boot launch (stages 2/3 always; stage-1 recovery boots once a
    /// pulled checkpoint exists): on "[pdos-install] waiting for go", fetch
    /// the pulled stage checkpoint and re-seed it into IndexedDB BEFORE the
    /// sockdrive mounts, then release the parked boot. A failed fetch does
    /// NOT wedge the stage: IndexedDB still holds the last state re-seeded
    /// into it (a prior boundary's checkpoint, or stage 1's live re-seeds up
    /// to the cadence switch) — log and go, and let the guest re-climb.
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
