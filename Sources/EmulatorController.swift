import Foundation
import WebKit

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

    func setPaused(_ paused: Bool) {
        isPaused = paused
        eval("window.props && window.props.setPaused(\(paused ? "true" : "false"))")
    }

    func togglePause() { setPaused(!isPaused) }

    func saveState() {
        eval("window.props && window.props.save && window.props.save()")
    }

    func restart() {
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
