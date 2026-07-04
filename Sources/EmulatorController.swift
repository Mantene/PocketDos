import Foundation
import WebKit
import UIKit

/// Bridges native in-game menu actions to the js-dos player running in the WebView,
/// and surfaces load failures / crashes back to SwiftUI.
///
/// Use on the main thread only (all callers — SwiftUI actions and WebKit delegate
/// callbacks — are already main-thread). evaluateJavaScript must run on main.
final class EmulatorController: ObservableObject {
    weak var webView: WKWebView?

    @Published var isPaused = false
    /// Non-nil when a bundle failed to load or the engine crashed; drives an alert.
    @Published var loadError: String?
    /// Transient status for a save/restore toast ("Saved", "Session restored", …).
    @Published var saveStatus: String?

    /// Destination for this game's filesystem-changes bundle (set at launch).
    var saveURL: URL?
    /// Called after a save is actually written (delta changed) — used to push to iCloud.
    var onPersisted: (() -> Void)?
    /// Whether persistence is attempted. Disabled for large disk-image games (Win9x
    /// qcow2): building the whole-FS delta via `ci.persist(true)` OOM-crashes the
    /// WebContent process, and the delta is too big to restore. Set per game at launch.
    var persistEnabled = true
    /// True for a sockdrive game. Persist still streams the same way, but the bytes are the
    /// serialized sector-diff (written to `sockdrive-write.bin`) and it BYPASSES the
    /// `maxRestoreBytes` cap: that cap exists because overlaying a big `changes.jsdos` doubles
    /// MEMFS at restore → OOM; a sockdrive re-seed streams into IndexedDB instead, so the
    /// doubling never happens. Set per game at launch.
    var isSockdrivePersist = false
    private var bgTask: UIBackgroundTaskIdentifier = .invalid
    /// A persist is in flight; further requests coalesce onto it (their completions
    /// run when it finishes) so overlapping triggers — periodic autosave, pause,
    /// background, quit — never race the atomic write or tear the WebView down mid-call.
    private var isPersisting = false
    /// Set when a persist is requested while one is already running, so a fresh
    /// snapshot is taken AFTER that request (the in-flight one predates its change).
    private var persistAgain = false
    private var pendingCompletions: [() -> Void] = []
    private var autosaveTimer: Timer?
    private var statusToken = 0
    /// Fingerprint (byte length + cheap content hash, computed page-side) of the last
    /// delta written, so an unchanged periodic autosave skips the (multi-MB, flash-
    /// wearing) disk rewrite while idle.
    private var lastSavedFingerprint: String?
    /// How often to checkpoint while playing. Durability never depends on the
    /// fragile background moment — worst case you lose this much progress.
    private let autosaveInterval: TimeInterval = 180

    func setPaused(_ paused: Bool) {
        isPaused = paused
        eval("window.props && window.props.setPaused(\(paused ? "true" : "false"))")
        // Pausing is a natural checkpoint (and the engine is stopped, so no hitch).
        if paused { persistNow() }
    }

    func togglePause() { setPaused(!isPaused) }

    /// Begin periodic checkpoint saves while a game is on screen. Bounds worst-case
    /// data loss to `autosaveInterval`, independent of background-suspension timing.
    func startAutosave() {
        guard persistEnabled else { return }   // large disk-image game runs ephemerally
        stopAutosave()
        autosaveTimer = Timer.scheduledTimer(withTimeInterval: autosaveInterval, repeats: true) { [weak self] _ in
            guard let self, !self.isPaused else { return }   // nothing changes while paused
            self.persistNow()
        }
    }

    func stopAutosave() {
        autosaveTimer?.invalidate()
        autosaveTimer = nil
    }

    /// Reset per-game state so the ONE shared controller can be re-pointed at a different
    /// game (the WebView/process is reused across launches — see SharedEmulator).
    func prepareForNewGame() {
        isPaused = false
        loadError = nil
        lastSavedFingerprint = nil
    }

    /// Free the heavy WASM page (emulated RAM + the mounted disk image — ~225 MB for
    /// Win98) when leaving gameplay, by tearing the DOCUMENT down. We navigate to a
    /// SAME-ORIGIN blank page (pocketdos://app/blank.html), NOT about:blank: once a real
    /// page has committed loads, about:blank's opaque origin makes WebKit treat the
    /// round-trip as cross-site and spin up a FRESH WebContent process per launch while
    /// the old one lingers (the app can't force-terminate it — no entitlement) holding
    /// its ~225 MB heap → the observed "Win98 boots twice, the third relaunch OOMs"
    /// pile-up. A same-scheme blank page hits WebKit's unconditional non-HTTP
    /// same-protocol no-swap path, so the ONE shared process is reused and its heap is
    /// reclaimed in place. `pdosTeardown` first asks js-dos to stop its worker so the
    /// heap is released promptly; the navigation is the hard guarantee.
    func teardown() {
        guard let webView else { return }
        webView.stopLoading()
        webView.evaluateJavaScript("window.pdosTeardown && window.pdosTeardown()", completionHandler: nil)
        if let blank = URL(string: "\(BundleSchemeHandler.scheme)://\(BundleSchemeHandler.host)/blank.html") {
            webView.load(URLRequest(url: blank))
        }
    }

    /// Surfaced by the web layer (via the console bridge) when a saved session is
    /// overlaid at launch — gives the user visible confirmation that restore worked.
    func noteRestored() { flashStatus("Session restored") }

    /// Show a transient status message, auto-clearing after a moment. Main-thread only.
    private func flashStatus(_ message: String) {
        statusToken += 1
        let token = statusToken
        saveStatus = message
        DispatchQueue.main.asyncAfter(deadline: .now() + 1.8) { [weak self] in
            guard let self, self.statusToken == token else { return }
            self.saveStatus = nil
        }
    }

    /// Pull the emulator's filesystem delta (base64) out of the web layer and
    /// write it atomically to `saveURL`. js-dos has no CPU/RAM snapshot, so this
    /// captures disk changes (in-game saves, an installed Win9x's HDD image, …)
    /// which are overlaid as `options.initFs` on the next launch.
    ///
    /// `isBackground` takes an OS background-task assertion so the async round-trip
    /// can finish after the app leaves the foreground. A null return (no changes
    /// yet, or engine not running) leaves any prior save untouched.
    func persistNow(isBackground: Bool = false, completion: (() -> Void)? = nil) {
        guard persistEnabled else {
            // Large disk-image game (Win9x): building the whole-FS delta via ci.persist
            // OOM-crashes the WebContent process, and the result is too big to restore.
            completion?(); return
        }
        guard webView != nil, saveURL != nil else {
            NSLog("[pdos] persist skipped — no webView/saveURL")
            completion?(); return
        }
        if let completion { pendingCompletions.append(completion) }
        if isBackground { beginBackgroundAssertion() }
        if isPersisting {
            // A request arrived mid-flight. Schedule ONE more fresh pass after the
            // current one so this caller's just-made change is captured, and its
            // completion fires only after that fresh snapshot is written.
            persistAgain = true
            return
        }
        runPersistPass()
    }

    private func runPersistPass() {
        guard let webView, let saveURL else {   // view torn down between passes
            isPersisting = false
            endBackgroundAssertion()
            drainCompletions()
            return
        }
        isPersisting = true
        // Capture webView + saveURL as STRONG locals for the Task's lifetime: the
        // emulator's filesystem write completes even if the view dismisses mid-call.
        Task { @MainActor in
            await self.doPersist(webView: webView, saveURL: saveURL)
            if self.persistAgain {
                self.persistAgain = false
                self.runPersistPass()           // fresh snapshot for late requests
                return
            }
            self.isPersisting = false
            self.endBackgroundAssertion()
            self.drainCompletions()
        }
    }

    @MainActor
    private func doPersist(webView: WKWebView, saveURL: URL) async {
        do {
            // Build the delta in the page and learn its size + fingerprint. It's pulled
            // out in base64 CHUNKS, not one string: a single base64 string of a large
            // (Win9x) delta hits a ~512MB JS-engine string-length limit (RAM-independent),
            // so it can't be marshalled whole. A length of 0 means nothing changed.
            let begin = try await webView.callAsyncJavaScript(
                "return await window.pdosPersistBegin();",
                arguments: [:], in: nil, contentWorld: .page)
            let info = begin as? [String: Any]
            let total = (info?["length"] as? NSNumber)?.intValue ?? 0
            guard total > 0 else {
                NSLog("[pdos] persist: no changes to save")
                await endPersist(webView)
                return
            }
            // A delta this large isn't an incremental save — it's a whole mounted disk
            // image (js-dos persists at file granularity, so any write to a Win9x qcow2
            // marks the whole image changed). Writing it bricks the next launch (restore
            // doubles memory → OOM), so skip it; and drop a stale over-cap save so it
            // stops wasting space. Incremental Win9x saves are the sockdrive plan.
            // A sockdrive write-set is a sector-diff re-seeded into IndexedDB (no MEMFS
            // doubling at restore), so it's exempt from the whole-FS cap below.
            if !isSockdrivePersist && total > Game.maxRestoreBytes {
                NSLog("[pdos] persist: delta \(total / 1_048_576) MB exceeds local cap — not saved (whole disk image; sockdrive will add incremental saves)")
                let attrs = try? FileManager.default.attributesOfItem(atPath: saveURL.path)
                if let existing = attrs?[.size] as? Int, existing > Game.maxRestoreBytes {
                    try? FileManager.default.removeItem(at: saveURL)
                }
                await endPersist(webView)
                return
            }
            // Unchanged since the last write → skip the flash-wearing rewrite.
            let fingerprint = info?["fp"] as? String
            if let fingerprint, fingerprint == lastSavedFingerprint {
                NSLog("[pdos] persist: delta unchanged since last save — skipping write")
                await endPersist(webView)
                return
            }
            // Stream base64 chunks → a temp file, then atomically publish the save. The
            // delta never exists whole as a native String or Data, so size is unbounded
            // by the string limit (RAM permitting on the engine side).
            let chunkBytes = 8 * 1_048_576
            let tmpURL = saveURL.appendingPathExtension("part")
            try? FileManager.default.removeItem(at: tmpURL)   // clear any crashed-run leftover
            guard FileManager.default.createFile(atPath: tmpURL.path, contents: nil),
                  let handle = try? FileHandle(forWritingTo: tmpURL) else {
                NSLog("[pdos] persist FAILED: can't open temp file")
                await endPersist(webView)
                flashStatus("Save failed")
                return
            }
            var offset = 0
            var streamed = true
            while offset < total {
                let len = min(chunkBytes, total - offset)
                let chunk = try await webView.callAsyncJavaScript(
                    "return window.pdosPersistChunk(off, len);",
                    arguments: ["off": offset, "len": len], in: nil, contentWorld: .page)
                guard let b64 = chunk as? String, !b64.isEmpty,
                      let data = Data(base64Encoded: b64) else { streamed = false; break }
                try handle.write(contentsOf: data)
                offset += len
            }
            try handle.close()          // a flush failure here routes to catch → discard partial
            await endPersist(webView)
            guard streamed, offset == total else {
                try? FileManager.default.removeItem(at: tmpURL)
                NSLog("[pdos] persist FAILED: chunk stream incomplete (\(offset)/\(total))")
                flashStatus("Save failed")
                return
            }
            if FileManager.default.fileExists(atPath: saveURL.path) {
                _ = try FileManager.default.replaceItemAt(saveURL, withItemAt: tmpURL)
            } else {
                try FileManager.default.moveItem(at: tmpURL, to: saveURL)
            }
            lastSavedFingerprint = fingerprint
            NSLog("[pdos] persist wrote \(total) bytes (chunked) -> \(saveURL.lastPathComponent)")
            flashStatus("Saved")
            onPersisted?()      // mirror the new save to iCloud (no-op if unavailable)
        } catch {
            // Release the page-side delta buffer AND the partial temp file on the error
            // path too — otherwise a multi-hundred-MB JS buffer + a `.part` file leak
            // until the next persist. The temp path is deterministic from saveURL.
            await endPersist(webView)
            try? FileManager.default.removeItem(at: saveURL.appendingPathExtension("part"))
            NSLog("[pdos] persist FAILED: \(error.localizedDescription)")
            flashStatus("Save failed")
        }
    }

    /// Release the page-side delta buffer captured by `pdosPersistBegin`.
    @MainActor
    private func endPersist(_ webView: WKWebView) async {
        _ = try? await webView.callAsyncJavaScript(
            "window.pdosPersistEnd(); return true;",
            arguments: [:], in: nil, contentWorld: .page)
    }

    private func drainCompletions() {
        let callbacks = pendingCompletions
        pendingCompletions = []
        callbacks.forEach { $0() }
    }

    private func beginBackgroundAssertion() {
        guard bgTask == .invalid else { return }
        bgTask = UIApplication.shared.beginBackgroundTask(withName: "pocketdos.persist") { [weak self] in
            self?.endBackgroundAssertion()
        }
    }

    private func endBackgroundAssertion() {
        guard bgTask != .invalid else { return }
        UIApplication.shared.endBackgroundTask(bgTask)
        bgTask = .invalid
    }

    func restart() {
        isPaused = false
        loadError = nil
        // Persist first, THEN reload — otherwise in-session disk changes (e.g. a
        // sound config just written by the game's SETUP/IMUSE utility) are lost,
        // because reload re-applies the previously-saved changes overlay.
        persistNow(isBackground: true) { [weak self] in
            self?.webView?.reload()
        }
    }

    /// Pure reload with no save — discards the current session and re-applies the
    /// last saved changes. Used by F7 quick-load.
    func reloadLastSave() {
        isPaused = false
        loadError = nil
        webView?.reload()
    }

    // MARK: - Key input (codes from js-dos src/window/dos/controls/keys.ts)

    /// Press a key down (hold). Pair with keyUp.
    func keyDown(_ code: Int) {
        eval("window.ci && window.ci.sendKeyEvent(\(code), true)")
    }

    /// Release a held key.
    func keyUp(_ code: Int) {
        eval("window.ci && window.ci.sendKeyEvent(\(code), false)")
    }

    /// Press and release a key (tap).
    func tapKey(_ code: Int) {
        eval("window.ci && window.ci.simulateKeyPress(\(code))")
    }

    /// Right-click at the current cursor position (button 1 in js-dos).
    /// (Left-click + cursor positioning is handled by js-dos's own absolute
    /// touch handling on the canvas when no overlay covers it.)
    func rightClick() {
        eval("(function(){var c=window.ci;if(c){c.sendMouseButton(1,true);"
           + "setTimeout(function(){c.sendMouseButton(1,false);},60);}})()")
    }

    // MARK: - Mouse (used by the game controller's cursor mapping)

    /// Hold/release a mouse button (0 = left, 1 = right).
    func mouseButton(_ index: Int, pressed: Bool) {
        eval("window.ci && window.ci.sendMouseButton(\(index), \(pressed ? "true" : "false"))")
    }

    /// Move the cursor by a relative delta (e.g. from a thumbstick).
    func mouseMoveRelative(dx: Int, dy: Int) {
        eval("(function(){var c=window.ci;if(c){c.sendMouseRelativeMotion(\(dx),\(dy));"
           + "c.sendMouseSync&&c.sendMouseSync();}})()")
    }

    /// Surfaced when a game controller connects — shows the transient toast.
    func noteControllerConnected() { flashStatus("Controller connected") }

    func reportError(_ raw: String) {
        // Called from WebKit delegate callbacks that may fire during a SwiftUI
        // view update; defer the @Published mutation to avoid "Publishing changes
        // from within view updates" undefined behavior.
        DispatchQueue.main.async { [weak self] in
            guard let self, self.loadError == nil else { return }
            self.loadError = raw
        }
    }

    private func eval(_ js: String) {
        webView?.evaluateJavaScript(js, completionHandler: nil)
    }
}

/// Turns a raw js-dos panic / crash string into a plain-English explanation.
func friendlyEmulatorError(_ raw: String) -> String {
    let lower = raw.lowercased()
    if lower.contains("dosbox.conf not found") || lower.contains("broken bundle") {
        return "This file isn't a js-dos game bundle (no dosbox.conf inside). "
             + "Import a .jsdos file — for example one exported from js-dos Studio."
    }
    if lower.contains("compression method not supported") {
        return "This archive uses a compression method the emulator can't read. "
             + "Repack it as a standard ZIP, or use a .jsdos bundle."
    }
    if lower.contains("__crash__") || lower.contains("out of memory") || lower.contains("terminated") {
        return "The game stopped unexpectedly — it may have run out of memory. "
             + "Heavy Windows 9x titles aren't supported in this build."
    }
    return "Something went wrong loading this game.\n\n\(raw)"
}
