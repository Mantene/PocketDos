import SwiftUI

struct ContentView: View {
    var body: some View {
        EmulatorWebView()
            .ignoresSafeArea()
            .background(Color.black)
    }
}

#Preview {
    ContentView()
}
