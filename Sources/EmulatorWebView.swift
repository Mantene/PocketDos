import SwiftUI
import WebKit

/// Hosts the js-dos player in a WKWebView whose assets are served from the app
/// bundle via `BundleSchemeHandler`. Forwards JS `console.*` and uncaught errors
/// to Xcode's console (prefixed `[web]`) so the spike is debuggable on device.
struct EmulatorWebView: UIViewRepresentable {

    /// Same-origin relative path of the game to load (e.g. "lib/<id>/game.jsdos").
    /// nil → show the bare js-dos loader (used by the spike / fallback).
    var gameRelativeURL: String? = nil
    var runCommand: String? = nil
    var memoryMB: Int? = nil
    var controller: EmulatorController? = nil

    func makeCoordinator() -> Coordinator { Coordinator(controller: controller) }

    /// Start URL: the harness, optionally with ?url=<game> (and &run=<cmd> for zips)
    /// so it autostarts a bundle. The game URL is absolute and same-origin
    /// (pocketdos://app/lib/...) so js-dos can fetch it without a cross-origin barrier.
    private var startURL: URL {
        guard let rel = gameRelativeURL, !rel.isEmpty else { return BundleSchemeHandler.startURL }
        let absolute = "\(BundleSchemeHandler.scheme)://\(BundleSchemeHandler.host)/\(rel)"
        var query = "?url=" + (absolute.addingPercentEncoding(withAllowedCharacters: .urlQueryAllowed) ?? absolute)
        if let runCommand, !runCommand.isEmpty {
            query += "&run=" + (runCommand.addingPercentEncoding(withAllowedCharacters: .urlQueryAllowed) ?? runCommand)
        }
        if let memoryMB {
            query += "&mem=\(memoryMB)"
        }
        return URL(string: BundleSchemeHandler.startURL.absoluteString + query)
            ?? BundleSchemeHandler.startURL
    }

    func makeUIView(context: Context) -> WKWebView {
        let config = WKWebViewConfiguration()
        config.setURLSchemeHandler(BundleSchemeHandler(), forURLScheme: BundleSchemeHandler.scheme)
        config.allowsInlineMediaPlayback = true
        config.mediaTypesRequiringUserActionForPlayback = []

        // Bridge console.log / errors -> native, injected before any page script.
        let controller = config.userContentController
        controller.add(context.coordinator, name: "console")
        controller.addUserScript(WKUserScript(
            source: Self.consoleBridgeJS,
            injectionTime: .atDocumentStart,
            forMainFrameOnly: false
        ))

        let webView = WKWebView(frame: .zero, configuration: config)
        webView.isInspectable = true              // enable Safari Web Inspector (iOS 16.4+)
        webView.scrollView.isScrollEnabled = false
        webView.scrollView.contentInsetAdjustmentBehavior = .never
        webView.backgroundColor = .black
        webView.isOpaque = false
        webView.navigationDelegate = context.coordinator
        webView.uiDelegate = context.coordinator   // catch target="_blank" / window.open

        self.controller?.webView = webView
        webView.load(URLRequest(url: startURL))
        return webView
    }

    func updateUIView(_ uiView: WKWebView, context: Context) {}

    final class Coordinator: NSObject, WKScriptMessageHandler, WKNavigationDelegate, WKUIDelegate {
        let emulator: EmulatorController?

        init(controller: EmulatorController?) {
            self.emulator = controller
            super.init()
        }

        func userContentController(_ userContentController: WKUserContentController,
                                   didReceive message: WKScriptMessage) {
            guard message.name == "console" else { return }
            let text = "\(message.body)"
            print("[web] \(text)")

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
            if url.absoluteString.contains(".jsdos") {
                let encoded = url.absoluteString
                    .addingPercentEncoding(withAllowedCharacters: .urlQueryAllowed) ?? ""
                if let harness = URL(string: BundleSchemeHandler.startURL.absoluteString + "?url=" + encoded) {
                    webView.load(URLRequest(url: harness))
                }
            } else {
                webView.load(navigationAction.request)
            }
            return nil
        }
    }

    private static let consoleBridgeJS = """
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
