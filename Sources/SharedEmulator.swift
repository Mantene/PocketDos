import SwiftUI
import WebKit

/// ONE WKWebView + EmulatorController reused for EVERY game launch.
///
/// WHY: iOS does not reap this app's WebContent processes when a WKWebView is dismissed
/// (termination fails with "Client not entitled"). So creating a fresh WebView per game —
/// the old design — piled up ~300-400 MB zombie processes until the next launch OOM'd.
/// That's fatal for the 225 MB Win98 image: it booted once, then every relaunch crashed,
/// with the device's baseline memory stuck at ~941 MB and never dropping. Reusing ONE
/// WebView means ONE process forever: leaving a game loads a SAME-ORIGIN blank page
/// (pocketdos://app/blank.html — NOT about:blank, whose opaque origin churns a fresh
/// process per launch; see EmulatorController.teardown) which frees the page, and the
/// next game reuses the same process. Nothing accumulates. (A crash frees its own
/// process, so even an OOM doesn't leak — the next launch spins a fresh one.)
/// Used on the main thread only (created by SwiftUI's `@StateObject`; all callers are
/// SwiftUI actions / WebKit delegate callbacks, which are already main-thread).
final class SharedEmulator: ObservableObject {
    let controller = EmulatorController()
    let webView: WKWebView
    /// Strongly held here (NOT only by the userContentController) so there's no retain
    /// cycle: the host owns both the WebView and the Bridge.
    private let coordinator: EmulatorWebView.Bridge

    init() {
        let config = WKWebViewConfiguration()
        config.setURLSchemeHandler(BundleSchemeHandler(), forURLScheme: BundleSchemeHandler.scheme)
        config.allowsInlineMediaPlayback = true
        config.mediaTypesRequiringUserActionForPlayback = []

        let coord = EmulatorWebView.Bridge(controller: controller)
        config.userContentController.add(coord, name: "console")
        config.userContentController.add(coord, name: "hotkey")
        config.userContentController.addUserScript(WKUserScript(
            source: EmulatorWebView.consoleBridgeJS,
            injectionTime: .atDocumentStart, forMainFrameOnly: false))

        let wv = WKWebView(frame: .zero, configuration: config)
        #if DEBUG
        wv.isInspectable = true
        #endif
        wv.scrollView.isScrollEnabled = false
        wv.scrollView.contentInsetAdjustmentBehavior = .never
        wv.backgroundColor = .black
        wv.isOpaque = false
        wv.navigationDelegate = coord
        wv.uiDelegate = coord

        self.webView = wv
        self.coordinator = coord
        controller.webView = wv
    }

    /// Point the shared WebView at a game (resetting per-game controller state first).
    func play(_ game: Game) {
        controller.prepareForNewGame()
        webView.load(URLRequest(url: Self.startURL(for: game)))
    }

    /// Leave gameplay: drop the heavy page (frees the process's memory) but keep the
    /// process so the next launch reuses it.
    func leave() {
        controller.teardown()
    }

    /// The harness URL for a game: `?url=<bundle>` plus the optional run/mem/conf/restore/
    /// mt32 params. Same-origin (pocketdos://) so js-dos can fetch without a CORS barrier.
    private static func startURL(for game: Game) -> URL {
        func enc(_ s: String) -> String { s.addingPercentEncoding(withAllowedCharacters: .urlQueryAllowed) ?? s }
        func abs(_ rel: String) -> String { "\(BundleSchemeHandler.scheme)://\(BundleSchemeHandler.host)/\(rel)" }
        #if DEBUG
        // Sockdrive boot-speed spike: boot Win9x from the chunks bundled at Web/drive/
        // (served at pocketdos://app/drive). index.html's ?sockspike= branch mounts it
        // via `imgmount 2 sockdrive <base>` + `boot c:` on the forced dosbox-x backend.
        if game.isSockSpike {
            let s = BundleSchemeHandler.startURL.absoluteString + "?sockspike=" + enc(abs("drive")) + "&mem=64"
            return URL(string: s) ?? BundleSchemeHandler.startURL
        }
        // Sockdrive WRITE-LOAD OOM spike: boot the DOS floppy onto the existing sockdrive
        // and write ~398 MB to it to find the in-heap write-set ceiling.
        if game.isWriteSpike {
            let s = BundleSchemeHandler.startURL.absoluteString + "?writespike=" + enc(abs("drive"))
            return URL(string: s) ?? BundleSchemeHandler.startURL
        }
        #endif
        // Production sockdrive game: a chunked raw HDD under Documents/Games/<id>/drive,
        // served at pocketdos://app/lib/<id>/drive. index.html's ?drive= branch mounts it
        // via `imgmount 2 sockdrive <base>` + `boot c:` on the forced dosbox-x backend
        // (plain dosbox lacks the sockdrive client). Carries only the emulated-RAM hint.
        if game.isSockdrive {
            var s = BundleSchemeHandler.startURL.absoluteString + "?drive=" + enc(abs(game.driveBasePath))
            if let mb = game.memoryMB { s += "&mem=\(mb)" }
            // S2: re-seed a persisted sector-diff into IndexedDB before the drive mounts.
            if let srp = game.sockdriveRestorablePath { s += "&restore=" + enc(abs(srp)) }
            return URL(string: s) ?? BundleSchemeHandler.startURL
        }
        guard !game.webRelativeURL.isEmpty else { return BundleSchemeHandler.startURL }
        var q = "?url=" + enc(abs(game.webRelativeURL))
        if let rc = game.runCommand, !rc.isEmpty { q += "&run=" + enc(rc) }
        // A large disk image (Win9x .jsdos) must NOT carry a mem/config override: js-dos's
        // in-place config rewrite (index.html "applying config…" path) re-buffers the whole
        // 200 MB+ bundle ~3× in JS heap and OOM-crashes the WebContent process at load
        // (observed on iPhone — boots once after a reboot, then black-screens once memory
        // tightens). Its emulated RAM is baked into the image's own dosbox.conf instead, and
        // the bundle loads via the light streaming path (index.html:195 `return url`).
        if !game.isLargeDiskImage {
            if let mb = game.memoryMB { q += "&mem=\(mb)" }
            if let co = game.configOverride, !co.isEmpty { q += "&conf=" + enc(co) }
        }
        if let rp = game.restorablePath, !rp.isEmpty { q += "&restore=" + enc(abs(rp)) }
        if let mt = game.mt32RomsRelativeURL, !mt.isEmpty { q += "&mt32roms=" + enc(abs(mt)) }
        return URL(string: BundleSchemeHandler.startURL.absoluteString + q) ?? BundleSchemeHandler.startURL
    }
}
