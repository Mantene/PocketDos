import SwiftUI
import AVFoundation
import UIKit

/// Hosts the orientation policy: gameplay locks to landscape while the library
/// stays free to rotate. `lockLandscape` is toggled by EmulatorView.
final class AppDelegate: NSObject, UIApplicationDelegate {
    static var lockLandscape = false

    func application(_ application: UIApplication,
                     supportedInterfaceOrientationsFor window: UIWindow?) -> UIInterfaceOrientationMask {
        AppDelegate.lockLandscape ? .landscape : .allButUpsideDown
    }
}

@main
struct PocketDOSApp: App {
    @UIApplicationDelegateAdaptor(AppDelegate.self) private var appDelegate

    init() {
        // Play game audio through the speaker even when the ring/silent switch is
        // on (default WKWebView audio is "ambient" and gets muted otherwise).
        // Run off the main thread — setActive can block (AVAudioSession hang risk).
        DispatchQueue.global(qos: .userInitiated).async {
            let session = AVAudioSession.sharedInstance()
            try? session.setCategory(.playback, mode: .default, options: [])
            try? session.setActive(true)
        }
    }

    var body: some Scene {
        WindowGroup {
            ContentView()
                .preferredColorScheme(.dark)
        }
    }
}
