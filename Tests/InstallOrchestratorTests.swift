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
        // A stage 2/3 boot starts with the count already huge (the seeded
        // write store). Without the growth arming, the first four idle boot
        // ticks would read as "install finished".
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

    func testStage3DeathsRetryThenExhaustTheRecoveryBudget() {
        var flow = flowAtStage2()
        _ = flow.died(stage2Evidence: finalizeShapedDeath)   // → stage 3 (expected)
        flow.bootSucceeded()
        XCTAssertEqual(flow.died(), .bootStage(.stage3, attempt: 1))   // recovery 1
        XCTAssertEqual(flow.died(), .bootStage(.stage3, attempt: 1))   // recovery 2
        XCTAssertEqual(flow.died(), .bootStage(.stage3, attempt: 1))   // recovery 3
        guard case .failed = flow.died() else {
            return XCTFail("the fourth stage-3 death must fail the install")
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
        XCTAssertEqual(flow.died(stage2Evidence: earlyCrashDeath), .bootStage(.stage2, attempt: 1))
        XCTAssertEqual(flow.died(stage2Evidence: earlyCrashDeath), .bootStage(.stage2, attempt: 1))
        XCTAssertEqual(flow.died(stage2Evidence: earlyCrashDeath), .bootStage(.stage2, attempt: 1))
        guard case .failed = flow.died(stage2Evidence: earlyCrashDeath) else {
            return XCTFail("the fourth early stage-2 crash must fail the install")
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

    // MARK: - Injected JS builders

    func testCaptureLoopJSCarriesTheLoadBearingPieces() {
        let js = InstallJS.captureLoop(
            targetBase: "pocketdos://app/lib/ABC/target-drive/drive", floor: 123_456)
        XCTAssertTrue(js.contains("\"pocketdos://app/lib/ABC/target-drive/drive\""),
                      "the target base must be matched EXACTLY (two drives are mounted)")
        XCTAssertTrue(js.contains("var last = 123456;"),
                      "the monotonic floor must survive page reloads via Swift")
        XCTAssertTrue(js.contains("ci.persist(true)"))
        XCTAssertTrue(js.contains("pdosReseed"), "the LIVE re-seed is what makes reboots survive")
        XCTAssertTrue(js.contains("[pdos-install] captured "))
        XCTAssertTrue(js.contains("4500"), "the proven 4.5s capture cadence")
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
        XCTAssertEqual(SetupScript.leadInSeconds, 60)
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
        XCTAssertEqual(DesktopProbe.settleTicks, 3)
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
