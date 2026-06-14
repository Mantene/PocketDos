import SwiftUI
import WebKit

/// Hosts the js-dos player in a WKWebView whose assets are served from the app
/// bundle via `BundleSchemeHandler`. Forwards JS `console.*` and uncaught errors
/// to Xcode's console (prefixed `[web]`) so the spike is debuggable on device.
struct EmulatorWebView: UIViewRepresentable {

    func makeCoordinator() -> Coordinator { Coordinator() }

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

        webView.load(URLRequest(url: BundleSchemeHandler.startURL))
        return webView
    }

    func updateUIView(_ uiView: WKWebView, context: Context) {}

    final class Coordinator: NSObject, WKScriptMessageHandler, WKNavigationDelegate, WKUIDelegate {
        func userContentController(_ controller: WKUserContentController,
                                   didReceive message: WKScriptMessage) {
            if message.name == "console" {
                print("[web] \(message.body)")
            }
        }

        func webView(_ webView: WKWebView, didFailProvisionalNavigation navigation: WKNavigation!,
                     withError error: Error) {
            print("[web] navigation failed: \(error.localizedDescription)")
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
