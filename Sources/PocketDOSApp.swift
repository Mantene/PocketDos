import SwiftUI
import AVFoundation

@main
struct PocketDOSApp: App {
    init() {
        // Play game audio through the speaker even when the ring/silent switch is
        // on (default WKWebView audio is "ambient" and gets muted otherwise).
        let session = AVAudioSession.sharedInstance()
        try? session.setCategory(.playback, mode: .default, options: [])
        try? session.setActive(true)
    }

    var body: some Scene {
        WindowGroup {
            ContentView()
                .preferredColorScheme(.dark)
        }
    }
}
