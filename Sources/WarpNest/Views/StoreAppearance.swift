import AppKit
import SwiftUI

@MainActor enum StoreArt {
    private static let images: [String: NSImage] = {
        var result: [String: NSImage] = [:]
        for name in ["AlpineKart", "Steam", "SevenZip", "NotepadPlus", "Minesweeper"] {
            if let url = Bundle.module.url(forResource: name, withExtension: name == "AlpineKart" ? "jpg" : "png") {
                result[name] = NSImage(contentsOf: url)
            }
        }
        return result
    }()

    @MainActor @ViewBuilder static func image(_ name: String) -> some View {
        if let art = images[name] {
            Image(nsImage: art).resizable().accessibilityHidden(true)
        } else {
            Image(systemName: "macwindow").resizable().accessibilityHidden(true)
        }
    }
}

struct StoreButtonStyle: ButtonStyle {
    @Environment(\.isEnabled) private var enabled
    func makeBody(configuration: Configuration) -> some View {
        configuration.label.font(.system(size: 13, weight: .semibold))
            .padding(.horizontal, 14).padding(.vertical, 7)
            .foregroundStyle(.white)
            .background(.black.opacity(configuration.isPressed ? 0.68 : 0.86),
                        in: RoundedRectangle(cornerRadius: 7))
            .opacity(enabled ? 1 : 0.5)
    }
}
