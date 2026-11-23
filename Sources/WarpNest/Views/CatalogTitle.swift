import Foundation
import SwiftUI
import WarpNestCore

enum CatalogTitle: String, CaseIterable, Identifiable, Sendable {
    case kart = "SuperTuxKart"
    case steam = "Steam"
    case sevenZip = "7-Zip"
    case notepad = "Notepad++"

    var id: Self { self }
    var artwork: String {
        switch self {
        case .kart: "AlpineKart"
        case .steam: "Steam"
        case .sevenZip: "SevenZip"
        case .notepad: "NotepadPlus"
        }
    }
    var category: String {
        switch self {
        case .kart: "Arcade racing"
        case .steam: "Game launcher"
        case .sevenZip: "File utility"
        case .notepad: "Text editor"
        }
    }
    var version: String {
        switch self {
        case .kart: "1.5"
        case .sevenZip: "26.06"
        case .notepad: "8.9.9.1"
        case .steam: "Steam client"
        }
    }
    var installerName: String {
        switch self {
        case .kart: "SuperTuxKart-1.5-installer-x86_64.exe"
        case .steam: "SteamSetup.exe"
        case .sevenZip: "7z2606-x64.exe"
        case .notepad: "npp.8.9.9.1.Installer.x64.exe"
        }
    }
    var executableName: String {
        switch self {
        case .kart: "supertuxkart.exe"
        case .steam: "Steam.exe"
        case .sevenZip: "7zFM.exe"
        case .notepad: "notepad++.exe"
        }
    }
    var downloadURL: URL {
        let base = "https://github.com/"
        switch self {
        case .kart: return URL(string: base + "supertuxkart/stk-code/releases/download/1.5/" + installerName)!
        case .steam: return SteamDownloaderService.officialEndpoint
        case .sevenZip: return URL(string: base + "ip7z/7zip/releases/download/26.06/" + installerName)!
        case .notepad: return URL(string: base + "notepad-plus-plus/notepad-plus-plus/releases/download/v8.9.9.1/" + installerName)!
        }
    }
    var checksum: String {
        switch self {
        case .kart: "a1260ebb73dd9da13ec3e37f526f29e494b3b66c00c05fd70767b30a4497d95e"
        case .steam: SteamDownloaderService.verifiedSHA256
        case .sevenZip: "9b697f65ecc2d9b0152f5ee96d72dde522a7827690349d9307935dacf40f42ec"
        case .notepad: "ce3267f5c4e7e42f847e00f4b20234da6150647203033cdde34a69593efc3152"
        }
    }
    static func name(forExecutable name: String) -> String {
        allCases.first { $0.executableName.caseInsensitiveCompare(name) == .orderedSame }?.rawValue
            ?? URL(fileURLWithPath: name).deletingPathExtension().lastPathComponent
    }
}

struct ShelfIdentity {
    let symbol: String
    let color: Color
    let highlight: Color
    var monogram: String?
    var plays = false

    init(_ symbol: String, _ color: Color, _ highlight: Color, plays: Bool = false) {
        self.symbol = symbol
        self.color = color
        self.highlight = highlight
        self.plays = plays
    }
    init(file: String) {
        switch file.lowercased() {
        case "supertuxkart.exe": self.init("flag.checkered", .orange, .yellow, plays: true)
        case "steam.exe", "steamsetup.exe": self.init("circle.hexagongrid.fill", .indigo, .teal)
        case "winemine.exe", "minesweeper.exe": self.init("flag.checkered", .purple, .pink, plays: true)
        case "clock.exe": self.init("clock", .brown, .orange)
        case "notepad.exe": self.init("text.alignleft", .teal, .mint)
        case "notepad++.exe":
            self.init("text.alignleft", .teal, .mint)
            monogram = "N++"
        case "control.exe": self.init("slider.horizontal.3", .indigo, .blue)
        case "7zfm.exe":
            self.init("archivebox", .brown, .orange)
            monogram = "7z"
        default: self.init("macwindow", .indigo, .purple)
        }
    }
    init(game: GameItem) {
        self.init(file: URL(fileURLWithPath: game.executableRelativePath).lastPathComponent)
        if symbol == "macwindow" {
            monogram = game.name.split(separator: " ").prefix(2).compactMap(\.first).map(String.init).joined().uppercased()
        }
        if game.executableRelativePath.lowercased().contains("/steamapps/common/") { plays = true }
    }
}

struct ShelfCover: View {
    let identity: ShelfIdentity
    var body: some View {
        ZStack {
            LinearGradient(colors: [identity.color, identity.highlight], startPoint: .bottomLeading, endPoint: .topTrailing)
            LinearGradient(colors: [.black.opacity(0.55), .black.opacity(0.12)], startPoint: .leading, endPoint: .trailing)
            GeometryReader { geo in
                let size = min(geo.size.width, geo.size.height)
                ZStack {
                    ForEach(1...4, id: \.self) { step in
                        Circle().stroke(.white.opacity(0.20), lineWidth: 1)
                            .frame(width: size * CGFloat(step) * 0.68, height: size * CGFloat(step) * 0.68)
                    }
                }
                .position(x: geo.size.width * 0.92, y: geo.size.height * 0.13)
                Group {
                    if let mark = identity.monogram {
                        Text(mark).fontDesign(.monospaced).lineLimit(1)
                    } else {
                        Image(systemName: identity.symbol)
                    }
                }
                    .font(.system(size: size * 0.44, weight: .medium))
                    .foregroundStyle(.white)
                    .position(x: geo.size.width * 0.27, y: geo.size.height * 0.56)
            }
        }.clipped().accessibilityHidden(true)
    }
}

struct ShelfLaunchButton: View {
    let viewModel: AppViewModel
    let game: GameItem
    var body: some View {
        let state = viewModel.activeSessionStates[game.id] ?? .stopped
        let label: String = switch state {
        case .stopFailed: "Retry Stop"
        case .running: "Stop"
        case .preparing: "Starting…"
        case .stopping: "Stopping…"
        case .stopped, .failed: game.isInstaller ? "Run Setup" : (ShelfIdentity(game: game).plays ? "Play" : "Open")
        }
        Button {
            Task { await viewModel.toggleGameSession(game: game) }
        } label: {
            if label == "Play" { Label(label, systemImage: "play.fill") }
            else { Text(label) }
        }
            .buttonStyle(StoreButtonStyle())
            .disabled(state == .preparing || state == .stopping)
            .accessibilityLabel("\(label) \(game.name)")
    }
}
