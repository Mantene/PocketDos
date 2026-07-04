import Foundation
import WebKit
import UniformTypeIdentifiers

/// Serves the bundled `Web/` directory to the WKWebView over a custom scheme
/// (`pocketdos://app/...`) with correct MIME types.
///
/// Why a custom scheme instead of `file://` or an embedded HTTP server:
///  - `file://` in WKWebView has an opaque/limited origin and blocks some
///    fetch/worker/WASM-streaming behavior that js-dos relies on.
///  - A custom scheme gives us a real, stable origin with no network entitlement
///    and no localhost port, while letting us set `Content-Type: application/wasm`
///    so `WebAssembly.instantiateStreaming` works and the WebKit WASM JIT engages.
final class BundleSchemeHandler: NSObject, WKURLSchemeHandler {
    static let scheme = "pocketdos"
    static let host = "app"
    static var startURL: URL {
        URL(string: "\(scheme)://\(host)/index.html")!
    }

    private let rootURL: URL   // bundled Web/ assets
    private let gamesURL: URL  // Documents/Games (imported library)

    #if DEBUG
    // Sockdrive boot-speed spike instrumentation (DEBUG only). The on-device unknown is
    // how long a Win9x boot takes when sockdrive fetches its 256 KiB chunks strictly one
    // at a time (BATCH_SIZE=1, sockdrive.ts) and each fetch hits the SYNCHRONOUS,
    // main-thread `Data(contentsOf:)` read below. These counters expose the fetch count +
    // inter-fetch cadence so we can localize the wall. Reset on each `sockdrive.metaj`
    // open (so relaunches measure fresh); all scheme-task callbacks are main-thread, so
    // plain statics are safe.
    private static var sockFetchCount = 0
    private static var sockFetchBytes = 0
    private static var sockFirstNs: UInt64 = 0
    private static var sockLastNs: UInt64 = 0
    #endif

    override init() {
        // `Web` is added to the project as a folder reference, so it lands at
        // <bundle resources>/Web preserving its subdirectory structure.
        let base = Bundle.main.resourceURL ?? Bundle.main.bundleURL
        self.rootURL = base.appendingPathComponent("Web", isDirectory: true)
        let docs = FileManager.default.urls(for: .documentDirectory, in: .userDomainMask)[0]
        self.gamesURL = docs.appendingPathComponent("Games", isDirectory: true)
        super.init()
    }

    /// Resolves a request path to a file, keeping each request inside its allowed root:
    ///  - `lib/<id>/...` → Documents/Games (imported games, same origin → no CORS)
    ///  - everything else → bundled Web/
    /// Returns nil on path-traversal attempts.
    private func resolveFile(_ relPath: String) -> URL? {
        if relPath.hasPrefix("lib/") {
            let sub = String(relPath.dropFirst("lib/".count))
            let file = gamesURL.appendingPathComponent(sub).standardizedFileURL
            return Self.contains(gamesURL, file) ? file : nil
        }
        let file = rootURL.appendingPathComponent(relPath).standardizedFileURL
        return Self.contains(rootURL, file) ? file : nil
    }

    /// True iff `file` is `base` itself or lives inside it. Uses a trailing-separator
    /// boundary so a sibling whose name merely SHARES the prefix (e.g. `…/Games` vs
    /// `…/GamesEvil`) does not satisfy containment — a plain `hasPrefix` would. This
    /// is the path-traversal guard for the custom scheme; kept `internal static` so
    /// it can be unit-tested in isolation.
    static func contains(_ base: URL, _ file: URL) -> Bool {
        let basePath = base.standardizedFileURL.path
        let filePath = file.standardizedFileURL.path
        if filePath == basePath { return true }
        let boundary = basePath.hasSuffix("/") ? basePath : basePath + "/"
        return filePath.hasPrefix(boundary)
    }

    func webView(_ webView: WKWebView, start task: WKURLSchemeTask) {
        guard let url = task.request.url else {
            task.didFailWithError(URLError(.badURL)); return
        }

        // Map URL path onto Web/ (bundled) or Documents/Games (lib/ → imported).
        var relPath = url.path
        if relPath.hasPrefix("/") { relPath.removeFirst() }
        if relPath.isEmpty { relPath = "index.html" }

        guard let fileURL = resolveFile(relPath),
              let data = try? Data(contentsOf: fileURL) else {
            respondNotFound(url: url, task: task); return
        }

        #if DEBUG
        // Sockdrive spike: trace chunk GETs served from `drive/` (see static counters).
        if relPath.hasPrefix("drive/") {
            let now = DispatchTime.now().uptimeNanoseconds
            if relPath.hasSuffix("sockdrive.metaj") {
                Self.sockFirstNs = now; Self.sockLastNs = now
                Self.sockFetchCount = 0; Self.sockFetchBytes = 0
                print("[sockspike] ── sockdrive open: \(relPath) (\(data.count) B) ──")
            } else if relPath.hasSuffix(".raw") {
                let sinceLastMs = Self.sockLastNs == 0 ? 0 : Double(now - Self.sockLastNs) / 1_000_000
                let sinceFirstMs = Self.sockFirstNs == 0 ? 0 : Double(now - Self.sockFirstNs) / 1_000_000
                Self.sockLastNs = now
                Self.sockFetchCount += 1
                Self.sockFetchBytes += data.count
                print(String(format: "[sockspike] chunk #%d %@ (%dB) +%.0fms last, %.0fms total, %.1fMB cum",
                             Self.sockFetchCount, relPath, data.count, sinceLastMs, sinceFirstMs,
                             Double(Self.sockFetchBytes) / 1_048_576))
            }
        }
        #endif

        // Bundled assets (engine wasm/js/css) are immutable per app version — let
        // WebKit cache them so a reload (Restart / quick-load) doesn't re-fetch and
        // re-compile the multi-MB wasm. Imported games + saves under lib/ are mutable.
        let cache = relPath.hasPrefix("lib/")
            ? "no-store"
            : "public, max-age=31536000, immutable"
        let headers: [String: String] = [
            "Content-Type": Self.mimeType(forPathExtension: fileURL.pathExtension),
            "Content-Length": String(data.count),
            "Access-Control-Allow-Origin": "*",
            "Cache-Control": cache,
        ]
        let response = HTTPURLResponse(url: url, statusCode: 200,
                                       httpVersion: "HTTP/1.1", headerFields: headers)!
        task.didReceive(response)
        task.didReceive(data)
        task.didFinish()
    }

    func webView(_ webView: WKWebView, stop task: WKURLSchemeTask) {
        // No long-lived requests to cancel in this spike.
    }

    private func respondNotFound(url: URL, task: WKURLSchemeTask) {
        let response = HTTPURLResponse(url: url, statusCode: 404,
                                       httpVersion: "HTTP/1.1", headerFields: nil)!
        task.didReceive(response)
        task.didFinish()
    }

    /// Maps a file extension to a Content-Type. The `wasm` case is load-bearing:
    /// it must stay `application/wasm` so `WebAssembly.instantiateStreaming` works
    /// and the WebKit WASM JIT engages — reverting it to `octet-stream` silently
    /// disables the JIT and tanks emulator performance.
    static func mimeType(forPathExtension ext: String) -> String {
        switch ext.lowercased() {
        case "html", "htm": return "text/html; charset=utf-8"
        case "js", "mjs":   return "text/javascript; charset=utf-8"
        case "css":         return "text/css; charset=utf-8"
        case "wasm":        return "application/wasm"
        case "json", "map": return "application/json"
        case "wat":         return "text/plain; charset=utf-8"
        case "symbols":     return "text/plain; charset=utf-8"
        case "png":         return "image/png"
        case "jpg", "jpeg": return "image/jpeg"
        case "gif":         return "image/gif"
        case "svg":         return "image/svg+xml"
        case "webp":        return "image/webp"
        case "woff":        return "font/woff"
        case "woff2":       return "font/woff2"
        case "ttf":         return "font/ttf"
        case "wav":         return "audio/wav"
        case "jsdos", "zip": return "application/zip"
        default:
            if let type = UTType(filenameExtension: ext),
               let mime = type.preferredMIMEType {
                return mime
            }
            return "application/octet-stream"
        }
    }
}
