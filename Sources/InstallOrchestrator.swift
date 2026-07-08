import Foundation
import Combine
import WebKit
import UIKit

/// One install failure, with whether a full re-run is worth offering. File-
/// scoped (not nested in the @MainActor orchestrator) so the off-main build
/// and finalize tasks can construct and throw it without actor hops.
struct InstallError: Error {
    let reason: String
    let retryable: Bool
}

/// Drives one complete Windows 98 install, end to end, against the app's ONE
/// shared WKWebView: media build → stage 1 (floppy boot, unattended file
/// copy) → stage 2 (boot C:, repeated keystroke cycles until the captures
/// show Setup advanced, unattended hardware setup, expected WASM death at
/// Windows' first shutdown — an EARLY death is a crash and re-runs the
/// stage) → stage 3 (recovery boot; each write plateau is probed with a
/// keystroke cycle and only a FLAT probe counts as the desktop) →
/// mouse-driver surgery + library registration.
///
/// The mechanics are the Chrome-proven runbook, made timing-immune after the
/// first device run (device Setup paints far slower than Chrome); the pure
/// decision pieces (breadcrumb grammar, plateau rule, stage/retry machine,
/// death classification, reboot-boundary detection, script/probe shapes)
/// live in InstallFlow.swift where they are unit-tested.
///
/// Device run #3 fix: in stages 2/3 a guest reboot the page SURVIVES
/// remounts stale boot-boundary IndexedDB (only boot boundaries re-seed
/// there — the OOM fix), so the floor rejects every capture while the guest
/// re-runs finished work. Two consecutive `capture-regressed` breadcrumbs
/// now trigger an immediate, unbudgeted stage reload on the freshest
/// `__lastGood` pulled from the still-alive page — no 5-minute silence
/// wait, no recovery-slot draw, no crash-prone stale re-climbs dirtying
/// the FAT.
///
/// Device run #4 fix: stage 1's TAIL was OOM-cycling on the same churn that
/// killed run #2's stage 2 (per-tick serialize + live IndexedDB re-seed of a
/// 120-148 MB overlay every 4.5 s). Its capture loop is now two-phase — the
/// injected JS itself flips to the slow persist-only cadence past 200k
/// accepted sectors ("cadence-switch") — which makes IndexedDB deliberately
/// stale in the tail, with two consequences wired here: (a) phase-1's
/// completion warm reboot now usually surfaces as a REGRESSED run instead of
/// a plateau, and stage 1 answers it exactly like the plateau (pull
/// `__lastGood` → stage.bin → stage 2); (b) a stage-1 mid-tail death can no
/// longer resume off IndexedDB alone, so stage-1 RECOVERY boots park behind
/// `pdosInstallGo` and re-seed the freshest pulled checkpoint first — the
/// same boot-boundary transport stages 2/3 always use.
///
/// Device run #5 fix: Windows' post-hardware-setup pass ends in ANOTHER
/// restart that deterministically panics this wasm, and the continuation
/// flags it writes in its final seconds fall inside the 20 s capture-cadence
/// gap — so every reseed booted the PRE-restart state and the pass repeated
/// (60-90 s of identical writes, count frozen at 424,609, then the panic)
/// until four identical deaths drained the budget. A [panic] kills the WASM
/// but not the PAGE, and sockdrive persist() is pure client-side JS: every
/// panic-classified interruption now runs a one-shot FINAL FLUSH
/// (InstallJS.finalFlush, off the page's `__pdosCi` ci-ready stash) that
/// re-persists the panic-instant state into `__lastGood` BEFORE the
/// checkpoint pull — capturing at the panic instant instead of ticking
/// faster. Process kills skip it naturally: the page is gone, the evaluate
/// throws, try? falls through to the pull's own failure fallback.
///
/// Device run #6 fix: stage 3's final boot REACHED the real desktop and then
/// sat 20+ minutes to the stage deadline — idle-desktop writes rewrite
/// EXISTING sectors, so the unique-sector count never grew and the
/// growth-armed initial plateau watch never armed, never fired, and never
/// let the desktop probe run. Stage 3's plateau watches (the initial arm
/// included) are now growth-free (CaptureCadence.requireGrowth): three
/// flat-at-floor ticks ARE the plateau, and the probe alone decides desktop
/// (flat) vs waiting page (grew). Stages 1/2 keep the growth arming — they
/// have no probe, and their idle boot ticks must not read as settled.
///
/// It observes the install page through the EXISTING console bridge — via the
/// additive `EmulatorController.onConsoleLine` hook — and through
/// `EmulatorController.loadError` (the Bridge reports engine panics and
/// WebContent process death there). It never creates a WebView: the wizard's
/// progress view hosts the shared one, keeping the app's single-WebContent-
/// process architecture intact.
@MainActor
final class InstallOrchestrator: ObservableObject {

    // MARK: - Public state

    enum State: Equatable {
        case idle
        case buildingMedia(percent: Int)
        case stage1FileCopy(captureCount: Int)
        /// `step` = keystroke cycles started so far (0 = lead-in before the
        /// first cycle, 1...maxCycles = that cycle running, maxCycles+1 =
        /// Setup advanced / unattended hardware setup running).
        case stage2Script(step: Int)
        /// Recovery boot through final capture pull.
        case stage3Finalizing
        /// FAT32 overlay surgery + game-folder assembly.
        case applyingMouseFix
        case done(gameId: String)
        case failed(reason: String, retryable: Bool)

        var isRunning: Bool {
            switch self {
            case .idle, .done, .failed: return false
            default: return true
            }
        }
    }

    @Published private(set) var state: State = .idle
    /// Wall-clock start of the current run (drives the elapsed readout).
    @Published private(set) var startedAt: Date?
    /// Latest accepted capture count (sectors written to the target so far).
    @Published private(set) var latestCaptureCount = 0

    // MARK: - Tunables (runbook timings, generous)

    // In-page persist cadence + re-seed policy are PER STAGE: CaptureCadence
    // (InstallFlow.swift) — stage 1 two-phase (4.5 s + live re-seed while the
    // overlay is small, in-page switch to 20 s persist-only past 200k
    // sectors — device run #4), stages 2/3 at 20 s persist-only always.
    static let bootTimeout: TimeInterval = 90    // load → ci-ready / waiting-for-go
    static let captureSilenceLimit: TimeInterval = 300   // persist silence = death
    /// Panic/crash events arriving this soon after a load() are the OLD page's
    /// dying gasps — dropping them keeps a stale panic from burning a fresh
    /// boot attempt. A genuinely instant panic still fails via the 90 s timeout.
    static let staleEventWindow: TimeInterval = 1.5
    /// Per-stage hard deadlines (safety net over the runbook's expectations
    /// of 15-25 min, ~13-17 min, and ~2-3 min in Chrome). Stage 3 gets 25 on
    /// device: dirty-boot ScanDisk passes and a PnP re-pass land there, and
    /// the old 12 was Chrome-calibrated. The clock deliberately SURVIVES
    /// reboot-boundary reloads (see runStages) — it is the ONLY bound on
    /// those, since they draw no budget.
    static func stageDeadline(_ stage: InstallFlow.Stage) -> TimeInterval {
        switch stage {
        case .stage1: return 45 * 60
        case .stage2: return 30 * 60
        case .stage3: return 25 * 60
        }
    }
    /// How long a stage-3 desktop probe waits for its settle ticks before
    /// comparing counts anyway (nominal is settleTicks × stage 3's 20 s
    /// cadence = 40 s; the in-page persist can stall far longer under load).
    static let probeSettleTimeout: TimeInterval = 90
    // Stage 2's keystroke cycles and stage 3's desktop probe are pure data:
    // SetupScript / DesktopProbe in InstallFlow.swift.

    // MARK: - Run wiring

    private enum InstallEvent: Equatable {
        case ciReady
        case waitingForGo
        case captured(count: Int, bytes: Int)
        case captureRegressed
        case panic(String)
        case processDied
        case cancelled
    }

    private var sharedEmulator: SharedEmulator?
    private var store: GameStore?
    private var gameId: String?
    private var gameFolder: URL?
    private var masterTask: Task<Void, Never>?
    private var loadErrorSink: AnyCancellable?

    // Event plumbing (all MainActor-confined).
    private var eventQueue: [InstallEvent] = []
    private var waiter: (id: Int, continuation: CheckedContinuation<InstallEvent?, Never>)?
    private var waiterSeq = 0

    // Per-phase observation flags (reset around each page load).
    private var ciReadySeen = false
    private var waitingForGoSeen = false
    private var deathSeen = false
    /// deathSeen's page-alive subset: a [panic] event (console breadcrumb or
    /// a non-__CRASH__ loadError) — the WASM died but the page and its JS
    /// heap survive, which is exactly the state the post-panic final flush
    /// (device run #5) can still persist from. A process kill sets deathSeen
    /// WITHOUT this.
    private var panicSeen = false
    private var plateauSeen = false
    /// A regressed run fired: the guest rebooted in-page (stages 2/3 only —
    /// RegressedRunDetector.arms). Once true it stays true until the reload.
    private var rebootBoundarySeen = false
    private var stageDetector = CapturePlateauDetector()
    private var regressedRun = RegressedRunDetector()
    /// The stage whose capture loop is armed — gates the regressed-run
    /// detector (stage 1's warm reboots continue in-page by design).
    private var currentStage: InstallFlow.Stage = .stage1
    private var lastCaptureAt = Date()
    private var lastLoadAt = Date.distantPast
    private var goAt = Date()
    /// Highest capture count ever accepted this run — seeds each injected
    /// capture loop's monotonic floor so a reloaded page can't re-seed a
    /// regressed (partial) persist over IndexedDB.
    private var captureHighWater = 0
    /// Highest count the page provably LIVE-re-seeded into IndexedDB (stage
    /// 1's fast phase only — the page logs `captured` AFTER awaiting the
    /// re-seed, so every accepted fast-phase capture is in the store). Past
    /// the cadence switch the high water runs AHEAD of IndexedDB, and a
    /// checkpoint-less stage-1 recovery flooring at the high water would
    /// reject every persist of the resumed copy (device run #4's fix): the
    /// floor must sit where the store actually is.
    private var lastLiveReseedCount = 0
    /// Swift mirror of the injected loop's `live` flag (stage 1's fast
    /// phase): true while accepted captures are still being re-seeded live.
    private var liveReseedActive = false
    /// The floor the CURRENT boot's capture loop was armed with. The final
    /// flush (device run #5) guards on this same number, so its acceptance
    /// rule is exactly the loop's own monotonic rule — NOT the run-global
    /// high water, which a stage-2 retry deliberately resumes below.
    private var currentCaptureFloor = 0

    deinit {
        masterTask?.cancel()
    }

    // MARK: - Entry points

    /// Kicks off a full install. `isoBookmark` is the wizard's security-scoped
    /// bookmark for the user's CD image; `productKey` stays in memory and
    /// flows ONLY into InstallMediaBuilder (which burns it into MSBATCH.INF on
    /// the generated D: source) — it is never logged or persisted here.
    func start(isoBookmark: Data, productKey: String, shared: SharedEmulator, store: GameStore) {
        guard masterTask == nil else { return }
        let id = UUID().uuidString
        sharedEmulator = shared
        self.store = store
        gameId = id
        gameFolder = store.gamesURL.appendingPathComponent(id, isDirectory: true)
        captureHighWater = 0
        lastLiveReseedCount = 0
        liveReseedActive = false
        latestCaptureCount = 0
        eventQueue.removeAll()
        startedAt = Date()
        state = .buildingMedia(percent: 0)
        masterTask = Task { await run(isoBookmark: isoBookmark, productKey: productKey) }
    }

    /// User cancel: stops the run at its next suspension point; the run's
    /// cancellation path tears the page down and deletes the partial folder.
    func cancel() {
        guard masterTask != nil else { return }
        masterTask?.cancel()
        post(.cancelled)
    }

    // MARK: - The run

    private func run(isoBookmark: Data, productKey: String) async {
        guard let shared = sharedEmulator, let store, let gameId, let gameFolder else { return }
        // A 30-60 minute unattended run must not die to the screen locking
        // (iOS suspends the app — and the WebContent timers — with it).
        UIApplication.shared.isIdleTimerDisabled = true
        attachHooks(shared)
        defer {
            UIApplication.shared.isIdleTimerDisabled = false
            detachHooks(shared)
            masterTask = nil
        }
        do {
            try await buildMedia(isoBookmark: isoBookmark, productKey: productKey, into: gameFolder)
            try await runStages(shared: shared, folder: gameFolder)
            try await finalize(store: store, gameId: gameId, folder: gameFolder, shared: shared)
            state = .done(gameId: gameId)
        } catch is CancellationError {
            shared.controller.teardown()
            try? FileManager.default.removeItem(at: gameFolder)
            state = .idle
        } catch let error as InstallError {
            shared.controller.teardown()
            // The partial folder is KEPT on failure (it's invisible to the
            // library and is the only forensic artifact of a long run); a
            // retried install starts fresh in a new folder.
            state = .failed(reason: error.reason, retryable: error.retryable)
        } catch {
            shared.controller.teardown()
            state = .failed(reason: error.localizedDescription, retryable: true)
        }
    }

    // MARK: - Console / crash observation

    private func attachHooks(_ shared: SharedEmulator) {
        // ADDITIVE console tap: the Bridge keeps all its existing handling and
        // additionally hands every line to this hook (see EmulatorWebView).
        // The Bridge delivers on the main thread (WKScriptMessageHandler), so
        // assumeIsolated is a formality, not a hop.
        shared.controller.onConsoleLine = { [weak self] line in
            MainActor.assumeIsolated {
                self?.handleConsoleLine(line)
            }
        }
        // Engine panics and WebContent process death surface as loadError
        // ("__CRASH__" for a dead process — see Bridge/webViewWebContentProcessDidTerminate).
        loadErrorSink = shared.controller.$loadError.sink { [weak self] error in
            guard let self, let error, !error.isEmpty else { return }
            Task { @MainActor in
                guard self.masterTask != nil else { return }
                guard Date().timeIntervalSince(self.lastLoadAt) > Self.staleEventWindow else { return }
                self.post(error.contains("__CRASH__") ? .processDied : .panic(error))
            }
        }
    }

    private func detachHooks(_ shared: SharedEmulator) {
        shared.controller.onConsoleLine = nil
        loadErrorSink?.cancel()
        loadErrorSink = nil
    }

    private func handleConsoleLine(_ line: String) {
        guard let crumb = InstallBreadcrumb.parse(line) else { return }
        switch crumb {
        case .captured(let count, let bytes):
            // Floor + silence clock update immediately (not at drain time), so
            // queue resets can't lose them and the watchdog sees arrivals even
            // while the run loop is sleeping through a script step.
            if count > captureHighWater { captureHighWater = count }
            lastCaptureAt = Date()
            post(.captured(count: count, bytes: bytes))
        case .ciReady:
            post(.ciReady)
        case .waitingForGo:
            post(.waitingForGo)
        case .panic(let text):
            guard Date().timeIntervalSince(lastLoadAt) > Self.staleEventWindow else { return }
            post(.panic(text))
        case .captureRegressed:
            // Same stale-gasp guard as panics: within the window the NEW
            // page's capture loop cannot be armed yet (that takes ci-ready),
            // so any regressed line this early is the OLD page flushing —
            // it must not seed the fresh boot's regressed-run counter.
            guard Date().timeIntervalSince(lastLoadAt) > Self.staleEventWindow else { return }
            post(.captureRegressed)   // the run loop counts consecutive ones
        }
    }

    // MARK: - Event queue

    private func post(_ event: InstallEvent) {
        if let w = waiter {
            waiter = nil
            w.continuation.resume(returning: event)
        } else {
            eventQueue.append(event)
        }
    }

    /// Next event, or nil after `timeout`. MainActor-confined; one waiter at
    /// a time (the run loop is the only consumer).
    private func awaitEvent(timeout: TimeInterval) async -> InstallEvent? {
        if !eventQueue.isEmpty { return eventQueue.removeFirst() }
        guard timeout > 0 else { return nil }
        waiterSeq += 1
        let id = waiterSeq
        return await withCheckedContinuation { continuation in
            waiter = (id, continuation)
            Task { [weak self] in
                try? await Task.sleep(nanoseconds: UInt64(timeout * 1_000_000_000))
                guard let self, let w = self.waiter, w.id == id else { return }
                self.waiter = nil
                w.continuation.resume(returning: nil)
            }
        }
    }

    private func apply(_ event: InstallEvent) {
        switch event {
        case .ciReady:
            ciReadySeen = true
        case .waitingForGo:
            waitingForGoSeen = true
        case .panic:
            deathSeen = true
            panicSeen = true   // page alive — the final flush can still run
        case .processDied:
            deathSeen = true   // page GONE — the flush must not be attempted
        case .captured(let count, _):
            regressedRun.accepted()
            if liveReseedActive {
                // Mirror of the page's fast phase: this capture was awaited
                // into IndexedDB before it was logged. The crossing capture
                // is re-seeded too, THEN the loop switches.
                lastLiveReseedCount = max(lastLiveReseedCount, count)
                if let cut = CaptureCadence.switchCount(for: currentStage), count >= cut {
                    liveReseedActive = false
                }
            }
            if stageDetector.ingest(count) == .plateau { plateauSeen = true }
            latestCaptureCount = count
            if case .stage1FileCopy = state { state = .stage1FileCopy(captureCount: count) }
        case .captureRegressed:
            // Device run #3: in stages 2/3 a surviving guest reboot remounts
            // stale boot-boundary IndexedDB, so the in-page floor rejects
            // every persist while the guest re-runs finished work. Two
            // consecutive rejections ARE that reboot. Device run #4: stage 1
            // arms too once the floor is past the file copy AND this boot
            // has accepted a capture (a fresh post-floor __lastGood provably
            // exists) — there the fired run is phase-1's completion warm
            // reboot regressing against the post-switch stale store.
            guard RegressedRunDetector.arms(for: currentStage,
                                            floor: captureHighWater,
                                            acceptedThisBoot: stageDetector.firstAccepted != nil)
            else { break }
            if regressedRun.regressed() { rebootBoundarySeen = true }
        case .cancelled:
            break   // the loops' Task.checkCancellation() throws right after
        }
    }

    /// The stop-early flags in classification priority: a death arriving
    /// during/after a fired regressed run is the SAME reboot boundary
    /// (StageInterruption.classify — pure, tested), never a second death.
    private var interruption: StageInterruption? {
        StageInterruption.classify(rebootBoundary: rebootBoundarySeen, death: deathSeen)
    }
    private var interrupted: Bool { interruption != nil }

    // MARK: - Media build

    private func buildMedia(isoBookmark: Data, productKey: String, into folder: URL) async throws {
        guard let template = InstallMediaBuilder.bundledBlankTargetTemplate else {
            throw InstallError(reason: "The app bundle is missing the blank-drive template.",
                               retryable: false)
        }
        let onPercent: @Sendable (Int) -> Void = { [weak self] p in
            Task { @MainActor in self?.noteBuildPercent(p) }
        }
        // The build streams a ~240 MB image — keep it off the main actor.
        try await Task.detached(priority: .userInitiated) {
            var stale = false
            guard let iso = try? URL(resolvingBookmarkData: isoBookmark, bookmarkDataIsStale: &stale) else {
                throw InstallError(reason: "Couldn't re-open the CD image. Pick it again in the wizard.",
                                   retryable: false)
            }
            let scoped = iso.startAccessingSecurityScopedResource()
            defer { if scoped { iso.stopAccessingSecurityScopedResource() } }
            do {
                try InstallMediaBuilder.build(isoAt: iso, productKey: productKey,
                                              into: folder, blankTargetTemplate: template) { progress in
                    switch progress {
                    case .floppyReady: onPercent(8)
                    case .buildingSource(let p): onPercent(8 + (p * 84) / 100)
                    case .chunking: onPercent(94)
                    case .done: onPercent(100)
                    }
                }
            } catch let error as InstallMediaBuilder.BuildError {
                throw InstallError(reason: error.localizedDescription, retryable: false)
            }
        }.value
        try Task.checkCancellation()
    }

    private func noteBuildPercent(_ percent: Int) {
        if case .buildingMedia(let old) = state, percent > old {
            state = .buildingMedia(percent: min(100, percent))
        }
    }

    // MARK: - URL plumbing (lib/<id>/… is served from Documents/Games/<id>/…)

    private func abs(_ rel: String) -> String {
        "\(BundleSchemeHandler.scheme)://\(BundleSchemeHandler.host)/\(rel)"
    }
    private func enc(_ s: String) -> String {
        s.addingPercentEncoding(withAllowedCharacters: .urlQueryAllowed) ?? s
    }
    /// The target base is ONE string used everywhere (imgmount base, persist
    /// match, IndexedDB db-name suffix, reseed key) — built once, no drift.
    private var targetBase: String { abs("lib/\(gameId ?? "")/target-drive/drive") }
    private var srcBase: String { abs("lib/\(gameId ?? "")/src-drive/drive") }
    private var floppyURLString: String { abs("lib/\(gameId ?? "")/boot-floppy.zip") }
    private var stageBinURLString: String { abs("lib/\(gameId ?? "")/stage.bin") }
    private func stageBinFileURL(_ folder: URL) -> URL { folder.appendingPathComponent("stage.bin") }

    /// `parked` adds &instwait=1 (the page parks the boot behind
    /// `pdosInstallGo` so a checkpoint can be re-seeded BEFORE the sockdrive
    /// mounts). Stages 2/3 always park; stage 1 parks on recovery boots only
    /// (the page's instwait handling is independent of instboot/instfloppy).
    private func stageURL(_ stage: InstallFlow.Stage, parked: Bool) -> URL {
        var q = "?insttarget=" + enc(targetBase) + "&instsrc=" + enc(srcBase)
        switch stage {
        case .stage1:
            q += "&instfloppy=" + enc(floppyURLString)
        case .stage2, .stage3:
            q += "&instboot=c"
        }
        if parked { q += "&instwait=1" }
        return URL(string: BundleSchemeHandler.startURL.absoluteString + q) ?? BundleSchemeHandler.startURL
    }

    // MARK: - Stages

    private func runStages(shared: SharedEmulator, folder: URL) async throws {
        // The install page drives its own persist transport; make sure the
        // controller's own persistence can't race it (no game is on screen,
        // but a hardware-keyboard F6 would otherwise persist install state
        // into the previous game's save file).
        shared.controller.prepareForNewGame()
        shared.controller.persistEnabled = false
        shared.controller.saveURL = nil

        var flow = InstallFlow()
        var next = flow.begin()
        // The stage-deadline CLOCK. (Re)started by budgeted transitions into
        // a stage (begin / stageEnded / died) and deliberately NOT by
        // reboot-boundary reloads or boot-attempt retries: reboot boundaries
        // are unbudgeted (Setup legitimately reboots 2-3 times mid-phase-2/3
        // — device run #3), so the persisted deadline is their only bound.
        var stageDeadlineAt = Date.distantFuture
        var restartStageClock = true
        while true {
            try Task.checkCancellation()
            switch next {
            case .failed(let why):
                throw InstallError(reason: why, retryable: true)
            case .finalizeReady:
                return
            case .bootStage(let stage, _):
                if restartStageClock {
                    stageDeadlineAt = Date().addingTimeInterval(Self.stageDeadline(stage))
                    restartStageClock = false
                }
                publishStageEntry(stage)
                let booted = try await bootStage(stage, shared: shared, folder: folder)
                guard booted else {
                    next = flow.bootFailed()   // boot retries keep the stage clock
                    continue
                }
                flow.bootSucceeded()
                armCaptureLoop(stage, shared: shared, floor: captureFloor(for: stage, folder: folder))
                if stage == .stage2 {
                    let interruptedDuringScript = try await runSetupScript(shared: shared)
                    if interruptedDuringScript {
                        // Best-effort checkpoint refresh either way (the
                        // .died arm below explains the failure semantics).
                        // A panic flushes the panic-instant state FIRST
                        // (run #5): the pull pins __lastGood, so the flush
                        // must be awaited before it.
                        await finalFlushIfPanicked(shared: shared)
                        try? await pullCapture(shared: shared, to: stageBinFileURL(folder))
                        if interruption == .guestReboot {
                            emitBreadcrumb("reboot-boundary", shared: shared)
                            next = flow.guestRebooted()
                        } else {
                            next = flow.died(stage2Evidence: stage2DeathEvidence())
                            restartStageClock = true
                        }
                        continue
                    }
                }
                let outcome: StageOutcome
                if stage == .stage3 {
                    outcome = try await watchStage3ToDesktop(shared: shared, until: stageDeadlineAt)
                } else {
                    outcome = try await watchStage(stage, until: stageDeadlineAt)
                }
                switch outcome {
                case .plateau:
                    if stage == .stage3 {
                        state = .stage3Finalizing
                        shared.webView.evaluateJavaScript(InstallJS.stopCaptureLoop, completionHandler: nil)
                        try await pullCapture(shared: shared, to: stageBinFileURL(folder))
                    } else {
                        try await pullCapture(shared: shared, to: stageBinFileURL(folder))
                    }
                    next = flow.stageEnded()
                    restartStageClock = true
                case .guestRebooted:
                    // Run #5: a boundary can be panic-ENDED (the stale
                    // re-climb panicking mid-way is run #3's signature, and
                    // classification priority folds that death into the
                    // boundary). The page is alive either way, so flush the
                    // panic-instant state into __lastGood BEFORE the pulls
                    // below; a pure (panic-free) boundary skips it — the
                    // loop's last accepted capture is already the freshest
                    // good state — and a stale post-remount persist is
                    // rejected by the flush's own floor guard.
                    await finalFlushIfPanicked(shared: shared)
                    switch RebootBoundaryResponse.response(for: stage) {
                    case .phase1Complete:
                        // Device run #4: with stage 1's two-phase loop,
                        // IndexedDB is stale past the cadence switch, so
                        // Setup's end-of-copy warm reboot into the one-shot
                        // park remounts BELOW the floor and REGRESSES where
                        // it used to plateau. The arming rule guaranteed
                        // this boot accepted a post-300k capture, so the
                        // still-alive page holds a fresh __lastGood: treat
                        // the fired run exactly like the plateau — pin +
                        // pull it as the stage checkpoint and move to
                        // stage 2. The pull moves ~150 MB over the bridge
                        // on a possibly strained page (run #3's residual),
                        // so unlike the plateau a failure here falls back
                        // to a budgeted stage-1 recovery — reboot on the
                        // last checkpoint, re-climb, re-signal — instead of
                        // failing the whole run.
                        emitBreadcrumb("stage1-complete regressed-run", shared: shared)
                        do {
                            try await pullCapture(shared: shared, to: stageBinFileURL(folder))
                            next = flow.stageEnded()
                        } catch let error where error is CancellationError {
                            throw error
                        } catch {
                            emitBreadcrumb("stage1-complete pull-failed", shared: shared)
                            next = flow.died()
                        }
                        restartStageClock = true
                    case .reloadStage:
                        // Device run #3 fix: the guest rebooted IN-PAGE.
                        // Stages 2/3 hold only the boot-boundary re-seed in
                        // IndexedDB, so the remount handed the guest STALE
                        // state — left alone it re-runs finished work for
                        // the floor to reject (5-minute silence stall) and
                        // panics mid-climb often enough to dirty the FAT.
                        // The page is still ALIVE and __lastGood holds the
                        // newest pre-reboot snapshot: pull it as the stage
                        // checkpoint NOW (a failed pull falls back to the
                        // last pulled checkpoint, exactly like the death
                        // path) and reload the stage — no watchdog wait, no
                        // recovery-budget draw, stage clock keeps running.
                        emitBreadcrumb("reboot-boundary", shared: shared)
                        try? await pullCapture(shared: shared, to: stageBinFileURL(folder))
                        next = flow.guestRebooted()
                    }
                case .died:
                    // Flush FIRST, pull SECOND (run #5 — the pull pins
                    // whatever __lastGood holds at pdosCapPullBegin time).
                    // After a [panic] the page still answers (only the WASM
                    // died): the flush re-persists the panic-instant state
                    // into __lastGood, catching the writes Windows made in
                    // its final seconds — without it they fall inside the
                    // capture-cadence gap and the reseed boots the
                    // PRE-restart state forever. After a process kill both
                    // throw and the previous checkpoint (the last
                    // successful pull into stage.bin) stands.
                    await finalFlushIfPanicked(shared: shared)
                    try? await pullCapture(shared: shared, to: stageBinFileURL(folder))
                    next = flow.died(
                        stage2Evidence: stage == .stage2 ? stage2DeathEvidence() : nil)
                    restartStageClock = true
                }
            }
        }
    }

    private func publishStageEntry(_ stage: InstallFlow.Stage) {
        switch stage {
        case .stage1: state = .stage1FileCopy(captureCount: latestCaptureCount)
        case .stage2: state = .stage2Script(step: 0)
        case .stage3: state = .stage3Finalizing
        }
    }

    /// Loads the stage's page and sees it through to ci-ready. Parked boots
    /// (stages 2/3 always; stage-1 RECOVERY boots, i.e. once a pulled
    /// checkpoint exists — device run #4: past the cadence switch IndexedDB
    /// is deliberately stale, so a resumed stage 1 must re-seed the pulled
    /// checkpoint before the sockdrive mounts, the same boot-boundary
    /// transport stages 2/3 use; the first boot has nothing to re-seed and
    /// boots plain off live-re-seeded IndexedDB): wait for the park
    /// breadcrumb, re-seed the checkpoint, release the boot, then wait for
    /// ci-ready. Returns false on a failed boot (timeout or death) — the
    /// flow's retry budget decides what happens next.
    private func bootStage(_ stage: InstallFlow.Stage, shared: SharedEmulator, folder: URL) async throws -> Bool {
        resetPhaseFlags()
        shared.controller.loadError = nil
        let parked = stage != .stage1
            || FileManager.default.fileExists(atPath: stageBinFileURL(folder).path)
        lastLoadAt = Date()
        shared.webView.load(URLRequest(url: stageURL(stage, parked: parked)))
        guard parked else {
            return try await waitBoot { self.ciReadySeen }
        }
        guard try await waitBoot({ self.waitingForGoSeen }) else { return false }
        goAt = Date()
        shared.webView.evaluateJavaScript(
            InstallJS.reseedAndGo(stageBinURL: stageBinURLString, targetBase: targetBase),
            completionHandler: nil)
        return try await waitBoot { self.ciReadySeen }
    }

    private func waitBoot(_ ready: @escaping () -> Bool) async throws -> Bool {
        let deadline = Date().addingTimeInterval(Self.bootTimeout)
        while Date() < deadline {
            try Task.checkCancellation()
            if ready() { return true }
            if deathSeen { return false }
            if let event = await awaitEvent(timeout: min(5, max(0.1, deadline.timeIntervalSinceNow))) {
                apply(event)
            }
        }
        return ready()
    }

    private func resetPhaseFlags() {
        ciReadySeen = false
        waitingForGoSeen = false
        deathSeen = false
        panicSeen = false
        plateauSeen = false
        rebootBoundarySeen = false
        regressedRun = RegressedRunDetector()
        eventQueue.removeAll()   // stale events die with the page they came from
    }

    /// Injects the stage's capture loop and re-arms the plateau detector at
    /// the stage's cadence (CaptureCadence: stage 1 = two-phase, 4.5 s +
    /// live re-seed until 200k sectors then an in-page switch to 20 s
    /// persist-only; stages 2/3 = 20 s persist-only always; plateau at
    /// 3 equal ticks ≈ 60 s at the slow cadence, the only one plateaus can
    /// fire at — their 300k minimum is past stage 1's switch). Growth arming
    /// is per stage too (CaptureCadence.requireGrowth — device run #6):
    /// stage 3's INITIAL watch must fire on flat-at-floor ticks, because a
    /// boot landing on an already-converged desktop never grows the count —
    /// the desktop probe, not growth, gates its plateaus. Stages 1/2 keep
    /// the arming (idle boot ticks echoing the re-seeded checkpoint must
    /// not read as settled).
    private func armCaptureLoop(_ stage: InstallFlow.Stage, shared: SharedEmulator, floor: Int) {
        currentStage = stage
        currentCaptureFloor = floor   // the final flush guards on the SAME floor
        stageDetector = CapturePlateauDetector(plateauTicks: CaptureCadence.plateauTicks(for: stage),
                                               requireGrowth: CaptureCadence.requireGrowth(for: stage))
        plateauSeen = false
        lastCaptureAt = Date()
        // Mirror the loop's baked `live` flag: a boot floored past the
        // switch starts slow/persist-only, so nothing new reaches IndexedDB
        // until the next boot boundary re-seed.
        liveReseedActive = CaptureCadence.liveReseed(for: stage)
            && (CaptureCadence.switchCount(for: stage).map { floor < $0 } ?? true)
        shared.webView.evaluateJavaScript(
            InstallJS.captureLoop(targetBase: targetBase, floor: floor,
                                  tickSeconds: CaptureCadence.tickSeconds(for: stage),
                                  liveReseed: CaptureCadence.liveReseed(for: stage),
                                  reseedSwitchCount: CaptureCadence.switchCount(for: stage),
                                  switchedTickSeconds: CaptureCadence.slowTickSeconds),
            completionHandler: nil)
    }

    /// The monotonic floor injected into this boot's capture loop: the record
    /// count of the checkpoint the page actually RESUMES from, NOT the run's
    /// global high water. A retry deliberately restores an OLDER state —
    /// flooring at the high water would make the page drop every persist as
    /// regressed (no accepted captures, no live re-seed, and a spurious
    /// silence death) until Setup re-crossed the stale mark.
    ///  - Any boot with a pulled checkpoint re-seeds stage.bin (stages 2/3
    ///    always; stage-1 recovery boots since device run #4) — floor at its
    ///    header count.
    ///  - A stage-1 boot WITHOUT a checkpoint resumes straight off
    ///    IndexedDB, which holds exactly the live-re-seeded state — floor at
    ///    the last count the page provably re-seeded (0 on the first boot).
    ///    Past the cadence switch the high water runs ahead of the store, so
    ///    flooring there would reject the whole resumed re-climb.
    ///  - Stages 2/3 with an unreadable stage.bin keep the conservative
    ///    high-water fallback (they never reach it in practice: every
    ///    transition into them pulls a checkpoint first).
    private func captureFloor(for stage: InstallFlow.Stage, folder: URL) -> Int {
        if let count = stageBinRecordCount(folder) { return count }
        return stage == .stage1 ? lastLiveReseedCount : captureHighWater
    }

    /// stage.bin's u32le record-count header, nil if absent/unreadable.
    private func stageBinRecordCount(_ folder: URL) -> Int? {
        guard let handle = try? FileHandle(forReadingFrom: stageBinFileURL(folder)) else {
            return nil
        }
        defer { try? handle.close() }
        guard let header = try? handle.read(upToCount: 4), header.count == 4 else { return nil }
        return sockdriveOverlayRecordCount(header)
    }

    /// What stage 2 actually did before dying — read at death time, fed to
    /// the flow's classifier. Runtime counts from the go release; growth
    /// counts from this boot's first accepted capture (which reports the
    /// re-seeded checkpoint's count, so growth is genuinely new work).
    private func stage2DeathEvidence() -> Stage2DeathEvidence {
        Stage2DeathEvidence(runtime: Date().timeIntervalSince(goAt),
                            captureGrowth: stageDetector.growthSinceFirstAccepted)
    }

    /// Stage 2's keystroke phase, timing-immune (the fixed-delay table died
    /// on device: Setup paints far slower there than in Chrome). After a
    /// quiet lead-in, keystroke cycles repeat — each safe wherever Setup
    /// happens to be — until the captures prove Setup advanced into its
    /// copy/hardware work, the cycle cap runs out, or the run is
    /// interrupted (death or reboot boundary). Returns true on interruption.
    private func runSetupScript(shared: SharedEmulator) async throws -> Bool {
        state = .stage2Script(step: 0)
        if try await drain(until: goAt.addingTimeInterval(SetupScript.leadInSeconds)) { return true }
        let baseline = captureHighWater
        for cycle in 1...SetupScript.maxCycles {
            state = .stage2Script(step: cycle)
            emitBreadcrumb("script-cycle \(cycle)", shared: shared)
            if try await perform(cycle: SetupScript.cycle, shared: shared) { return true }
            if SetupScript.hasAdvanced(baseline: baseline, latest: captureHighWater) { break }
        }
        state = .stage2Script(step: SetupScript.maxCycles + 1)   // unattended hardware setup
        return false
    }

    /// Interprets one keystroke cycle (SetupScript.cycle / DesktopProbe.cycle)
    /// Swift-side, draining events through the waits. True = interrupted
    /// (death or reboot boundary — the caller classifies via `interruption`).
    private func perform(cycle: [ScriptStep], shared: SharedEmulator) async throws -> Bool {
        for step in cycle {
            if interrupted { return true }
            switch step {
            case .press(let js):
                shared.webView.evaluateJavaScript(js, completionHandler: nil)
            case .wait(let seconds):
                if try await drain(until: Date().addingTimeInterval(seconds)) { return true }
            }
        }
        return interrupted
    }

    /// Drains install events until `deadline`. True = interrupted (early out).
    private func drain(until deadline: Date) async throws -> Bool {
        while Date() < deadline {
            try Task.checkCancellation()
            if interrupted { return true }
            if let event = await awaitEvent(timeout: max(0.1, deadline.timeIntervalSinceNow)) {
                apply(event)
            }
        }
        return interrupted
    }

    /// Waits for `ticks` accepted captures (nominally ticks × the stage's
    /// capture cadence — 20 s where this is used, stage 3), bounded by
    /// `probeSettleTimeout` in case the in-page persist stalls. True =
    /// interrupted.
    private func awaitCaptureTicks(_ ticks: Int) async throws -> Bool {
        let deadline = Date().addingTimeInterval(Self.probeSettleTimeout)
        var seen = 0
        while seen < ticks, Date() < deadline {
            try Task.checkCancellation()
            if interrupted { return true }
            if let event = await awaitEvent(timeout: max(0.1, deadline.timeIntervalSinceNow)) {
                if case .captured = event { seen += 1 }
                apply(event)
            }
        }
        return interrupted
    }

    /// Best-effort forensic breadcrumb INTO the page console, so native-
    /// driven moves (script cycles, probe verdicts) interleave with the
    /// page's own `captured` lines in one pullable log stream.
    private func emitBreadcrumb(_ tail: String, shared: SharedEmulator) {
        shared.webView.evaluateJavaScript(InstallJS.logBreadcrumb(tail), completionHandler: nil)
    }

    private enum StageOutcome { case plateau, guestRebooted, died }

    /// Maps the stop-early flags to a stage outcome once a helper reported
    /// "interrupted" (priority lives in StageInterruption.classify: a death
    /// during/after a fired regressed run is the same reboot boundary).
    private func interruptedOutcome() -> StageOutcome {
        interruption == .guestReboot ? .guestRebooted : .died
    }

    /// Supervises a booted stage until it settles, hits a reboot boundary,
    /// or dies. Stage 2 never ends by plateau (the runbook's end there is
    /// death or plateau-THEN-silence, and equal-count captures keep arriving
    /// during a plateau, so the 5-min silence watchdog is exactly the
    /// "then-silence" half — and the FALLBACK for a regressed run the
    /// detector somehow missed). The deadline is the caller's: it survives
    /// reboot-boundary reloads and stage 3's probe rounds alike.
    private func watchStage(_ stage: InstallFlow.Stage, until deadline: Date) async throws -> StageOutcome {
        lastCaptureAt = Date()
        while true {
            try Task.checkCancellation()
            if interrupted { return interruptedOutcome() }
            if plateauSeen && stage != .stage2 { return .plateau }
            if Date().timeIntervalSince(lastCaptureAt) > Self.captureSilenceLimit { return .died }
            if Date() > deadline { return .died }
            if let event = await awaitEvent(timeout: 30) { apply(event) }
        }
    }

    /// Stage 3's supervisor, device fix: a write plateau is no longer trusted
    /// as "desktop reached" — the device run plateaued on a WAITING wizard
    /// page and pulled a half-installed overlay. Each plateau is probed with
    /// one keystroke cycle, then the counts get `DesktopProbe.settleTicks`
    /// capture ticks to move: flat → the desktop really is idle → done;
    /// grew → a wizard page ate the keys and advanced → resume watching for
    /// the next plateau on the SAME stage deadline. At most
    /// `DesktopProbe.maxProbes` probes per boot; after that the next plateau
    /// is accepted (finalize's mouse-fix guard is the last backstop). Every
    /// stage-3 plateau watch — the INITIAL arm included — runs growth-free
    /// (device run #6: the final boot landed on an already-converged desktop
    /// whose idle writes rewrite existing sectors, so the count never grew,
    /// the growth-armed watch never fired, and the stage idled to its
    /// deadline with the probe never consulted; the probe is the gate
    /// against a false desktop, growth arming added nothing but the
    /// deadlock). The deadline is the caller's persisted stage clock — a
    /// reboot boundary (or a probe interrupted by one) surfaces as
    /// .guestRebooted and the reloaded boot re-enters here with a fresh
    /// probe budget.
    private func watchStage3ToDesktop(shared: SharedEmulator, until deadline: Date) async throws -> StageOutcome {
        var probes = 0
        while true {
            switch try await watchStage(.stage3, until: deadline) {
            case .died:
                return .died
            case .guestRebooted:
                return .guestRebooted
            case .plateau:
                guard probes < DesktopProbe.maxProbes else { return .plateau }
                probes += 1
                let baseline = captureHighWater
                if try await perform(cycle: DesktopProbe.cycle, shared: shared) { return interruptedOutcome() }
                if try await awaitCaptureTicks(DesktopProbe.settleTicks) { return interruptedOutcome() }
                if DesktopProbe.isFlat(baseline: baseline, latest: captureHighWater) {
                    emitBreadcrumb("desktop-probe flat", shared: shared)
                    return .plateau
                }
                emitBreadcrumb("desktop-probe grew", shared: shared)
                // The keys advanced a live wizard page. Re-arm the plateau
                // watch — growth-free like every stage-3 watch (run #6):
                // the page's write burst may finish inside the settle wait
                // we just spent, and the next plateau is probed (or
                // budget-trusted) anyway.
                stageDetector = CapturePlateauDetector(
                    plateauTicks: CaptureCadence.plateauTicks(for: .stage3),
                    requireGrowth: CaptureCadence.requireGrowth(for: .stage3))
                plateauSeen = false
            }
        }
    }

    // MARK: - Post-panic final flush (device run #5)

    /// Re-persists the target sockdrive INTO `__lastGood` at the panic
    /// instant, so the pull that follows retrieves the writes Windows made
    /// in its final seconds before the restart-that-panics (its
    /// continuation flags — inside the 20 s cadence gap otherwise, which is
    /// why every reseed used to boot the PRE-restart state and repeat the
    /// pass forever: run #5's wall at 424,60x). The sockdrive path of
    /// `ci.persist(true)` is pure client-side JS, so it works over the dead
    /// WASM; the in-JS floor + held-count guard means a failed or stale
    /// flush changes nothing.
    ///
    /// Runs on BOTH classifications of a panic — a reboot-boundary-priority
    /// panic and a plain death — because the page is alive in both and the
    /// flush strictly improves (or leaves) the checkpoint. It skips
    /// naturally everywhere else:
    ///  - process kill: `panicSeen` is false (and the page is gone anyway —
    ///    the evaluate would throw and `try?` falls through);
    ///  - capture silence / pure regressed runs: no panic, and the still-
    ///    live capture loop already holds the freshest good `__lastGood`.
    ///
    /// ORDERING (load-bearing, not unit-testable without a WebView — the
    /// call sites in runStages mirror this comment): the flush is AWAITED
    /// BEFORE pullCapture, because the pull pins whatever `__lastGood`
    /// holds at pdosCapPullBegin time. Flush-then-pull is the entire fix.
    private func finalFlushIfPanicked(shared: SharedEmulator) async {
        guard panicSeen else { return }
        _ = try? await shared.webView.callAsyncJavaScript(
            InstallJS.finalFlush(targetBase: targetBase, floor: currentCaptureFloor),
            arguments: [:], in: nil, contentWorld: .page)
    }

    // MARK: - Capture pull (mirrors the pdosPersistBegin/Chunk/End transport)

    /// Streams the page's held `__lastGood` capture to a file in base64
    /// chunks via callAsyncJavaScript — the same chunked shape
    /// EmulatorController.doPersist uses, because a single-string marshal of
    /// a ~150 MB blob hits the JS string-length wall.
    private func pullCapture(shared: SharedEmulator, to fileURL: URL) async throws {
        let webView = shared.webView
        let began = try await webView.callAsyncJavaScript(
            "return window.pdosCapPullBegin ? window.pdosCapPullBegin() : 0;",
            arguments: [:], in: nil, contentWorld: .page)
        let total = (began as? NSNumber)?.intValue ?? 0
        guard total >= 4 else {
            throw InstallError(reason: "No captured install state to checkpoint.", retryable: true)
        }
        let fm = FileManager.default
        let tmpURL = fileURL.appendingPathExtension("part")
        try? fm.removeItem(at: tmpURL)
        guard fm.createFile(atPath: tmpURL.path, contents: nil),
              let handle = try? FileHandle(forWritingTo: tmpURL) else {
            throw InstallError(reason: "Couldn't write the install checkpoint file.", retryable: true)
        }
        var offset = 0
        var streamed = true
        let chunkBytes = 8 * 1_048_576
        do {
            while offset < total {
                let len = min(chunkBytes, total - offset)
                let chunk = try await webView.callAsyncJavaScript(
                    "return window.pdosCapPullChunk(off, len);",
                    arguments: ["off": offset, "len": len], in: nil, contentWorld: .page)
                guard let b64 = chunk as? String, !b64.isEmpty,
                      let data = Data(base64Encoded: b64) else { streamed = false; break }
                try handle.write(contentsOf: data)
                offset += len
            }
            try handle.close()
        } catch {
            try? handle.close()
            streamed = false
        }
        _ = try? await webView.callAsyncJavaScript(
            "window.pdosCapPullEnd && window.pdosCapPullEnd(); return true;",
            arguments: [:], in: nil, contentWorld: .page)
        guard streamed, offset == total else {
            try? fm.removeItem(at: tmpURL)
            throw InstallError(reason: "The install checkpoint transfer broke mid-stream.", retryable: true)
        }
        if fm.fileExists(atPath: fileURL.path) {
            _ = try fm.replaceItemAt(fileURL, withItemAt: tmpURL)
        } else {
            try fm.moveItem(at: tmpURL, to: fileURL)
        }
    }

    // MARK: - Finalize (pure Swift, no emulator)

    /// stage.bin (the final captured overlay) + the blank-target chunks become
    /// the library game: mouse-fix surgery on the overlay (plus best-effort
    /// MSDOS.SYS AutoScan=0 — dirty-boot ScanDisk suppression), chunks moved to
    /// `drive/`, patched overlay written as `sockdrive-write.bin` (the S2
    /// restore path re-seeds it at every boot), GameStore-shaped meta.json,
    /// and every intermediate artifact deleted — nothing derived from the
    /// user's CD outlives the install except the installed machine itself.
    private func finalize(store: GameStore, gameId: String, folder: URL, shared: SharedEmulator) async throws {
        state = .applyingMouseFix
        shared.controller.teardown()   // free the install page; keep the ONE process
        guard let driverURL = Bundle.main.url(forResource: "dboxmpi", withExtension: "drv",
                                              subdirectory: "Web/install") else {
            throw InstallError(reason: "The app bundle is missing the mouse-integration driver.",
                               retryable: false)
        }
        let stageBin = stageBinFileURL(folder)
        try await Task.detached(priority: .userInitiated) {
            let fm = FileManager.default
            let overlay = try Data(contentsOf: stageBin)
            let chunksDir = folder.appendingPathComponent("target-drive/drive", isDirectory: true)
            do {
                let editor = try FAT32OverlayEditor(overlay: overlay, chunksDirectory: chunksDir)
                try editor.applyMouseFix(driver: try Data(contentsOf: driverURL))
                // Best-effort dirty-boot polish (device run #3): panic-
                // interrupted stage re-runs leave the FAT crash-consistent,
                // and Win98's next boot then parks on ScanDisk's prompt — a
                // stall on every unattended boot of the SHIPPED machine.
                // AutoScan=0 in MSDOS.SYS skips it. Unlike the mouse fix
                // this must NOT fail the install: an unexpected MSDOS.SYS
                // shape logs its breadcrumb and the machine ships as-is.
                do {
                    try editor.applyAutoScanOff()
                } catch {
                    print("[pdos-install] autoscan-skip \(error.localizedDescription)")
                }
                let driveDest = folder.appendingPathComponent("drive", isDirectory: true)
                try? fm.removeItem(at: driveDest)
                try fm.moveItem(at: chunksDir, to: driveDest)
                try editor.overlay.write(to: folder.appendingPathComponent("sockdrive-write.bin"),
                                         options: .atomic)
            } catch let error as FAT32OverlayEditor.EditorError {
                throw InstallError(reason: error.localizedDescription, retryable: true)
            }
            writeGameMeta(installedWin98Game(id: gameId, folderURL: folder))
            // Install-time media: the CAB source and boot floppy are derived
            // from the user's copyrighted CD — never kept past the install.
            try? fm.removeItem(at: folder.appendingPathComponent("src-drive"))
            try? fm.removeItem(at: folder.appendingPathComponent("target-drive"))
            try? fm.removeItem(at: folder.appendingPathComponent("boot-floppy.zip"))
            try? fm.removeItem(at: stageBin)
        }.value
        store.reload()
    }
}
