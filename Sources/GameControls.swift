import SwiftUI

/// js-dos key codes (from src/window/dos/controls/keys.ts).
enum DOSKey {
    static let up = 265, down = 264, left = 263, right = 262
    static let ctrl = 341, alt = 342, shift = 340
    static let space = 32, esc = 256, enter = 257
    static let n1 = 49, n2 = 50, n3 = 51, n4 = 52, n5 = 53
}

/// A hold-to-press control: key-down on touch, key-up on release.
struct HoldKey: View {
    let code: Int
    let controller: EmulatorController
    var label: String? = nil
    var systemImage: String? = nil
    var diameter: CGFloat = 56

    @State private var pressed = false

    var body: some View {
        content
            .frame(width: diameter, height: diameter)
            .background(pressed ? Color.white.opacity(0.40) : Color.white.opacity(0.16), in: Circle())
            .overlay(Circle().stroke(.white.opacity(0.25), lineWidth: 1))
            .contentShape(Circle())
            .gesture(
                DragGesture(minimumDistance: 0)
                    .onChanged { _ in
                        if !pressed { pressed = true; controller.keyDown(code) }
                    }
                    .onEnded { _ in
                        pressed = false; controller.keyUp(code)
                    }
            )
    }

    @ViewBuilder private var content: some View {
        if let systemImage {
            Image(systemName: systemImage).font(.title2).foregroundStyle(.white)
        } else {
            Text(label ?? "").font(.headline).foregroundStyle(.white)
        }
    }
}

/// A tap control: press-and-release once.
struct TapKey: View {
    let code: Int
    let controller: EmulatorController
    let label: String
    var body: some View {
        Button {
            controller.tapKey(code)
        } label: {
            Text(label)
                .font(.subheadline.weight(.semibold))
                .foregroundStyle(.white)
                .frame(width: 42, height: 36)
                .background(.white.opacity(0.16), in: RoundedRectangle(cornerRadius: 8))
        }
        .buttonStyle(.plain)
    }
}

/// Directional pad (arrow keys) for the bottom-left.
struct DPad: View {
    let controller: EmulatorController
    var body: some View {
        VStack(spacing: 6) {
            HoldKey(code: DOSKey.up, controller: controller, systemImage: "chevron.up")
            HStack(spacing: 6) {
                HoldKey(code: DOSKey.left, controller: controller, systemImage: "chevron.left")
                Color.clear.frame(width: 56, height: 56)
                HoldKey(code: DOSKey.right, controller: controller, systemImage: "chevron.right")
            }
            HoldKey(code: DOSKey.down, controller: controller, systemImage: "chevron.down")
        }
    }
}

/// Weapons row + fire/use for the bottom-right (FPS layout).
struct ActionCluster: View {
    let controller: EmulatorController
    var body: some View {
        VStack(alignment: .trailing, spacing: 12) {
            HStack(spacing: 6) {
                TapKey(code: DOSKey.n1, controller: controller, label: "1")
                TapKey(code: DOSKey.n2, controller: controller, label: "2")
                TapKey(code: DOSKey.n3, controller: controller, label: "3")
                TapKey(code: DOSKey.n4, controller: controller, label: "4")
                TapKey(code: DOSKey.n5, controller: controller, label: "5")
                TapKey(code: DOSKey.esc, controller: controller, label: "Esc")
            }
            HStack(spacing: 14) {
                HoldKey(code: DOSKey.space, controller: controller, label: "USE", diameter: 64)
                HoldKey(code: DOSKey.ctrl, controller: controller, label: "FIRE", diameter: 74)
            }
        }
    }
}
