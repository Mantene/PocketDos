import SwiftUI

// PocketDOS — Track A spike.
// Goal: prove that js-dos (WASM DOSBox/-X) runs inside a WKWebView served entirely
// from the app bundle (offline), so we can measure real Win9x / DOS speed on device.
@main
struct PocketDOSApp: App {
    var body: some Scene {
        WindowGroup {
            ContentView()
                .ignoresSafeArea()
                .preferredColorScheme(.dark)
                .statusBarHidden(true)
        }
    }
}
