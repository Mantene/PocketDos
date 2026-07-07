import XCTest
@testable import PocketDOS

/// Pure-logic coverage for the install orchestration (InstallFlow.swift): the
/// breadcrumb grammar the native side parses off the console bridge, the
/// monotonic-guard/plateau detector that decides when a stage's writes have
/// settled, the stage/retry state machine, the injected-JS builders, and the
/// meta.json shape the finished machine registers with. No WebView anywhere —
/// the full pipeline's device run is a manual step by design.
final class InstallOrchestratorTests: XCTestCase {

    // MARK: - Breadcrumb parser

    func testParsesCiReadyWithConsoleLevelPrefix() {
        // The console bridge prepends "log: " — the parser must match the
        // breadcrumb anywhere in the line, not at its start.
        XCTAssertEqual(InstallBreadcrumb.parse("log: [pdos-install] ci-ready"), .ciReady)
    }

    func testParsesWaitingForGo() {
        XCTAssertEqual(InstallBreadcrumb.parse("log: [pdos-install] waiting for go"),
                       .waitingForGo)
    }

    func testParsesCapturedCountAndBytes() {
        XCTAssertEqual(InstallBreadcrumb.parse("log: [pdos-install] captured 312345 161234567"),
                       .captured(count: 312_345, bytes: 161_234_567))
    }

    func testMalformedCapturedLineIsRejectedNotMisparsed() {
        XCTAssertNil(InstallBreadcrumb.parse("log: [pdos-install] captured oops 123"))
        XCTAssertNil(InstallBreadcrumb.parse("log: [pdos-install] captured 123"))
        XCTAssertNil(InstallBreadcrumb.parse("log: [pdos-install] captured -5 10"))
    }

    func testParsesPanicWithAndWithoutInstallPrefix() {
        // Re-emitted under the install prefix by the page's console.error hook…
        XCTAssertEqual(InstallBreadcrumb.parse("log: [pdos-install] [panic] wasm trap"),
                       .panic("[panic] wasm trap"))
        // …and the bare engine form (pre-hook panics during bundle build).
        XCTAssertEqual(InstallBreadcrumb.parse("error: [panic] null function"),
                       .panic("error: [panic] null function"))
    }

    func testUnrelatedAndInformationalLinesParseToNil() {
        XCTAssertNil(InstallBreadcrumb.parse("log: running — ci-ready"))          // no install prefix
        XCTAssertNil(InstallBreadcrumb.parse("log: [pdos-install] phase=boot-a target=x src=y floppy=yes"))
        XCTAssertNil(InstallBreadcrumb.parse("log: [pdos-install] capture-error persist timeout"))
        XCTAssertNil(InstallBreadcrumb.parse("log: [pdos-install] tick-ms 8342"),
                     "the serialize-cost breadcrumb is forensic only, never an event")
        XCTAssertNil(InstallBreadcrumb.parse("log: [pdos-install] cadence-switch"),
                     "stage 1's two-phase flip is forensic only, never an event")
        XCTAssertNil(InstallBreadcrumb.parse("log: [pdos-fps] raf=60.0 emu=60.0 act=0"))
        XCTAssertEqual(InstallBreadcrumb.parse("log: [pdos-install] capture-regressed 100 200"),
                       .captureRegressed)
    }

    // MARK: - Plateau detector

    func testMonotonicGuardRejectsRegressionsAndKeepsFloor() {
        var d = CapturePlateauDetector()
        XCTAssertEqual(d.ingest(400_000), .accepted)
        XCTAssertEqual(d.ingest(399_999), .rejected)   // a partial persist mid-reboot
        XCTAssertEqual(d.lastAccepted, 400_000)        // the floor survives the reject
        XCTAssertEqual(d.ingest(400_001), .accepted)   // and growth continues from it
    }

    func testPlateauFiresOnFourthConsecutiveEqualTickAboveMinimum() {
        var d = CapturePlateauDetector()   // min 300k, 4 ticks, growth required
        XCTAssertEqual(d.ingest(5_000), .accepted)     // early file copy
        XCTAssertEqual(d.ingest(310_000), .accepted)   // growth arms the detector
        XCTAssertEqual(d.ingest(310_000), .accepted)   // tick 2
        XCTAssertEqual(d.ingest(310_000), .accepted)   // tick 3
        XCTAssertEqual(d.ingest(310_000), .plateau)    // tick 4 — settled
    }

    func testNoPlateauBelowTheMinimumCount() {
        var d = CapturePlateauDetector()
        XCTAssertEqual(d.ingest(1_000), .accepted)
        XCTAssertEqual(d.ingest(2_000), .accepted)     // growth seen
        for _ in 0..<10 {
            XCTAssertEqual(d.ingest(2_000), .accepted, "below 300k must never read as settled")
        }
    }

    func testNoPlateauWithoutGrowthWhenSeededAboveMinimum() {
        // A stage-2 (or stage-1 retry) boot starts with the count already
        // huge (the seeded write store). Without the growth arming, the
        // first four idle boot ticks would read as "install finished".
        // (Stage 3 deliberately DROPS this arming — run #6, tested below —
        // because its desktop probe is the gate there.)
        var d = CapturePlateauDetector()
        for _ in 0..<8 {
            XCTAssertEqual(d.ingest(800_000), .accepted)
        }
        XCTAssertEqual(d.ingest(800_001), .accepted)   // Windows finally writes → armed
        XCTAssertEqual(d.ingest(800_001), .accepted)
        XCTAssertEqual(d.ingest(800_001), .accepted)
        XCTAssertEqual(d.ingest(800_001), .plateau)
    }

    func testGrowthResetsThePlateauRun() {
        var d = CapturePlateauDetector()
        XCTAssertEqual(d.ingest(300_500), .accepted)
        XCTAssertEqual(d.ingest(301_000), .accepted)   // armed
        XCTAssertEqual(d.ingest(301_000), .accepted)
        XCTAssertEqual(d.ingest(301_000), .accepted)
        XCTAssertEqual(d.ingest(302_000), .accepted)   // fresh writes — run restarts
        XCTAssertEqual(d.ingest(302_000), .accepted)
        XCTAssertEqual(d.ingest(302_000), .accepted)
        XCTAssertEqual(d.ingest(302_000), .plateau)
    }

    func testRejectedRegressionDoesNotBreakAPlateauRun() {
        var d = CapturePlateauDetector()
        XCTAssertEqual(d.ingest(300_500), .accepted)
        XCTAssertEqual(d.ingest(301_000), .accepted)   // armed, tick 1
        XCTAssertEqual(d.ingest(301_000), .accepted)   // tick 2
        XCTAssertEqual(d.ingest(300_900), .rejected)   // noise — must not reset the run
        XCTAssertEqual(d.ingest(301_000), .accepted)   // tick 3
        XCTAssertEqual(d.ingest(301_000), .plateau)    // tick 4
    }

    func testDetectorTracksGrowthSinceFirstAcceptedCapture() {
        // Stage 2's death classifier reads "how much did Setup actually do"
        // straight off the detector: the first accepted capture reports the
        // re-seeded checkpoint, so growth is genuinely new work.
        var d = CapturePlateauDetector()
        XCTAssertEqual(d.growthSinceFirstAccepted, 0, "no captures yet")
        _ = d.ingest(388_979)                          // the seeded checkpoint
        XCTAssertEqual(d.firstAccepted, 388_979)
        XCTAssertEqual(d.growthSinceFirstAccepted, 0)
        _ = d.ingest(388_979)                          // idle wizard ticks
        XCTAssertEqual(d.growthSinceFirstAccepted, 0)
        _ = d.ingest(401_690)                          // Setup wrote
        XCTAssertEqual(d.growthSinceFirstAccepted, 12_711)
        _ = d.ingest(150_000)                          // rejected partial persist
        XCTAssertEqual(d.firstAccepted, 388_979, "rejects must not move the baseline")
        XCTAssertEqual(d.growthSinceFirstAccepted, 12_711)
    }

    // MARK: - Capture transport cadence (device OOM fix)

    func testCaptureCadenceTablePerStage() {
        // stage → (tick, live re-seed, switch, plateau ticks). Stage 1 is
        // TWO-PHASE (device run #4: its 120-148 MB tail OOM-cycled on the
        // same per-tick serialize+re-seed churn that killed run #2's stage
        // 2): 4.5 s + live re-seed while the overlay is small — the re-seed
        // is what makes early in-page warm reboots free — then an in-page
        // switch to the slow persist-only cadence at 200k sectors. Stages
        // 2/3 tick at 20 s persist-only always (no switch).
        XCTAssertEqual(CaptureCadence.tickSeconds(for: .stage1), 4.5)
        XCTAssertTrue(CaptureCadence.liveReseed(for: .stage1))
        XCTAssertEqual(CaptureCadence.switchCount(for: .stage1), 200_000)
        XCTAssertEqual(CaptureCadence.stage1SwitchCount, 200_000)
        XCTAssertEqual(CaptureCadence.slowTickSeconds, 20)

        XCTAssertEqual(CaptureCadence.tickSeconds(for: .stage2), 20)
        XCTAssertFalse(CaptureCadence.liveReseed(for: .stage2))
        XCTAssertNil(CaptureCadence.switchCount(for: .stage2))
        XCTAssertEqual(CaptureCadence.plateauTicks(for: .stage2), 3)

        XCTAssertEqual(CaptureCadence.tickSeconds(for: .stage3), 20)
        XCTAssertFalse(CaptureCadence.liveReseed(for: .stage3))
        XCTAssertNil(CaptureCadence.switchCount(for: .stage3))
        XCTAssertEqual(CaptureCadence.plateauTicks(for: .stage3), 3)

        // Growth arming rides the same table (device run #6): stages 1/2
        // keep it, stage 3's watches fire on flat-at-floor ticks and let
        // the desktop probe gate the plateau instead.
        XCTAssertTrue(CaptureCadence.requireGrowth(for: .stage1))
        XCTAssertTrue(CaptureCadence.requireGrowth(for: .stage2))
        XCTAssertFalse(CaptureCadence.requireGrowth(for: .stage3))

        // A plateau can only FIRE above the 300k minimum, which is past the
        // 200k switch — so stage 1's plateau-relevant cadence is the slow
        // one and its plateau rule is 3 equal ticks ≈ 60 s, like stages 2/3
        // (the old 4-tick/4.5 s rule only covered sub-300k plateaus, which
        // cannot fire at all).
        XCTAssertEqual(CaptureCadence.plateauTicks(for: .stage1), 3)
        XCTAssertGreaterThan(CapturePlateauDetector().minimumCount,
                             CaptureCadence.stage1SwitchCount,
                             "every fireable plateau count is post-switch")
    }

    func testPlateauFiresOnThirdEqualTickAtTheSlowCadence() {
        // Stages 2/3 arm the detector with plateauTicks: 3 — at the 20 s tick
        // that is ≈ 60 s of settled writes, the same wall-clock confidence the
        // 4-tick rule gave at 4.5 s. The rest of the semantics (monotonic
        // floor, stage 2's growth arming — stage 3's watch is growth-free
        // since run #6, tested in its own section) are untouched by the
        // cadence change.
        var d = CapturePlateauDetector(plateauTicks: CaptureCadence.plateauTicks(for: .stage2))
        XCTAssertEqual(d.ingest(310_000), .accepted)   // seeded checkpoint
        XCTAssertEqual(d.ingest(320_000), .accepted)   // growth arms, tick 1
        XCTAssertEqual(d.ingest(320_000), .accepted)   // tick 2
        XCTAssertEqual(d.ingest(320_000), .plateau)    // tick 3 — settled
    }

    func testStage2DeathEvidenceStaysCountAndClockBasedAtAnyCadence() {
        // The re-entry classification never counted ticks: runtime is wall
        // clock and growth is SECTORS since the first accepted capture, so
        // the 20 s cadence only means the last pre-death capture can be up to
        // ~20 s stale — noise against the >8 min / >+10k-sector thresholds.
        XCTAssertEqual(Stage2DeathEvidence.finalizeMinRuntime, 8 * 60)
        XCTAssertEqual(Stage2DeathEvidence.finalizeMinGrowth, 10_000)
        var d = CapturePlateauDetector(plateauTicks: CaptureCadence.plateauTicks(for: .stage2))
        _ = d.ingest(388_979)                          // re-seeded checkpoint
        _ = d.ingest(401_690)                          // one slow tick of real Setup work
        let evidence = Stage2DeathEvidence(runtime: 60,
                                           captureGrowth: d.growthSinceFirstAccepted)
        XCTAssertTrue(evidence.indicatesFinalizeRestart,
                      "growth evidence must survive arriving in fewer, larger ticks")
    }

    // MARK: - Stage/retry state machine

    func testFlowBeginsByBootingStage1() {
        let flow = InstallFlow()
        XCTAssertEqual(flow.begin(), .bootStage(.stage1, attempt: 1))
    }

    func testBootRetriesThenFailsAfterThreeAttempts() {
        var flow = InstallFlow()
        _ = flow.begin()
        XCTAssertEqual(flow.bootFailed(), .bootStage(.stage1, attempt: 2))
        XCTAssertEqual(flow.bootFailed(), .bootStage(.stage1, attempt: 3))
        guard case .failed = flow.bootFailed() else {
            return XCTFail("the fourth boot attempt must fail the install")
        }
    }

    func testBootSuccessResetsTheAttemptBudget() {
        var flow = InstallFlow()
        _ = flow.begin()
        _ = flow.bootFailed()          // attempt 2
        flow.bootSucceeded()           // booted on the second try
        _ = flow.died()                // later mid-stage death → recovery reboot
        // The fresh boot episode gets a full budget again.
        XCTAssertEqual(flow.bootFailed(), .bootStage(.stage1, attempt: 2))
        XCTAssertEqual(flow.bootFailed(), .bootStage(.stage1, attempt: 3))
    }

    func testStage1PlateauMovesToStage2() {
        var flow = InstallFlow()
        _ = flow.begin()
        flow.bootSucceeded()
        XCTAssertEqual(flow.stageEnded(), .bootStage(.stage2, attempt: 1))
        XCTAssertEqual(flow.stage, .stage2)
    }

    /// Evidence that unambiguously reads as Windows' finalize shutdown.
    private let finalizeShapedDeath = Stage2DeathEvidence(runtime: 14 * 60,
                                                          captureGrowth: 60_000)
    /// Evidence shaped like the device run's OOM: seconds in, nothing written.
    private let earlyCrashDeath = Stage2DeathEvidence(runtime: 75, captureGrowth: 0)

    private func flowAtStage2() -> InstallFlow {
        var flow = InstallFlow()
        _ = flow.begin(); flow.bootSucceeded()
        _ = flow.stageEnded()          // → stage 2
        flow.bootSucceeded()
        return flow
    }

    func testStage2DeathIsTheExpectedTransitionToStage3() {
        var flow = flowAtStage2()
        // "Windows is shutting down" kills the WASM: NOT a failure, and it
        // must not draw on the recovery budget — but only a death whose
        // evidence looks like real Setup work counts.
        XCTAssertEqual(flow.died(stage2Evidence: finalizeShapedDeath),
                       .bootStage(.stage3, attempt: 1))
        XCTAssertEqual(flow.recoveryBoots, 0)
    }

    func testSharedRecoveryBudgetIsFive() {
        // Device run #4: four mid-stage-1 deaths, each of which resumed from
        // its checkpoint and made real progress (316k→344k→371k→399k
        // sectors) — failing a 30-60 min run at 3 was too tight. Boundaries
        // stay budget-free; this is the death budget only.
        XCTAssertEqual(InstallFlow.maxRecoveryBoots, 5)
    }

    func testStage3DeathsRetryThenExhaustTheRecoveryBudget() {
        var flow = flowAtStage2()
        _ = flow.died(stage2Evidence: finalizeShapedDeath)   // → stage 3 (expected)
        flow.bootSucceeded()
        for n in 1...InstallFlow.maxRecoveryBoots {
            XCTAssertEqual(flow.died(), .bootStage(.stage3, attempt: 1), "recovery \(n)")
        }
        guard case .failed = flow.died() else {
            return XCTFail("the sixth stage-3 death must fail the install")
        }
    }

    func testStage1DeathRebootsStage1OnTheRecoveryBudget() {
        var flow = InstallFlow()
        _ = flow.begin()
        flow.bootSucceeded()
        XCTAssertEqual(flow.died(), .bootStage(.stage1, attempt: 1))
        XCTAssertEqual(flow.recoveryBoots, 1)
        XCTAssertEqual(flow.stage, .stage1)
    }

    func testStage3PlateauIsTheFinalizeSignal() {
        var flow = flowAtStage2()
        _ = flow.died(stage2Evidence: finalizeShapedDeath)   // → stage 3
        flow.bootSucceeded()
        XCTAssertEqual(flow.stageEnded(), .finalizeReady)
    }

    // MARK: - Stage-2 death classification (device fix 1)

    func testStage2EarlyDeathRetriesStage2OnTheRecoveryBudget() {
        // The device run: WebContent OOM ~3 captures into GUI Setup. That is
        // NOT the finalize restart — stage 2 must re-boot (re-seed + re-run
        // the script), and it costs a recovery slot.
        var flow = flowAtStage2()
        XCTAssertEqual(flow.died(stage2Evidence: earlyCrashDeath),
                       .bootStage(.stage2, attempt: 1))
        XCTAssertEqual(flow.stage, .stage2)
        XCTAssertEqual(flow.recoveryBoots, 1)
    }

    func testStage2DeathClassifiesByRuntimeAlone() {
        // Past 8 minutes the shutdown story holds even if the growth arm
        // stayed quiet (e.g. the checkpoint already contained the copies).
        var flow = flowAtStage2()
        let evidence = Stage2DeathEvidence(runtime: 8 * 60 + 1, captureGrowth: 0)
        XCTAssertTrue(evidence.indicatesFinalizeRestart)
        XCTAssertEqual(flow.died(stage2Evidence: evidence), .bootStage(.stage3, attempt: 1))
        XCTAssertEqual(flow.recoveryBoots, 0)
    }

    func testStage2DeathClassifiesByGrowthAlone() {
        // Heavy writes prove Setup did real copy/hardware work regardless of
        // how fast the clock ran.
        var flow = flowAtStage2()
        let evidence = Stage2DeathEvidence(runtime: 60, captureGrowth: 10_001)
        XCTAssertTrue(evidence.indicatesFinalizeRestart)
        XCTAssertEqual(flow.died(stage2Evidence: evidence), .bootStage(.stage3, attempt: 1))
        XCTAssertEqual(flow.recoveryBoots, 0)
    }

    func testStage2DeathThresholdsAreStrictlyGreaterThan() {
        // Exactly AT both thresholds is still an early death (> not >=).
        let boundary = Stage2DeathEvidence(runtime: 8 * 60, captureGrowth: 10_000)
        XCTAssertFalse(boundary.indicatesFinalizeRestart)
        var flow = flowAtStage2()
        XCTAssertEqual(flow.died(stage2Evidence: boundary), .bootStage(.stage2, attempt: 1))
        XCTAssertEqual(flow.recoveryBoots, 1)
    }

    func testStage2DeathWithoutEvidenceIsTreatedAsEarly() {
        // nil evidence must fall on the SAFE side: retry, don't advance.
        var flow = flowAtStage2()
        XCTAssertEqual(flow.died(), .bootStage(.stage2, attempt: 1))
        XCTAssertEqual(flow.recoveryBoots, 1)
    }

    func testStage2EarlyDeathsExhaustTheSharedRecoveryBudget() {
        var flow = flowAtStage2()
        for n in 1...InstallFlow.maxRecoveryBoots {
            XCTAssertEqual(flow.died(stage2Evidence: earlyCrashDeath),
                           .bootStage(.stage2, attempt: 1), "recovery \(n)")
        }
        guard case .failed = flow.died(stage2Evidence: earlyCrashDeath) else {
            return XCTFail("the sixth early stage-2 crash must fail the install")
        }
    }

    func testStage2RetryStillAllowsTheLaterFinalizeTransition() {
        // Early crash → retry → the re-run's REAL finalize death still moves
        // to stage 3 without further budget draw.
        var flow = flowAtStage2()
        _ = flow.died(stage2Evidence: earlyCrashDeath)   // recovery 1
        flow.bootSucceeded()
        XCTAssertEqual(flow.died(stage2Evidence: finalizeShapedDeath),
                       .bootStage(.stage3, attempt: 1))
        XCTAssertEqual(flow.recoveryBoots, 1)
    }

    // MARK: - In-page guest-reboot boundary (device fix, run #3)

    func testTwoConsecutiveRegressionsAreTheRebootBoundary() {
        // Device run #3: a guest reboot the page SURVIVED remounted stale
        // boot-boundary IndexedDB, and the floor then rejected 15 straight
        // ticks (300 s) before the silence watchdog fired. Two consecutive
        // rejections are conclusive — the in-memory store only ever grows
        // between mounts — and must be answered without the watchdog wait.
        var run = RegressedRunDetector()
        XCTAssertFalse(run.regressed(), "ONE rejection is persist/reboot race noise")
        XCTAssertTrue(run.regressed(), "the second consecutive rejection IS the reboot")
        XCTAssertTrue(run.regressed(), "and it stays fired until something is accepted")
        XCTAssertEqual(RegressedRunDetector.bootBoundaryRun, 2)
    }

    func testAcceptedCaptureBreaksTheRegressedRun() {
        var run = RegressedRunDetector()
        _ = run.regressed()
        run.accepted()                 // a good persist landed in between
        XCTAssertFalse(run.regressed(), "the accepted capture reset the run")
        XCTAssertTrue(run.regressed(), "two consecutive again — boundary again")
    }

    func testRegressedRunDetectorAlwaysArmsForStages2And3() {
        // The run-#3 fix is floor-independent there: a surviving guest
        // reboot regresses against whatever the boot boundary re-seeded.
        XCTAssertTrue(RegressedRunDetector.arms(for: .stage2, floor: 0, acceptedThisBoot: false))
        XCTAssertTrue(RegressedRunDetector.arms(for: .stage3, floor: 0, acceptedThisBoot: false))
        XCTAssertTrue(RegressedRunDetector.arms(for: .stage2, floor: 800_000, acceptedThisBoot: true))
    }

    func testStage1RegressedRunArmsOnlyPastTheFileCopyFloor() {
        // Device run #4: with the two-phase capture loop, IndexedDB is stale
        // past the cadence switch, so phase-1's completion warm reboot
        // REGRESSES where it used to plateau — stage 1 must hear it. But
        // only PAST the file copy (the same 300k bar as the plateau's
        // minimum): early-boot regressions stay noise.
        XCTAssertEqual(RegressedRunDetector.stage1CompleteFloor, 300_000)
        XCTAssertFalse(RegressedRunDetector.arms(for: .stage1, floor: 300_000, acceptedThisBoot: true),
                       "AT the floor is still early (strictly greater, like the plateau minimum)")
        XCTAssertTrue(RegressedRunDetector.arms(for: .stage1, floor: 300_001, acceptedThisBoot: true))
        XCTAssertFalse(RegressedRunDetector.arms(for: .stage1, floor: 12_000, acceptedThisBoot: true),
                       "early-boot noise stays ignored")
    }

    func testStage1RegressedRunRequiresAnAcceptedCaptureThisBoot() {
        // The completion signal pulls window.__lastGood — acceptance this
        // boot is what proves the page holds a fresh post-floor snapshot.
        // A checkpoint-less recovery boot re-climbing toward a high floor
        // regresses from its first tick WITHOUT ever accepting: firing there
        // would pull an empty __lastGood and advance to stage 2 on a
        // half-copied Windows.
        XCTAssertFalse(RegressedRunDetector.arms(for: .stage1, floor: 400_000, acceptedThisBoot: false))
        XCTAssertTrue(RegressedRunDetector.arms(for: .stage1, floor: 400_000, acceptedThisBoot: true))
    }

    func testInterruptionClassificationPrefersTheRebootBoundary() {
        XCTAssertNil(StageInterruption.classify(rebootBoundary: false, death: false))
        XCTAssertEqual(StageInterruption.classify(rebootBoundary: false, death: true), .death)
        XCTAssertEqual(StageInterruption.classify(rebootBoundary: true, death: false), .guestReboot)
        // Run #3's signature: the stale re-climb panics mid-way ("Out of
        // bounds call_indirect" at 424,289, just shy of the 424,539 floor).
        // A death during/after a fired regressed run is the SAME boundary —
        // fresh-checkpoint reload, no recovery-budget draw, never both.
        XCTAssertEqual(StageInterruption.classify(rebootBoundary: true, death: true), .guestReboot)
    }

    func testGuestRebootReloadsTheStageWithoutBudgetDraw() {
        var flow = flowAtStage2()
        XCTAssertEqual(flow.guestRebooted(), .bootStage(.stage2, attempt: 1))
        XCTAssertEqual(flow.stage, .stage2)
        XCTAssertEqual(flow.recoveryBoots, 0, "reboot boundaries are EXPECTED, not deaths")
        XCTAssertEqual(flow.rebootBoundaries, 1)
    }

    func testGuestRebootsNeverExhaustAnyBudget() {
        // Win98 Setup legitimately reboots 2-3 times mid-phase-2/3, plus
        // panic flake — only the stage deadline bounds these, never a count.
        var flow = flowAtStage2()
        for n in 1...10 {
            XCTAssertEqual(flow.guestRebooted(), .bootStage(.stage2, attempt: 1))
            XCTAssertEqual(flow.rebootBoundaries, n)
        }
        XCTAssertEqual(flow.recoveryBoots, 0)
    }

    func testGuestRebootLeavesTheDeathBudgetUntouchedInBothDirections() {
        var flow = flowAtStage2()
        _ = flow.died(stage2Evidence: earlyCrashDeath)       // recovery 1
        flow.bootSucceeded()
        XCTAssertEqual(flow.guestRebooted(), .bootStage(.stage2, attempt: 1))
        XCTAssertEqual(flow.recoveryBoots, 1, "a boundary must not consume a recovery slot")
        flow.bootSucceeded()
        for n in 2...InstallFlow.maxRecoveryBoots {
            _ = flow.died(stage2Evidence: earlyCrashDeath)   // recovery n
            XCTAssertEqual(flow.recoveryBoots, n)
        }
        guard case .failed = flow.died(stage2Evidence: earlyCrashDeath) else {
            return XCTFail("boundaries must not REFILL the death budget either")
        }
    }

    func testStage3GuestRebootStaysInStage3() {
        var flow = flowAtStage2()
        _ = flow.died(stage2Evidence: finalizeShapedDeath)   // → stage 3 (expected)
        flow.bootSucceeded()
        XCTAssertEqual(flow.guestRebooted(), .bootStage(.stage3, attempt: 1))
        XCTAssertEqual(flow.stage, .stage3)
        XCTAssertEqual(flow.recoveryBoots, 0)
    }

    func testGuestRebootStartsAFreshBootEpisode() {
        var flow = flowAtStage2()
        _ = flow.bootFailed()                                // attempt 2 mid-episode
        _ = flow.guestRebooted()
        XCTAssertEqual(flow.bootFailed(), .bootStage(.stage2, attempt: 2),
                       "the boundary reload gets the full 3-attempt boot budget")
    }

    // MARK: - Stage-1 regressed run = phase-1 complete (device fix, run #4)

    func testRebootBoundaryResponseTable() {
        // A FIRED regressed run means different things per stage: stages 2/3
        // reload on the freshest checkpoint (run #3); stage 1's is phase-1's
        // completion warm reboot regressing against the post-switch stale
        // IndexedDB (run #4) — answered like the plateau, not like a reload.
        XCTAssertEqual(RebootBoundaryResponse.response(for: .stage1), .phase1Complete)
        XCTAssertEqual(RebootBoundaryResponse.response(for: .stage2), .reloadStage)
        XCTAssertEqual(RebootBoundaryResponse.response(for: .stage3), .reloadStage)
    }

    func testStage1RegressionCompletionEndsPhase1ExactlyLikeThePlateau() {
        // Both stage-1 ends converge on the SAME flow transition (stageEnded
        // → boot stage 2), so stage 2 cannot tell which signal fired — and
        // neither end draws budget or counts a boundary.
        var viaPlateau = InstallFlow()
        _ = viaPlateau.begin(); viaPlateau.bootSucceeded()
        XCTAssertEqual(viaPlateau.stageEnded(), .bootStage(.stage2, attempt: 1))

        var viaRegression = InstallFlow()
        _ = viaRegression.begin(); viaRegression.bootSucceeded()
        XCTAssertEqual(RebootBoundaryResponse.response(for: viaRegression.stage), .phase1Complete)
        XCTAssertEqual(viaRegression.stageEnded(), .bootStage(.stage2, attempt: 1))

        XCTAssertEqual(viaPlateau, viaRegression, "identical flow state either way")
        XCTAssertEqual(viaRegression.recoveryBoots, 0)
        XCTAssertEqual(viaRegression.rebootBoundaries, 0,
                       "the completion is a stage END, not a counted boundary")
    }

    func testStage1CompletionSignalsBothSurviveTheDetectorSemantics() {
        // The plateau path stays for the fresh-store case (e.g. the reboot
        // lands right after a recovery boot's re-seed): equal ticks above
        // 300k still fire it at stage 1's slow-cadence rule…
        var d = CapturePlateauDetector(plateauTicks: CaptureCadence.plateauTicks(for: .stage1),
                                       requireGrowth: CaptureCadence.requireGrowth(for: .stage1))
        XCTAssertEqual(d.ingest(344_979), .accepted)   // recovery checkpoint
        XCTAssertEqual(d.ingest(388_979), .accepted)   // copy finishes (grew → armed)
        XCTAssertEqual(d.ingest(388_979), .accepted)   // parked pass-2 writes nothing
        XCTAssertEqual(d.ingest(388_979), .plateau)    // 3 equal slow ticks ≈ 60 s
        // …while the stale-store case regresses instead and fires the
        // detector run (the floor keeps rejecting the remounted counts).
        var run = RegressedRunDetector()
        XCTAssertEqual(d.ingest(201_144), .rejected)   // remount re-read stale IndexedDB
        XCTAssertFalse(run.regressed())
        XCTAssertEqual(d.ingest(201_144), .rejected)
        XCTAssertTrue(run.regressed(), "two consecutive = the completion warm reboot")
        XCTAssertTrue(RegressedRunDetector.arms(for: .stage1, floor: 388_979,
                                                acceptedThisBoot: true))
    }

    // MARK: - Stage deadlines (device fix: stage 3 runs ScanDisk + a PnP re-pass)

    @MainActor
    func testStageDeadlineTable() {
        // The deadline doubles as the ONLY bound on unbudgeted reboot-
        // boundary reloads (runStages persists it across them), so these
        // numbers are load-bearing, not decoration.
        XCTAssertEqual(InstallOrchestrator.stageDeadline(.stage1), 45 * 60)
        XCTAssertEqual(InstallOrchestrator.stageDeadline(.stage2), 30 * 60)
        XCTAssertEqual(InstallOrchestrator.stageDeadline(.stage3), 25 * 60,
                       "12 min was Chrome-calibrated; device stage 3 runs ScanDisk "
                       + "passes and a PnP re-pass and needs the headroom")
    }

    // MARK: - Injected JS builders

    /// Builds stage 1's capture loop exactly as armCaptureLoop does.
    private func stage1CaptureLoopJS(floor: Int) -> String {
        InstallJS.captureLoop(
            targetBase: "pocketdos://app/lib/ABC/target-drive/drive", floor: floor,
            tickSeconds: CaptureCadence.tickSeconds(for: .stage1),
            liveReseed: CaptureCadence.liveReseed(for: .stage1),
            reseedSwitchCount: CaptureCadence.switchCount(for: .stage1),
            switchedTickSeconds: CaptureCadence.slowTickSeconds)
    }

    func testCaptureLoopJSStage1CarriesTheLoadBearingPieces() {
        let js = stage1CaptureLoopJS(floor: 123_456)
        XCTAssertTrue(js.contains("\"pocketdos://app/lib/ABC/target-drive/drive\""),
                      "the target base must be matched EXACTLY (two drives are mounted)")
        XCTAssertTrue(js.contains("var last = 123456;"),
                      "the monotonic floor must survive page reloads via Swift")
        XCTAssertTrue(js.contains("ci.persist(true)"))
        XCTAssertTrue(js.contains("if (live) { await window.pdosReseed"),
                      "stage 1's EARLY live re-seed is what makes early warm reboots free — "
                      + "and it must be gated so the switched tail stops paying for it")
        XCTAssertTrue(js.contains("[pdos-install] captured "))
        XCTAssertTrue(js.contains("[pdos-install] tick-ms "),
                      "every persist logs its serialize cost (device OOM forensics)")
    }

    func testCaptureLoopJSStage1IsTwoPhaseWithAnInPlaceSwitch() throws {
        // Device run #4: stage 1's tail OOM-cycled on per-tick serialize +
        // live re-seed at 120-148 MB. Below the 200k switch the loop keeps
        // the proven fast cadence; past it it must flip ITSELF (no Swift
        // round-trip) to the slow persist-only tick and say so once.
        let js = stage1CaptureLoopJS(floor: 123_456)
        XCTAssertTrue(js.contains("var live = true;"),
                      "floored below the switch → starts in the fast live-re-seed phase")
        XCTAssertTrue(js.contains("setInterval(tick, live ? 4500 : 20000)"),
                      "initial arm picks the phase the floor baked")
        XCTAssertTrue(js.contains("if (live && count >= 200000) { live = false;"),
                      "the switch fires in-place on the accepted count crossing 200k")
        XCTAssertTrue(js.contains("clearInterval(window.__pdosCapTimer); "
                                  + "window.__pdosCapTimer = setInterval(tick, 20000);"),
                      "the flip re-arms the SAME loop at the slow tick")
        XCTAssertTrue(js.contains("[pdos-install] cadence-switch"),
                      "one forensic breadcrumb marks the flip")
        // The crossing capture is re-seeded BEFORE the flip (the re-seed
        // line precedes the switch line), so IndexedDB's stale tail state
        // is the switch point, not one tick before it.
        let reseedAt = try XCTUnwrap(js.range(of: "await window.pdosReseed"))
        let switchAt = try XCTUnwrap(js.range(of: "if (live && count >= 200000)"))
        XCTAssertTrue(reseedAt.lowerBound < switchAt.lowerBound)
    }

    func testCaptureLoopJSStage1StartsSlowWhenFlooredPastTheSwitch() {
        // A recovery boot re-seeded from a post-switch checkpoint (or the
        // completion re-signal path) must not re-enter the fast phase: its
        // overlay is already Jetsam-sized. The baked `live` flag starts
        // false and the loop arms straight at the slow persist-only tick.
        let js = stage1CaptureLoopJS(floor: 344_979)
        XCTAssertTrue(js.contains("var live = false;"))
        XCTAssertTrue(js.contains("var last = 344979;"))
        XCTAssertTrue(js.contains("setInterval(tick, live ? 4500 : 20000)"))
        // Exactly AT the switch count also starts slow (strictly-below is
        // what bakes fast).
        XCTAssertTrue(stage1CaptureLoopJS(floor: 200_000).contains("var live = false;"))
        XCTAssertTrue(stage1CaptureLoopJS(floor: 199_999).contains("var live = true;"))
    }

    func testCaptureLoopJSStages2And3ArePersistOnlyAtTheSlowTick() {
        // THE device OOM fix: with stage 2's ~150 MB overlay, persist + live
        // IndexedDB re-seed every 4.5 s ≈ 300+ MB of transient allocation per
        // tick — Jetsam killed WebContent ~50-60 s after ci-ready on all
        // three recovery boots. Stages 2/3 persist every 20 s and hold
        // __lastGood in page memory only; boot boundaries re-seed the pulled
        // checkpoint explicitly (reseedAndGo), so nothing is lost.
        for stage in [InstallFlow.Stage.stage2, .stage3] {
            let js = InstallJS.captureLoop(
                targetBase: "pocketdos://app/lib/ABC/target-drive/drive", floor: 388_915,
                tickSeconds: CaptureCadence.tickSeconds(for: stage),
                liveReseed: CaptureCadence.liveReseed(for: stage),
                reseedSwitchCount: CaptureCadence.switchCount(for: stage),
                switchedTickSeconds: CaptureCadence.slowTickSeconds)
            XCTAssertFalse(js.contains("pdosReseed"),
                           "\(stage): NO per-tick re-seed — that copy is what OOM'd the phone")
            XCTAssertTrue(js.contains("window.__lastGood = bytes"),
                          "\(stage): the in-page checkpoint must still feed the pull channel")
            XCTAssertTrue(js.contains("var last = 388915;"))
            XCTAssertTrue(js.contains("ci.persist(true)"))
            XCTAssertTrue(js.contains("[pdos-install] captured "))
            XCTAssertTrue(js.contains("[pdos-install] tick-ms "))
            XCTAssertTrue(js.contains("setInterval(tick, 20000)"), "\(stage): 20s tick")
            XCTAssertFalse(js.contains("cadence-switch"),
                           "\(stage): single-phase — the two-phase machinery is stage 1's")
            XCTAssertFalse(js.contains("4500"), "\(stage): no fast tick anywhere")
        }
    }

    func testReseedAndGoJSFetchesCheckpointThenReleasesTheBoot() throws {
        let js = InstallJS.reseedAndGo(
            stageBinURL: "pocketdos://app/lib/ABC/stage.bin",
            targetBase: "pocketdos://app/lib/ABC/target-drive/drive")
        XCTAssertTrue(js.contains("\"pocketdos://app/lib/ABC/stage.bin\""))
        XCTAssertTrue(js.contains("pdosReseed"))
        XCTAssertTrue(js.contains("pdosInstallGo"))
        // The go call must be OUTSIDE the try: a failed fetch logs and boots
        // anyway (IndexedDB already holds the live-reseeded state).
        let goAt = try XCTUnwrap(js.range(of: "pdosInstallGo"))
        let catchAt = try XCTUnwrap(js.range(of: "catch"))
        XCTAssertTrue(goAt.lowerBound > catchAt.lowerBound)
    }

    func testQuotedEscapesHostileCharacters() {
        XCTAssertEqual(InstallJS.quoted(#"a"b\c"#), #""a\"b\\c""#)
        XCTAssertEqual(InstallJS.quoted("x\ny"), #""x\ny""#)
    }

    func testLogBreadcrumbJSWritesAnInstallPrefixedConsoleLine() {
        XCTAssertEqual(InstallJS.logBreadcrumb("script-cycle 3"),
                       #"console.log("[pdos-install] script-cycle 3");"#)
        // The native-emitted forensic tails round-trip through the console
        // bridge — they must stay INFORMATIONAL to the parser, never events.
        XCTAssertNil(InstallBreadcrumb.parse("log: [pdos-install] script-cycle 3"))
        XCTAssertNil(InstallBreadcrumb.parse("log: [pdos-install] desktop-probe flat"))
        XCTAssertNil(InstallBreadcrumb.parse("log: [pdos-install] desktop-probe grew"))
        XCTAssertNil(InstallBreadcrumb.parse("log: [pdos-install] reboot-boundary"))
        XCTAssertNil(InstallBreadcrumb.parse("log: [pdos-install] stage1-complete regressed-run"))
        XCTAssertNil(InstallBreadcrumb.parse("log: [pdos-install] stage1-complete pull-failed"))
    }

    // MARK: - Post-panic final flush (device fix, run #5)

    // Orchestrator sequencing note: flush-then-pull ordering is enforced in
    // InstallOrchestrator.finalFlushIfPanicked's call sites (the pull pins
    // whatever __lastGood holds at pdosCapPullBegin time, so the flush is
    // AWAITED first). That sequencing runs against a live WKWebView and is
    // not unit-testable here — the builder below is pinned exhaustively
    // instead, and the ordering is documented at every call site.

    /// Builds the flush exactly as finalFlushIfPanicked does.
    private func finalFlushJS(floor: Int = 424_609) -> String {
        InstallJS.finalFlush(targetBase: "pocketdos://app/lib/ABC/target-drive/drive",
                             floor: floor)
    }

    func testFinalFlushJSCarriesTheLoadBearingPieces() {
        // Device run #5: from the 424,60x checkpoint every boot re-ran the
        // same post-hardware-setup pass and panicked at its restart — the
        // continuation flags Windows wrote in its final seconds fell inside
        // the 20 s cadence gap, so every reseed booted the PRE-restart
        // state. The flush captures AT the panic instant: persist() serves
        // sockdrives entirely client-side (persistSockdrives runs FIRST, no
        // wasm round-trip), so a dead backend doesn't stop it.
        let js = finalFlushJS()
        XCTAssertTrue(js.contains("window.__pdosCi || window.ci"),
                      "js-dos may drop its own ci reference on backend exit — the "
                      + "page's ci-ready stash is the reference that survives the panic")
        XCTAssertTrue(js.contains("ci.persist(true)"))
        XCTAssertTrue(js.contains("\"pocketdos://app/lib/ABC/target-drive/drive\""),
                      "the target base must be matched EXACTLY, like the capture loop "
                      + "(two sockdrives are mounted — a positional grab could take the CAB source)")
        XCTAssertTrue(js.contains("(bytes[0] | (bytes[1] << 8) | (bytes[2] << 16) | (bytes[3] << 24)) >>> 0"),
                      "same u32le header read as the capture loop")
        XCTAssertTrue(js.contains("window.__lastGood = bytes"),
                      "the flushed blob must land where the pull channel (pdosCapPullBegin) reads")
        XCTAssertTrue(js.contains("[pdos-install] final-flush "))
        XCTAssertTrue(js.contains("[pdos-install] final-flush-failed"))
    }

    func testFinalFlushJSGuardsOnBothTheFloorAndTheHeldCheckpoint() {
        // >= on BOTH arms, on purpose: the final pre-restart flags often
        // rewrite the SAME sectors, so the record count may not grow at all
        // — the BYTES are what changed, and an equal-count flush must still
        // replace __lastGood. Anything below the boot's floor (e.g. a
        // post-remount stale re-climb's persist, when a panic ends a reboot
        // boundary) must leave it untouched.
        let js = finalFlushJS(floor: 424_609)
        XCTAssertTrue(js.contains("count >= 424609 && count >= heldCount"))
        XCTAssertTrue(js.contains("held.length >= 4"),
                      "a malformed held blob reads as count 0, never a crash")
        XCTAssertTrue(finalFlushJS(floor: -3).contains("count >= 0 && count >= heldCount"),
                      "a negative floor clamps to 0, like the capture loop's")
    }

    func testFinalFlushJSNeverThrowsIntoThePageAndStaysBounded() throws {
        // The flush runs over a page that just panicked, from a native
        // `try? await` — every path must RESOLVE (breadcrumb + return),
        // never throw, and the persist is raced against a timeout so the
        // native await stays bounded even if a strained page's persist
        // wedges.
        let js = finalFlushJS()
        XCTAssertTrue(js.hasPrefix("try {"),
                      "everything is guarded — the first statement included")
        XCTAssertTrue(js.contains("} catch (e) {"))
        XCTAssertTrue(js.contains("await Promise.race"))
        XCTAssertTrue(js.contains("persist timeout"))
        XCTAssertTrue(js.contains("15000"))
        XCTAssertFalse(js.hasPrefix("(function"),
                       "a callAsyncJavaScript body the orchestrator AWAITS before the "
                       + "pull, not a fire-and-forget IIFE")
        // The catch path still breadcrumbs the failure (forensics for the
        // pulled device log) and resolves — __lastGood untouched.
        let catchAt = try XCTUnwrap(js.range(of: "} catch (e) {"))
        let failLogAt = try XCTUnwrap(js.range(of: "final-flush-failed \" + (e"))
        XCTAssertTrue(failLogAt.lowerBound > catchAt.lowerBound)
    }

    func testFinalFlushBreadcrumbsAreInformationalToTheParser() {
        // Like script-cycle / desktop-probe lines: forensic only. They must
        // never parse into events — a "final-flush-failed persist timeout"
        // arriving mid-death-handling must not look like a capture or a
        // second panic to the run loop.
        XCTAssertNil(InstallBreadcrumb.parse("log: [pdos-install] final-flush 424609"))
        XCTAssertNil(InstallBreadcrumb.parse("log: [pdos-install] final-flush-failed no-ci"))
        XCTAssertNil(InstallBreadcrumb.parse("log: [pdos-install] final-flush-failed below-floor 424603"))
        XCTAssertNil(InstallBreadcrumb.parse("log: [pdos-install] final-flush-failed persist timeout"))
    }

    // MARK: - Stage-2 keystroke loop (device fix 2)

    func testSetupScriptCycleIsTheEnterChordEnterPattern() {
        // The timing-immune repeat-cycle: Enter advances pre-filled pages
        // (disabled Next no-ops), Alt+A then Enter clears License. Stray
        // extras are safe by design, so the SAME cycle fits every page.
        XCTAssertEqual(SetupScript.cycle, [
            .press(js: InstallJS.pressEnter), .wait(seconds: 8),
            .press(js: InstallJS.pressAltA), .wait(seconds: 1.5),
            .press(js: InstallJS.pressEnter), .wait(seconds: 8),
        ])
        XCTAssertEqual(InstallJS.pressEnter, "window.ci && window.ci.simulateKeyPress(257)")
        XCTAssertEqual(InstallJS.pressAltA, "window.ci && window.ci.simulateKeyPress(342, 65)")
        XCTAssertEqual(SetupScript.leadInSeconds, 30,
                       "halved from 60: cycles are idempotent so early keys are safe, "
                       + "and the run reaches evidence-producing work sooner")
        XCTAssertEqual(SetupScript.maxCycles, 12, "hard cap — the loop must not run forever")
    }

    func testSetupScriptExitConditionIsStrictCaptureGrowth() {
        // The loop exits on EVIDENCE, not time: captures must grow past
        // +3,000 sectors (strictly) over the loop-start baseline before the
        // script hands over to the unattended watcher.
        XCTAssertFalse(SetupScript.hasAdvanced(baseline: 388_979, latest: 388_979))
        XCTAssertFalse(SetupScript.hasAdvanced(baseline: 388_979, latest: 388_979 + 3_000))
        XCTAssertTrue(SetupScript.hasAdvanced(baseline: 388_979, latest: 388_979 + 3_001))
    }

    // MARK: - Stage-3 desktop probe (device fix 3)

    func testDesktopProbeCycleShape() {
        XCTAssertEqual(DesktopProbe.cycle, [
            .press(js: InstallJS.pressEnter), .wait(seconds: 2),
            .press(js: InstallJS.pressAltA), .wait(seconds: 1.5),
            .press(js: InstallJS.pressEnter),
        ])
        XCTAssertEqual(DesktopProbe.settleTicks, 2,
                       "≈ 40 s of settle at stage 3's 20 s capture cadence")
        XCTAssertEqual(DesktopProbe.maxProbes, 3)
    }

    func testDesktopProbeFlatConfirmsDesktopAndGrowthMeansWizard() {
        // The device run's failure shape: stage 3 plateaued at 401,690 on a
        // WAITING wizard page. A real desktop swallows the probe keys with
        // zero writes (flat); a wizard page advances and writes (grew).
        XCTAssertTrue(DesktopProbe.isFlat(baseline: 401_690, latest: 401_690),
                      "flat probe = desktop confirmed = done")
        XCTAssertFalse(DesktopProbe.isFlat(baseline: 401_690, latest: 401_691),
                       "ANY growth = the probe advanced a live page = keep watching")
    }

    // MARK: - Stage-3 growth-free plateau watch (device fix, run #6)

    func testStage3PlateauWatchesArmWithoutGrowthStages1And2KeepArming() {
        // Run #6: the final stage-3 boot landed on an already-CONVERGED
        // system (real desktop, Welcome tour up) and sat 20+ minutes to the
        // stage deadline. Idle-desktop writes (swap, registry flushes)
        // rewrite EXISTING sectors, so the unique-sector count never grew —
        // the growth-armed initial watch never fired and the desktop probe
        // never got to run. The probe is stage 3's real gate against a
        // false desktop (its keys make a waiting page write and GROW), so
        // growth arming added nothing there but the deadlock: every stage-3
        // watch — the initial arm included, not just the post-probe
        // re-arms — is now growth-free. Stages 1/2 keep the arming: their
        // idle boot ticks echo the re-seeded checkpoint and they have no
        // probe behind the plateau.
        XCTAssertFalse(CaptureCadence.requireGrowth(for: .stage3),
                       "stage 3's initial watch must match the post-probe re-arms")
        XCTAssertTrue(CaptureCadence.requireGrowth(for: .stage1))
        XCTAssertTrue(CaptureCadence.requireGrowth(for: .stage2))
    }

    func testStage3FlatAtFloorFromTickOneReachesThePlateau() {
        // The run-#6 deadlock shape, fixed: the boot re-seeds its checkpoint,
        // the capture loop floors at its count, and every persist reports
        // that SAME count (equal-at-floor is `captured` — the page's
        // monotonic guard accepts count >= floor; `capture-regressed` is
        // strictly below). Armed exactly as armCaptureLoop arms stage 3's
        // initial watch, three flat-at-floor ticks ARE the plateau — zero
        // growth ever required — and the desktop probe then decides.
        var d = CapturePlateauDetector(plateauTicks: CaptureCadence.plateauTicks(for: .stage3),
                                       requireGrowth: CaptureCadence.requireGrowth(for: .stage3))
        XCTAssertEqual(d.ingest(407_113), .accepted, "tick 1 = the floor echoed back")
        XCTAssertEqual(d.ingest(407_113), .accepted, "tick 2")
        XCTAssertEqual(d.ingest(407_113), .plateau, "tick 3 — plateau with no growth seen")
    }

    func testStage3EqualAtFloorIsAPlateauTickOnlyStrictlyBelowRejects() {
        // Equality vs regression stays STRICT: a count EQUAL to the floor
        // counts toward the plateau run, only strictly-below is a rejection
        // — and a rejection does not break the flat run (the same noise
        // rule the growth-armed detector always had).
        var d = CapturePlateauDetector(plateauTicks: CaptureCadence.plateauTicks(for: .stage3),
                                       requireGrowth: CaptureCadence.requireGrowth(for: .stage3))
        XCTAssertEqual(d.ingest(407_113), .accepted)
        XCTAssertEqual(d.ingest(407_112), .rejected, "below the floor = regression, never a flat tick")
        XCTAssertEqual(d.ingest(407_113), .accepted, "the run survives the reject: flat tick 2")
        XCTAssertEqual(d.ingest(407_113), .plateau, "flat tick 3")
    }

    func testStage2InitialWatchStillRequiresGrowthBeforePlateau() {
        // Stage 2 is UNCHANGED by the run-#6 fix — its exits are death /
        // boundary / script-growth, and its idle boot ticks (the re-seeded
        // checkpoint echoed back while Setup repaints its wizard) must
        // never read as settled writes.
        var d = CapturePlateauDetector(plateauTicks: CaptureCadence.plateauTicks(for: .stage2),
                                       requireGrowth: CaptureCadence.requireGrowth(for: .stage2))
        for _ in 0..<10 {
            XCTAssertEqual(d.ingest(388_979), .accepted, "flat-at-floor never plateaus in stage 2")
        }
        XCTAssertEqual(d.ingest(401_690), .accepted)   // real Setup work arms it, tick 1
        XCTAssertEqual(d.ingest(401_690), .accepted)   // tick 2
        XCTAssertEqual(d.ingest(401_690), .plateau)    // tick 3
    }

    // MARK: - Overlay header (capture-loop floor source)

    func testSockdriveOverlayRecordCountReadsU32LEHeader() {
        XCTAssertEqual(sockdriveOverlayRecordCount(Data([0x01, 0x02, 0x03, 0x04])),
                       0x04030201, "u32le at byte 0 — the capture loop's exact read")
        XCTAssertEqual(sockdriveOverlayRecordCount(Data([0x33, 0xEF, 0x05, 0x00, 0xFF])),
                       388_915, "trailing bytes are ignored")
        XCTAssertNil(sockdriveOverlayRecordCount(Data([0x01, 0x02, 0x03])),
                     "short headers are unreadable, not zero")
    }

    // MARK: - Final game shape (meta.json)

    private func makeTempFolder() throws -> URL {
        let dir = URL(fileURLWithPath: NSTemporaryDirectory())
            .appendingPathComponent("pdos-install-tests-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        addTeardownBlock { try? FileManager.default.removeItem(at: dir) }
        return dir
    }

    func testInstalledGameMetaShapeMatchesWriteGameMeta() throws {
        let base = try makeTempFolder()
        let folder = base.appendingPathComponent("GAME-ID", isDirectory: true)
        let driveDir = folder.appendingPathComponent("drive", isDirectory: true)
        try FileManager.default.createDirectory(at: driveDir, withIntermediateDirectories: true)
        let metaj = Data("{\"size\": 2147483648}".utf8)
        try metaj.write(to: driveDir.appendingPathComponent("sockdrive.metaj"))

        writeGameMeta(installedWin98Game(id: "GAME-ID", folderURL: folder))

        let data = try Data(contentsOf: folder.appendingPathComponent("meta.json"))
        let obj = try XCTUnwrap(JSONSerialization.jsonObject(with: data) as? [String: Any])
        XCTAssertEqual(obj["title"] as? String, "Windows 98")
        XCTAssertEqual(obj["controlProfile"] as? String, "mouse")
        XCTAssertEqual(obj["memoryMB"] as? Int, 64)
        XCTAssertEqual(obj["executables"] as? [String], [])
        XCTAssertEqual(obj["contentHash"] as? String,
                       sha256Hex(ofFileAt: driveDir.appendingPathComponent("sockdrive.metaj")),
                       "cross-device identity = SHA256 of the small deterministic metaj")
    }

    @MainActor
    func testInstalledGameLoadsBackAsAMouseSockdriveGame() throws {
        let base = try makeTempFolder()
        let id = UUID().uuidString
        let folder = base.appendingPathComponent(id, isDirectory: true)
        let driveDir = folder.appendingPathComponent("drive", isDirectory: true)
        try FileManager.default.createDirectory(at: driveDir, withIntermediateDirectories: true)
        try Data("meta".utf8).write(to: driveDir.appendingPathComponent("sockdrive.metaj"))
        writeGameMeta(installedWin98Game(id: id, folderURL: folder))

        let store = GameStore(gamesBaseURL: base)
        XCTAssertEqual(store.games.count, 1)
        let game = try XCTUnwrap(store.games.first)
        XCTAssertTrue(game.isSockdrive)
        XCTAssertEqual(game.title, "Windows 98")
        XCTAssertEqual(game.controlProfile, .mouse)
        XCTAssertEqual(game.memoryMB, 64)
        XCTAssertNil(game.sockdriveRestorablePath,
                     "no restore until the first in-game save writes sockdrive-write.bin")
    }
}
