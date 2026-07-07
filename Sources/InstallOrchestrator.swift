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
/// death classification, script/probe shapes) live in InstallFlow.swift
/// where they are unit-tested.
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
    // (InstallFlow.swift) — stage 1 at the proven 4.5 s with live re-seed,
    // stages 2/3 at 20 s persist-only (the device OOM fix).
    static let bootTimeout: TimeInterval = 90    // load → ci-ready / waiting-for-go
    static let captureSilenceLimit: TimeInterval = 300   // persist silence = death
    /// Panic/crash events arriving this soon after a load() are the OLD page's
    /// dying gasps — dropping them keeps a stale panic from burning a fresh
    /// boot attempt. A genuinely instant panic still fails via the 90 s timeout.
    static let staleEventWindow: TimeInterval = 1.5
    /// Per-stage hard deadlines (safety net over the runbook's expectations of
    /// 15-25 min, ~13-17 min, and ~2-3 min respectively).
    static func stageDeadline(_ stage: InstallFlow.Stage) -> TimeInterval {
        switch stage {
        case .stage1: return 45 * 60
        case .stage2: return 30 * 60
        case .stage3: return 12 * 60
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
    private var plateauSeen = false
    private var stageDetector = CapturePlateauDetector()
    private var lastCaptureAt = Date()
    private var lastLoadAt = Date.distantPast
    private var goAt = Date()
    /// Highest capture count ever accepted this run — seeds each injected
    /// capture loop's monotonic floor so a reloaded page can't re-seed a
    /// regressed (partial) persist over IndexedDB.
    private var captureHighWater = 0

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
            break   // informational; the in-page guard already dropped it
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
        case .panic, .processDied:
            deathSeen = true
        case .captured(let count, _):
            if stageDetector.ingest(count) == .plateau { plateauSeen = true }
            latestCaptureCount = count
            if case .stage1FileCopy = state { state = .stage1FileCopy(captureCount: count) }
        case .cancelled:
            break   // the loops' Task.checkCancellation() throws right after
        }
    }

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

    private func stageURL(_ stage: InstallFlow.Stage) -> URL {
        var q = "?insttarget=" + enc(targetBase) + "&instsrc=" + enc(srcBase)
        switch stage {
        case .stage1:
            q += "&instfloppy=" + enc(floppyURLString)
        case .stage2, .stage3:
            q += "&instboot=c&instwait=1"
        }
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
        while true {
            try Task.checkCancellation()
            switch next {
            case .failed(let why):
                throw InstallError(reason: why, retryable: true)
            case .finalizeReady:
                return
            case .bootStage(let stage, _):
                publishStageEntry(stage)
                let booted = try await bootStage(stage, shared: shared)
                guard booted else {
                    next = flow.bootFailed()
                    continue
                }
                flow.bootSucceeded()
                armCaptureLoop(stage, shared: shared, floor: captureFloor(for: stage, folder: folder))
                if stage == .stage2 {
                    let diedDuringScript = try await runSetupScript(shared: shared)
                    if diedDuringScript {
                        try? await pullCapture(shared: shared, to: stageBinFileURL(folder))
                        next = flow.died(stage2Evidence: stage2DeathEvidence())
                        continue
                    }
                }
                let outcome: StageOutcome
                if stage == .stage3 {
                    outcome = try await watchStage3ToDesktop(shared: shared)
                } else {
                    outcome = try await watchStage(
                        stage, until: Date().addingTimeInterval(Self.stageDeadline(stage)))
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
                case .died:
                    // Best-effort checkpoint refresh: after a [panic] the page
                    // usually still answers (only the WASM died), and its
                    // __lastGood is at most one capture tick old. After a
                    // process kill this throws and the previous checkpoint
                    // (the last successful pull into stage.bin) stands.
                    try? await pullCapture(shared: shared, to: stageBinFileURL(folder))
                    next = flow.died(
                        stage2Evidence: stage == .stage2 ? stage2DeathEvidence() : nil)
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

    /// Loads the stage's page and sees it through to ci-ready. Stage 2/3 park
    /// behind `pdosInstallGo` (instwait=1): wait for the park breadcrumb,
    /// re-seed the checkpoint, release the boot, then wait for ci-ready.
    /// Returns false on a failed boot (timeout or death) — the flow's retry
    /// budget decides what happens next.
    private func bootStage(_ stage: InstallFlow.Stage, shared: SharedEmulator) async throws -> Bool {
        resetPhaseFlags()
        shared.controller.loadError = nil
        lastLoadAt = Date()
        shared.webView.load(URLRequest(url: stageURL(stage)))
        switch stage {
        case .stage1:
            return try await waitBoot { self.ciReadySeen }
        case .stage2, .stage3:
            guard try await waitBoot({ self.waitingForGoSeen }) else { return false }
            goAt = Date()
            shared.webView.evaluateJavaScript(
                InstallJS.reseedAndGo(stageBinURL: stageBinURLString, targetBase: targetBase),
                completionHandler: nil)
            return try await waitBoot { self.ciReadySeen }
        }
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
        plateauSeen = false
        eventQueue.removeAll()   // stale events die with the page they came from
    }

    /// Injects the stage's capture loop and re-arms the plateau detector at
    /// the stage's cadence (CaptureCadence: stage 1 = 4.5 s + live re-seed,
    /// stages 2/3 = 20 s persist-only with plateau at 3 equal ticks ≈ 60 s).
    private func armCaptureLoop(_ stage: InstallFlow.Stage, shared: SharedEmulator, floor: Int) {
        stageDetector = CapturePlateauDetector(plateauTicks: CaptureCadence.plateauTicks(for: stage))
        plateauSeen = false
        lastCaptureAt = Date()
        shared.webView.evaluateJavaScript(
            InstallJS.captureLoop(targetBase: targetBase, floor: floor,
                                  tickSeconds: CaptureCadence.tickSeconds(for: stage),
                                  liveReseed: CaptureCadence.liveReseed(for: stage)),
            completionHandler: nil)
    }

    /// The monotonic floor injected into this boot's capture loop: the record
    /// count of the checkpoint the page just re-seeded (stage 2/3 boots read
    /// it straight off stage.bin's header), NOT the run's global high water.
    /// A stage-2 retry deliberately restores an OLDER checkpoint — flooring
    /// at the high water would make the page drop every persist as regressed
    /// (no accepted captures, no live re-seed, and a spurious silence death)
    /// until Setup re-crossed the stale mark. Stage 1 has no checkpoint yet;
    /// unreadable headers fall back to the conservative high water.
    private func captureFloor(for stage: InstallFlow.Stage, folder: URL) -> Int {
        guard stage != .stage1 else { return captureHighWater }
        guard let handle = try? FileHandle(forReadingFrom: stageBinFileURL(folder)) else {
            return captureHighWater
        }
        defer { try? handle.close() }
        guard let header = try? handle.read(upToCount: 4), header.count == 4,
              let count = sockdriveOverlayRecordCount(header) else {
            return captureHighWater
        }
        return count
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
    /// copy/hardware work, the cycle cap runs out, or the engine dies.
    /// Returns true if the engine died mid-script.
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
    /// Swift-side, draining events through the waits. True = death seen.
    private func perform(cycle: [ScriptStep], shared: SharedEmulator) async throws -> Bool {
        for step in cycle {
            if deathSeen { return true }
            switch step {
            case .press(let js):
                shared.webView.evaluateJavaScript(js, completionHandler: nil)
            case .wait(let seconds):
                if try await drain(until: Date().addingTimeInterval(seconds)) { return true }
            }
        }
        return deathSeen
    }

    /// Drains install events until `deadline`. True = death seen (early out).
    private func drain(until deadline: Date) async throws -> Bool {
        while Date() < deadline {
            try Task.checkCancellation()
            if deathSeen { return true }
            if let event = await awaitEvent(timeout: max(0.1, deadline.timeIntervalSinceNow)) {
                apply(event)
            }
        }
        return deathSeen
    }

    /// Waits for `ticks` accepted captures (nominally ticks × the stage's
    /// capture cadence — 20 s where this is used, stage 3), bounded by
    /// `probeSettleTimeout` in case the in-page persist stalls. True =
    /// death seen.
    private func awaitCaptureTicks(_ ticks: Int) async throws -> Bool {
        let deadline = Date().addingTimeInterval(Self.probeSettleTimeout)
        var seen = 0
        while seen < ticks, Date() < deadline {
            try Task.checkCancellation()
            if deathSeen { return true }
            if let event = await awaitEvent(timeout: max(0.1, deadline.timeIntervalSinceNow)) {
                if case .captured = event { seen += 1 }
                apply(event)
            }
        }
        return deathSeen
    }

    /// Best-effort forensic breadcrumb INTO the page console, so native-
    /// driven moves (script cycles, probe verdicts) interleave with the
    /// page's own `captured` lines in one pullable log stream.
    private func emitBreadcrumb(_ tail: String, shared: SharedEmulator) {
        shared.webView.evaluateJavaScript(InstallJS.logBreadcrumb(tail), completionHandler: nil)
    }

    private enum StageOutcome { case plateau, died }

    /// Supervises a booted stage until it settles or dies. Stage 2 never ends
    /// by plateau (the runbook's end there is death or plateau-THEN-silence,
    /// and equal-count captures keep arriving during a plateau, so the 5-min
    /// silence watchdog is exactly the "then-silence" half). The deadline is
    /// the caller's so stage 3's probe loop can resume watching WITHOUT
    /// restarting the stage clock.
    private func watchStage(_ stage: InstallFlow.Stage, until deadline: Date) async throws -> StageOutcome {
        lastCaptureAt = Date()
        while true {
            try Task.checkCancellation()
            if deathSeen { return .died }
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
    /// is accepted (finalize's mouse-fix guard is the last backstop).
    private func watchStage3ToDesktop(shared: SharedEmulator) async throws -> StageOutcome {
        let deadline = Date().addingTimeInterval(Self.stageDeadline(.stage3))
        var probes = 0
        while true {
            switch try await watchStage(.stage3, until: deadline) {
            case .died:
                return .died
            case .plateau:
                guard probes < DesktopProbe.maxProbes else { return .plateau }
                probes += 1
                let baseline = captureHighWater
                if try await perform(cycle: DesktopProbe.cycle, shared: shared) { return .died }
                if try await awaitCaptureTicks(DesktopProbe.settleTicks) { return .died }
                if DesktopProbe.isFlat(baseline: baseline, latest: captureHighWater) {
                    emitBreadcrumb("desktop-probe flat", shared: shared)
                    return .plateau
                }
                emitBreadcrumb("desktop-probe grew", shared: shared)
                // The keys advanced a live wizard page. Re-arm the plateau
                // watch WITHOUT the growth requirement: the page's write
                // burst may finish inside the settle wait we just spent, and
                // the next plateau is probed (or budget-trusted) anyway.
                stageDetector = CapturePlateauDetector(
                    plateauTicks: CaptureCadence.plateauTicks(for: .stage3), requireGrowth: false)
                plateauSeen = false
            }
        }
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
    /// the library game: mouse-fix surgery on the overlay, chunks moved to
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
