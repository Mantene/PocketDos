import SwiftUI
import WebKit
import UIKit

/// Thin SwiftUI host for the app's ONE shared WKWebView (owned by `SharedEmulator`). It
/// re-parents that single WebView into a fresh container per presentation, so the same
/// WebView — and its single WebContent process — is reused across game launches. (iOS
/// won't reap a dismissed WebView's process for this app, so a per-game WebView leaked
/// un-killable ~400 MB processes; see SharedEmulator.) The `Bridge` + console bridge
/// live here but are instantiated and owned by `SharedEmulator`.
struct EmulatorWebView: UIViewRepresentable {
    let shared: SharedEmulator

    func makeUIView(context: Context) -> UIView {
        let container = UIView()
        container.backgroundColor = .black
        attach(shared.webView, to: container)
        return container
    }

    func updateUIView(_ container: UIView, context: Context) {
        if shared.webView.superview !== container { attach(shared.webView, to: container) }
    }

    /// Move the shared WebView into this presentation's container. It survives the old
    /// container's teardown because `SharedEmulator` holds it strongly; `removeFromSuperview`
    /// is a no-op when it's unparented.
    private func attach(_ webView: WKWebView, to container: UIView) {
        webView.removeFromSuperview()
        webView.frame = container.bounds
        webView.autoresizingMask = [.flexibleWidth, .flexibleHeight]
        container.addSubview(webView)
    }

    // NOTE: deliberately NOT named `Coordinator`. UIViewRepresentable resolves its
    // `associatedtype Coordinator` from a nested type of that name; if this were called
    // `Coordinator`, Swift would demand a `makeCoordinator()` we don't have (SharedEmulator
    // owns this object's lifecycle, SwiftUI does not). Naming it `Bridge` lets the
    // associated type default to `Void` and the synthesized `makeCoordinator()` apply.
    final class Bridge: NSObject, WKScriptMessageHandler, WKNavigationDelegate, WKUIDelegate {
        let emulator: EmulatorController?

        init(controller: EmulatorController?) {
            self.emulator = controller
            super.init()
        }

        func userContentController(_ userContentController: WKUserContentController,
                                   didReceive message: WKScriptMessage) {
            // Hardware-keyboard quick-save (F6) / quick-load (F7). Quick-load is a
            // reload: the start URL always carries &restore=, so it re-applies the
            // latest saved session.
            if message.name == "hotkey", let action = message.body as? String {
                switch action {
                case "quicksave": emulator?.persistNow()
                case "quickload": emulator?.reloadLastSave()
                default: break
                }
                return
            }
            guard message.name == "console" else { return }
            let text = "\(message.body)"
            print("[web] \(text)")

            // Additive tap for the install orchestrator's breadcrumb parsing —
            // everything below continues exactly as before.
            emulator?.onConsoleLine?(text)

            // The web layer logs this when it overlays a saved session at launch;
            // surface it natively so the user gets visible "restored" confirmation.
            if text.contains("[pdos-restore] restoring") {
                emulator?.noteRestored()
            }

            // Surface js-dos bundle-load failures as a native alert.
            let lower = text.lowercased()
            if lower.contains("[panic]")
                || lower.contains("broken bundle")
                || lower.contains("compression method not supported")
                || lower.contains("can't send bundles to backend") {
                emulator?.reportError(text)
            }
        }

        func webView(_ webView: WKWebView, didFailProvisionalNavigation navigation: WKNavigation!,
                     withError error: Error) {
            print("[web] navigation failed: \(error.localizedDescription)")
        }

        // Enforce the app's offline promise: the only top-level navigations allowed
        // are our own custom scheme (the harness + reloads). The vendored js-dos
        // runtime carries hardcoded remote endpoints (dos.zone / sockdrive); without
        // this gate a stray link would let the WebView reach the network. Subresource
        // fetches (wasm, blob: bundles, audio) are NOT navigations and are unaffected.
        func webView(_ webView: WKWebView,
                     decidePolicyFor navigationAction: WKNavigationAction,
                     decisionHandler: @escaping (WKNavigationActionPolicy) -> Void) {
            let scheme = navigationAction.request.url?.scheme?.lowercased()
            if scheme == BundleSchemeHandler.scheme || scheme == "about" {
                decisionHandler(.allow)
            } else {
                print("[web] blocked off-origin navigation: \(navigationAction.request.url?.absoluteString ?? "?")")
                decisionHandler(.cancel)
            }
        }

        // The WebContent process died (a black screen). For a heavy DOSBox-X /
        // Win9x machine this is almost always an out-of-memory Jetsam kill of the
        // WKWebView content process. Report it so the game view returns to the library.
        func webViewWebContentProcessDidTerminate(_ webView: WKWebView) {
            print("[web] ⚠️ WebContent process terminated — likely OUT OF MEMORY (Win9x/DOSBox-X heap exceeded the WKWebView limit).")
            emulator?.reportError("__CRASH__")
        }

        // WKWebView drops target="_blank" / window.open unless we handle it here.
        // js-dos's "Disk images (sockdrive)" quick-links are _blank anchors, so
        // without this they silently do nothing. We route .jsdos links back through
        // our harness loader (?url=) so js-dos actually loads the bundle; other
        // links load in place.
        func webView(_ webView: WKWebView,
                     createWebViewWith configuration: WKWebViewConfiguration,
                     for navigationAction: WKNavigationAction,
                     windowFeatures: WKWindowFeatures) -> WKWebView? {
            guard let url = navigationAction.request.url else { return nil }
            print("[web] intercepted _blank navigation: \(url.absoluteString)")
            // Only re-route SAME-ORIGIN (pocketdos://) .jsdos links back through the
            // harness loader. Anything else is off-origin: open it in the system
            // browser rather than inside our offline WebView (no in-app egress).
            if url.scheme?.lowercased() == BundleSchemeHandler.scheme {
                if url.absoluteString.contains(".jsdos") {
                    let encoded = url.absoluteString
                        .addingPercentEncoding(withAllowedCharacters: .urlQueryAllowed) ?? ""
                    if let harness = URL(string: BundleSchemeHandler.startURL.absoluteString + "?url=" + encoded) {
                        webView.load(URLRequest(url: harness))
                    }
                }
            } else {
                UIApplication.shared.open(url)
            }
            return nil
        }
    }

    static let consoleBridgeJS = """
    (function () {
      function post(level, args) {
        try {
          var parts = Array.prototype.slice.call(args).map(function (a) {
            try { return (typeof a === 'object') ? JSON.stringify(a) : String(a); }
            catch (e) { return String(a); }
          });
          window.webkit.messageHandlers.console.postMessage(level + ': ' + parts.join(' '));
        } catch (e) {}
      }
      ['log', 'info', 'warn', 'error', 'debug'].forEach(function (k) {
        var orig = console[k];
        console[k] = function () { post(k, arguments); if (orig) orig.apply(console, arguments); };
      });
      window.addEventListener('error', function (e) {
        post('error', [e.message + ' @ ' + e.filename + ':' + e.lineno]);
      });
      window.addEventListener('unhandledrejection', function (e) {
        post('error', ['unhandledrejection: ' + (e.reason && e.reason.message ? e.reason.message : e.reason)]);
      });
    })();
    """
}
