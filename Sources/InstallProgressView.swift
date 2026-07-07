import SwiftUI

/// Full-screen progress surface for the Windows 98 install. Hosts the app's
/// ONE shared WKWebView as a live (non-interactive) thumbnail — the WebView
/// must be in the view hierarchy for the install to render and run anyway, so
/// showing it doubles as the "is it actually doing something?" window — with
/// the orchestrator's stage/percent/elapsed below it.
struct InstallProgressView: View {
    @ObservedObject var orchestrator: InstallOrchestrator
    let shared: SharedEmulator
    /// Install finished — dismiss the whole wizard back to the library.
    var onFinished: () -> Void
    /// Cancelled or failed-and-closed — back to the wizard form.
    var onClosed: () -> Void

    @State private var confirmCancel = false

    var body: some View {
        ZStack {
            Color.black.ignoresSafeArea()
            VStack(spacing: 20) {
                Text("Installing Windows 98")
                    .font(.title2.bold())
                    .foregroundStyle(.white)
                    .padding(.top, 24)

                // Live view of the machine mid-install. Touches are disabled:
                // a stray tap during Setup's scripted pages could derail it.
                EmulatorWebView(shared: shared)
                    .aspectRatio(4 / 3, contentMode: .fit)
                    .frame(maxHeight: 240)
                    .clipShape(RoundedRectangle(cornerRadius: 12))
                    .overlay(RoundedRectangle(cornerRadius: 12)
                        .strokeBorder(.white.opacity(0.15), lineWidth: 1))
                    .allowsHitTesting(false)

                statusCard

                Spacer()

                footerButtons
                    .padding(.bottom, 28)
            }
            .padding(.horizontal, 20)
        }
        .interactiveDismissDisabled()
        .confirmationDialog("Stop installing Windows 98?",
                            isPresented: $confirmCancel, titleVisibility: .visible) {
            Button("Stop install", role: .destructive) {
                orchestrator.cancel()
                onClosed()
            }
            Button("Keep installing", role: .cancel) {}
        } message: {
            Text("Progress so far will be discarded.")
        }
    }

    // MARK: - Pieces

    private var statusCard: some View {
        VStack(spacing: 10) {
            HStack(spacing: 10) {
                statusIcon
                Text(stageTitle)
                    .font(.headline)
                    .foregroundStyle(.white)
                Spacer()
            }
            if case .buildingMedia(let percent) = orchestrator.state {
                ProgressView(value: Double(percent), total: 100)
                    .tint(.green)
            } else if orchestrator.state.isRunning {
                ProgressView()
                    .progressViewStyle(.linear)
                    .tint(.green)
            }
            HStack {
                Text(stageDetail)
                    .font(.footnote)
                    .foregroundStyle(.white.opacity(0.7))
                    .multilineTextAlignment(.leading)
                Spacer()
                if let startedAt = orchestrator.startedAt, orchestrator.state.isRunning {
                    TimelineView(.periodic(from: startedAt, by: 1)) { context in
                        Text(elapsedText(from: startedAt, to: context.date))
                            .font(.footnote.monospacedDigit())
                            .foregroundStyle(.white.opacity(0.7))
                    }
                }
            }
        }
        .padding(16)
        .background(RoundedRectangle(cornerRadius: 14).fill(.white.opacity(0.08)))
    }

    @ViewBuilder
    private var statusIcon: some View {
        switch orchestrator.state {
        case .done:
            Image(systemName: "checkmark.circle.fill").foregroundStyle(.green)
        case .failed:
            Image(systemName: "exclamationmark.triangle.fill").foregroundStyle(.yellow)
        default:
            Image(systemName: "gearshape.2.fill").foregroundStyle(.green)
        }
    }

    @ViewBuilder
    private var footerButtons: some View {
        switch orchestrator.state {
        case .done:
            Button {
                onFinished()
            } label: {
                Label("Back to library", systemImage: "checkmark")
                    .frame(maxWidth: .infinity)
            }
            .buttonStyle(.borderedProminent)
            .tint(.green)
        case .failed:
            Button {
                onClosed()
            } label: {
                Text("Close")
                    .frame(maxWidth: .infinity)
            }
            .buttonStyle(.borderedProminent)
        default:
            Button(role: .destructive) {
                confirmCancel = true
            } label: {
                Text("Cancel install")
                    .frame(maxWidth: .infinity)
            }
            .buttonStyle(.bordered)
            .tint(.red)
        }
    }

    // MARK: - Copy

    private var stageTitle: String {
        switch orchestrator.state {
        case .idle: return "Starting…"
        case .buildingMedia: return "Building install media"
        case .stage1FileCopy: return "Setup: copying Windows files"
        case .stage2Script: return "Setup: configuring Windows"
        case .stage3Finalizing: return "First boot"
        case .applyingMouseFix: return "Installing the mouse driver"
        case .done: return "Windows 98 is ready"
        case .failed: return "Install failed"
        }
    }

    private var stageDetail: String {
        switch orchestrator.state {
        case .idle:
            return ""
        case .buildingMedia(let percent):
            return "Reading your CD image and preparing the install disks (\(percent)%). "
                 + "This phase takes a few minutes."
        case .stage1FileCopy(let count):
            let progress = count > 0 ? "\(count.formatted()) disk sectors written so far. " : ""
            return progress + "Unattended file copy — roughly 15-25 minutes. Keep the app open."
        case .stage2Script(let step):
            switch step {
            case 0: return "Waiting for Setup's first page…"
            case 1...5: return "Answering Setup's questions automatically (step \(step) of 5)."
            default: return "Hardware detection and configuration — roughly 11-15 minutes. "
                          + "The screen going black partway through is expected."
            }
        case .stage3Finalizing:
            return "Booting your new Windows 98 machine and saving its final state."
        case .applyingMouseFix:
            return "Patching the installed system so the mouse works under emulation."
        case .done:
            return "Your machine is in the library. The install media were cleaned up."
        case .failed(let reason, let retryable):
            return reason + (retryable ? " You can close this and try the install again." : "")
        }
    }

    private func elapsedText(from start: Date, to now: Date) -> String {
        let seconds = max(0, Int(now.timeIntervalSince(start)))
        let (h, m, s) = (seconds / 3600, (seconds % 3600) / 60, seconds % 60)
        return h > 0 ? String(format: "%d:%02d:%02d", h, m, s) : String(format: "%d:%02d", m, s)
    }
}
