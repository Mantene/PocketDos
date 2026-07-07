import Foundation

// The PURE half of the Windows 98 install orchestration: everything here is
// deterministic, WebView-free, and unit-tested. `InstallOrchestrator` is the
// effectful interpreter that feeds these types real console lines and timers.
//
// The mechanics they encode are the Chrome-proven runbook (wizard-s0):
//   stage 1  boot the CD's floppy → unattended Setup phase-1 (file copy)
//   stage 2  boot C: → Setup's info-collection pages driven by 5 scripted
//            keystrokes → unattended hardware setup → guest shutdown KILLS
//            the WASM (expected!)
//   stage 3  recovery boot C: (no keystrokes) → desktop → final capture
// with the install state carried between stages as the target sockdrive's
// write-overlay blob, captured in-page via `ci.persist(true)` every 4.5 s and
// re-seeded LIVE into IndexedDB (that re-seed is what lets warm reboots and
// page reloads continue instead of restarting).

// MARK: - Breadcrumb parsing

/// One parsed `[pdos-install]` console line. The install page (and the
/// injected capture loop) narrate progress on the console; the native side
/// hears them through the existing console message bridge.
enum InstallBreadcrumb: Equatable {
    /// The emulator booted and `window.ci` is live (arm the capture loop).
    case ciReady
    /// `?instwait=1` parked the boot behind `pdosInstallGo()` (re-seed now).
    case waitingForGo
    /// The capture loop accepted a persist pass: `count` = u32le sector-record
    /// count at overlay byte 0, `bytes` = whole blob length.
    case captured(count: Int, bytes: Int)
    /// The capture loop saw a persist BELOW the accepted floor and dropped it
    /// (normal around guest reboots — persist can return a partial set).
    case captureRegressed
    /// The engine died ([panic] re-emitted under the install prefix, or a
    /// bare [panic] line from the engine itself).
    case panic(String)

    static let prefix = "[pdos-install]"

    /// Parses one console line (as delivered by the console bridge, i.e. with
    /// a "log: " / "error: " level prefix — matched anywhere in the line).
    /// Unknown install breadcrumbs (phase banners, capture-error notes, …)
    /// and unrelated lines return nil.
    static func parse(_ line: String) -> InstallBreadcrumb? {
        if let r = line.range(of: prefix) {
            let tail = line[r.upperBound...].trimmingCharacters(in: .whitespaces)
            if tail == "ci-ready" { return .ciReady }
            if tail == "waiting for go" { return .waitingForGo }
            if tail.hasPrefix("captured ") {
                let parts = tail.split(separator: " ")
                guard parts.count >= 3, let count = Int(parts[1]), let bytes = Int(parts[2]),
                      count >= 0, bytes >= 0 else { return nil }
                return .captured(count: count, bytes: bytes)
            }
            if tail.hasPrefix("capture-regressed") { return .captureRegressed }
            if tail.contains("[panic]") { return .panic(String(tail)) }
            return nil
        }
        // Engine panics that predate the install page's console.error re-emit
        // hook (e.g. during bundle build) arrive without the install prefix.
        if line.contains("[panic]") { return .panic(line) }
        return nil
    }
}

// MARK: - Capture plateau detection

/// Decides when a stage's disk writes have SETTLED, from the stream of
/// accepted capture counts. Runbook rule: the same count on ≥4 consecutive
/// ticks, after the count passed 300,000 (phase-1's file copy is well past
/// that; earlier plateaus are just Setup not having started yet).
///
/// Two guards beyond the raw rule:
///  - MONOTONIC: a count below the accepted floor is rejected outright (a
///    persist racing a guest reboot can return a partial set — accepting it
///    would regress the held state). Rejections do NOT break a plateau run.
///  - GROWTH ARMING (`requireGrowth`): the plateau only fires after the count
///    has strictly INCREASED at least once within this detector's lifetime.
///    Stages 2/3 (and stage-1 retries) boot with the count already above the
///    minimum — without arming, the first four idle boot ticks would read as
///    "installation settled" before Setup wrote anything.
struct CapturePlateauDetector: Equatable {
    enum Verdict: Equatable {
        case rejected   // below the monotonic floor — discard
        case accepted   // fresh data, no plateau yet
        case plateau    // the stage's writes have settled
    }

    let minimumCount: Int
    let plateauTicks: Int
    let requireGrowth: Bool

    private(set) var lastAccepted: Int?
    private(set) var consecutiveSame = 0
    private(set) var hasGrown = false

    init(minimumCount: Int = 300_000, plateauTicks: Int = 4, requireGrowth: Bool = true) {
        self.minimumCount = minimumCount
        self.plateauTicks = plateauTicks
        self.requireGrowth = requireGrowth
    }

    mutating func ingest(_ count: Int) -> Verdict {
        if let last = lastAccepted, count < last { return .rejected }
        if let last = lastAccepted, count == last {
            consecutiveSame += 1
        } else {
            if lastAccepted != nil { hasGrown = true }
            lastAccepted = count
            consecutiveSame = 1
        }
        if consecutiveSame >= plateauTicks, count > minimumCount, hasGrown || !requireGrowth {
            return .plateau
        }
        return .accepted
    }
}

// MARK: - Stage state machine

/// The stage-progression + retry authority. The orchestrator reports what
/// happened (boot outcome, plateau, death) and this answers with the ONE next
/// move, so the retry budgets live — and are tested — in one place.
///
/// Budgets, from the runbook:
///  - a stage load that never reaches ci-ready (90 s timeout or an instant
///    [panic]) is retried on the SAME stage, ≤3 attempts per boot episode;
///  - a mid-stage death in stage 2 is EXPECTED (Windows' first shutdown kills
///    the WASM) and transitions to stage 3 free of charge;
///  - any other mid-stage death (stage 1, stage 3, or capture silence >5 min)
///    re-boots that stage, drawing on a shared recovery budget of 3.
struct InstallFlow: Equatable {
    enum Stage: String, Equatable {
        case stage1   // floppy boot: unattended Setup phase-1 (file copy)
        case stage2   // boot C: + scripted keystrokes + hardware setup
        case stage3   // recovery boot C:, hands-off, to the desktop
    }

    enum Next: Equatable {
        case bootStage(Stage, attempt: Int)
        case finalizeReady
        case failed(String)
    }

    static let maxBootAttempts = 3
    static let maxRecoveryBoots = 3

    private(set) var stage: Stage = .stage1
    private(set) var bootAttempt = 1
    private(set) var recoveryBoots = 0

    /// The opening move (after media build): boot stage 1, attempt 1.
    func begin() -> Next { .bootStage(.stage1, attempt: 1) }

    /// The current stage's page never reached ci-ready (timeout / instant panic).
    mutating func bootFailed() -> Next {
        bootAttempt += 1
        guard bootAttempt <= Self.maxBootAttempts else {
            return .failed("\(stage.rawValue) never booted after \(Self.maxBootAttempts) attempts")
        }
        return .bootStage(stage, attempt: bootAttempt)
    }

    /// ci-ready arrived — this boot episode's budget is settled.
    mutating func bootSucceeded() {
        bootAttempt = 1
    }

    /// The stage reached its capture plateau (its writes settled) and any
    /// required pull completed.
    mutating func stageEnded() -> Next {
        switch stage {
        case .stage1:
            stage = .stage2
            bootAttempt = 1
            return .bootStage(.stage2, attempt: 1)
        case .stage2:
            // Not reached in practice (stage 2 ends by dying), but a stage 2
            // that settles without dying still wants the same recovery boot.
            stage = .stage3
            bootAttempt = 1
            return .bootStage(.stage3, attempt: 1)
        case .stage3:
            return .finalizeReady
        }
    }

    /// The stage died mid-run: engine [panic], WebContent process gone, or
    /// capture silence past the watchdog.
    mutating func died() -> Next {
        switch stage {
        case .stage2:
            // THE expected death: "Windows is shutting down" kills the WASM.
            stage = .stage3
            bootAttempt = 1
            return .bootStage(.stage3, attempt: 1)
        case .stage1, .stage3:
            recoveryBoots += 1
            guard recoveryBoots <= Self.maxRecoveryBoots else {
                return .failed("\(stage.rawValue) kept dying after \(Self.maxRecoveryBoots) recovery reboots")
            }
            bootAttempt = 1
            return .bootStage(stage, attempt: 1)
        }
    }
}

// MARK: - Injected JavaScript

/// The JS the orchestrator injects into the install page. Kept as pure string
/// builders so tests can pin the load-bearing pieces (the persist call, the
/// monotonic floor, the live re-seed, the breadcrumb format).
enum InstallJS {

    /// js-dos key codes (src/window/dos/controls/keys.ts — the same table
    /// EmulatorController's key helpers use).
    static let pressEnter = "window.ci && window.ci.simulateKeyPress(257)"
    /// Alt+A chord (License page's "I accept" accelerator): simulateKeyPress
    /// with two codes presses them together.
    static let pressAltA = "window.ci && window.ci.simulateKeyPress(342, 65)"

    /// Stops the capture loop (set before the FINAL pull so no fresher persist
    /// replaces `__lastGood` while the finalize is deciding).
    static let stopCaptureLoop =
        "window.__pdosCapStop = true; "
        + "if (window.__pdosCapTimer) { clearInterval(window.__pdosCapTimer); window.__pdosCapTimer = null; } "
        + "true;"

    /// Minimal string escape for embedding orchestrator-built values (custom-
    /// scheme URLs — controlled charset, but escape defensively anyway).
    static func quoted(_ s: String) -> String {
        var out = "\""
        for ch in s.unicodeScalars {
            switch ch {
            case "\"": out += "\\\""
            case "\\": out += "\\\\"
            case "\n": out += "\\n"
            case "\r": out += "\\r"
            default: out.unicodeScalars.append(ch)
            }
        }
        return out + "\""
    }

    /// The in-page capture loop, armed after each stage's ci-ready. Every
    /// 4.5 s it runs `ci.persist(true)`, picks the TARGET drive's serialized
    /// sector-diff (matched by exact base URL — two sockdrives are mounted in
    /// stages 1/2, so a positional fallback could grab the CAB source), reads
    /// the u32le record count at byte 0, and — monotonic guard — if the count
    /// is >= the accepted floor: holds the blob as `window.__lastGood`, re-
    /// seeds it LIVE into IndexedDB (`pdosReseed`), and logs
    /// `[pdos-install] captured <count> <bytes>` for the native watcher.
    ///
    /// `floor` seeds the monotonic guard ACROSS page reloads: the page-local
    /// floor dies with the page, so a partial persist on the first tick of a
    /// recovery boot could otherwise be accepted and re-seeded — regressing
    /// IndexedDB. The orchestrator passes the highest count it has ever seen.
    ///
    /// The pull channel (`pdosCapPullBegin/Chunk/End`) mirrors the
    /// pdosPersistBegin/Chunk/End transport shape: begin pins the CURRENT
    /// `__lastGood` reference (persist passes replace, never mutate, so the
    /// pinned blob stays coherent while ticks continue), chunks stream base64.
    static func captureLoop(targetBase: String, floor: Int) -> String {
        """
        (function () {
          if (window.__pdosCapTimer) { clearInterval(window.__pdosCapTimer); window.__pdosCapTimer = null; }
          window.__pdosCapStop = false;
          var TARGET = \(quoted(targetBase));
          var last = \(max(0, floor));
          var busy = false;
          function b64(u8) {
            var s = "", CHUNK = 0x8000;
            for (var i = 0; i < u8.length; i += CHUNK) {
              s += String.fromCharCode.apply(null, u8.subarray(i, i + CHUNK));
            }
            return btoa(s);
          }
          window.pdosCapPullBegin = function () {
            window.__pdosPull = window.__lastGood || null;
            return window.__pdosPull ? window.__pdosPull.length : 0;
          };
          window.pdosCapPullChunk = function (off, len) {
            var p = window.__pdosPull;
            if (!p) return "";
            var end = Math.min(off + len, p.length);
            if (off >= end) return "";
            return b64(p.subarray(off, end));
          };
          window.pdosCapPullEnd = function () { window.__pdosPull = null; return true; };
          async function tick() {
            if (busy || window.__pdosCapStop) return;
            busy = true;
            try {
              if (!window.ci || typeof window.ci.persist !== "function") return;
              var out = await Promise.race([
                window.ci.persist(true),
                new Promise(function (resolve, reject) {
                  setTimeout(function () { reject(new Error("persist timeout")); }, 60000);
                })
              ]);
              var bytes = null;
              if (out && out.drives) {
                for (var i = 0; i < out.drives.length; i++) {
                  if (out.drives[i].url === TARGET) { bytes = out.drives[i].persist; break; }
                }
              }
              if (!bytes || !bytes.subarray || bytes.length < 4) {
                console.log("[pdos-install] capture-miss");
                return;
              }
              var count = (bytes[0] | (bytes[1] << 8) | (bytes[2] << 16) | (bytes[3] << 24)) >>> 0;
              if (count >= last) {
                last = count;
                window.__lastGood = bytes;
                await window.pdosReseed(TARGET, bytes);
                console.log("[pdos-install] captured " + count + " " + bytes.length);
              } else {
                console.log("[pdos-install] capture-regressed " + count + " " + last);
              }
            } catch (e) {
              console.log("[pdos-install] capture-error " + (e && e.message ? e.message : e));
            } finally { busy = false; }
          }
          window.__pdosCapTimer = setInterval(tick, 4500);
        })();
        """
    }

    /// Stage 2/3 launch: on "[pdos-install] waiting for go", fetch the pulled
    /// stage checkpoint and re-seed it into IndexedDB BEFORE the sockdrive
    /// mounts, then release the parked boot. A failed fetch does NOT wedge the
    /// stage: the capture loop re-seeded IndexedDB live on every accepted
    /// capture, so the store already holds the last good state — log and go.
    static func reseedAndGo(stageBinURL: String, targetBase: String) -> String {
        """
        (async function () {
          try {
            var r = await fetch(\(quoted(stageBinURL)), { cache: "no-store" });
            if (r.ok) {
              var bytes = new Uint8Array(await r.arrayBuffer());
              if (bytes.length >= 4) { await window.pdosReseed(\(quoted(targetBase)), bytes); }
            } else {
              console.log("[pdos-install] reseed-skip HTTP " + r.status);
            }
          } catch (e) {
            console.log("[pdos-install] reseed-skip " + (e && e.message ? e.message : e));
          }
          if (window.pdosInstallGo) { window.pdosInstallGo(); }
          else { console.log("[pdos-install] go-missing"); }
        })();
        """
    }
}

// MARK: - Final game shape

/// The library entry an installed machine becomes: a bundle-less sockdrive
/// game (chunks in `drive/`, install writes in `sockdrive-write.bin`), mouse
/// controls (it's a desktop OS), 64 MB emulated RAM (the memsize the whole
/// install ran with), identity = SHA256 of the small deterministic metaj —
/// exactly the shape `GameStore.loadGame` reads back.
func installedWin98Game(id: String, folderURL: URL) -> Game {
    var game = Game(id: id, title: "Windows 98", bundleFileName: "",
                    folderURL: folderURL, controlProfile: .mouse)
    game.memoryMB = 64
    game.contentHash = sha256Hex(ofFileAt: folderURL.appendingPathComponent("drive/sockdrive.metaj"))
    return game
}
