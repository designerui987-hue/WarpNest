import SwiftUI
import WarpNestCore

struct DiscoverView: View {
    @Bindable var viewModel: AppViewModel
    let query: String
    @State private var detail: CatalogTitle?

    private var term: String { query.trimmingCharacters(in: .whitespacesAndNewlines) }
    private func matches(_ value: String) -> Bool {
        term.isEmpty || value.localizedCaseInsensitiveContains(term)
    }

    var body: some View {
        let apps = [CatalogTitle.steam, .sevenZip, .notepad].filter { matches($0.rawValue + " " + $0.category) }
        let games = viewModel.games.filter { matches($0.name) }
            .sorted { ($0.lastPlayedAt ?? $0.createdAt) > ($1.lastPlayedAt ?? $1.createdAt) }
        let showFeature = matches("SuperTuxKart Arcade kart racing for Windows")
        GeometryReader { geo in
            ScrollView {
                VStack(alignment: .leading, spacing: 0) {
                    if showFeature {
                        feature(width: geo.size.width)
                        Divider()
                    }
                    VStack(alignment: .leading, spacing: 18) {
                        if !apps.isEmpty {
                            Text("Browse Windows apps").font(.title.bold())
                            if geo.size.width >= 890 {
                                HStack(spacing: 18) {
                                    ForEach(apps) { title in
                                        if title != apps.first { Divider() }
                                        appRow(title)
                                    }
                                }.frame(height: 70)
                            } else {
                                ForEach(apps) { title in appRow(title) }
                            }
                            Divider()
                        }
                        if !games.isEmpty || term.isEmpty {
                            HStack {
                                Text("Your library").font(.title.bold())
                                Spacer()
                                if games.count > 3 {
                                    Button("View all") { viewModel.selectedTab = .library }
                                }
                            }
                            if games.isEmpty {
                                HStack {
                                    Text("Add your first Windows game or app.").foregroundStyle(.secondary)
                                    Spacer()
                                    Button("Open Library") { viewModel.selectedTab = .library }.buttonStyle(StoreButtonStyle())
                                }
                            }
                            ForEach(games.prefix(3)) { game in
                                HStack(spacing: 14) {
                                    libraryArt(game)
                                    VStack(alignment: .leading, spacing: 4) {
                                        Text(game.name).font(.headline)
                                        Text(game.isInstaller ? "Installer" : (ShelfIdentity(game: game).plays ? "Game" : "App"))
                                            .foregroundStyle(.secondary)
                                        if viewModel.bottles.first(where: { $0.id == game.bottleID })?.runtimeID == .simulation {
                                            Text("Simulated").font(.caption)
                                        }
                                    }
                                    Spacer()
                                    ShelfLaunchButton(viewModel: viewModel, game: game)
                                }
                                Divider()
                            }
                        }
                        if !showFeature && apps.isEmpty && games.isEmpty {
                            ContentUnavailableView.search(text: term).frame(maxWidth: .infinity)
                        }
                    }.padding(.horizontal, 30).padding(.vertical, 24)
                }
            }
        }
        .sheet(item: $detail) { title in CatalogInstallView(viewModel: viewModel, title: title) }
    }

    private func feature(width: CGFloat) -> some View {
        let panel = max(300, width * 0.32)
        let height = min(425, max(272, width * 0.316))
        return HStack(spacing: 0) {
            VStack(alignment: .leading, spacing: 16) {
                Text("Featured game").font(.headline).foregroundStyle(.secondary)
                Text("SuperTuxKart").font(.system(size: min(58, width * 0.045), weight: .bold))
                    .tracking(-1.8).lineLimit(1).minimumScaleFactor(0.76)
                Text("Arcade kart racing for Windows.").font(.title3).foregroundStyle(.secondary)
                Button { detail = .kart } label: { Label("View game", systemImage: "arrow.right").labelStyle(TrailingSymbol()) }
                    .buttonStyle(StoreButtonStyle()).padding(.top, 9)
            }.padding(.horizontal, 30).frame(width: panel, alignment: .leading)
            StoreArt.image("AlpineKart").scaledToFill()
                .frame(width: max(1, width - panel), height: height).clipped()
        }.frame(height: height)
    }

    private func appRow(_ title: CatalogTitle) -> some View {
        let existing = viewModel.catalogEntry(title)
        return HStack(spacing: 12) {
            StoreArt.image(title.artwork).scaledToFit().frame(width: 54, height: 54)
            VStack(alignment: .leading, spacing: 4) {
                Text(title.rawValue).font(.headline)
                Text(title.category).font(.subheadline).foregroundStyle(.secondary)
            }
            Spacer(minLength: 4)
            if let existing {
                ShelfLaunchButton(viewModel: viewModel, game: existing)
            } else {
                Button {
                    if downloading(title) { viewModel.selectedTab = .downloads }
                    else { detail = title }
                } label: {
                    if downloading(title) { Text("Downloads") }
                    else { Label("Install", systemImage: "arrow.down").labelStyle(TrailingSymbol()) }
                }.buttonStyle(StoreButtonStyle()).accessibilityLabel((downloading(title) ? "Show download for " : "Install options for ") + title.rawValue)
            }
        }.frame(maxWidth: .infinity)
    }

    private func downloading(_ title: CatalogTitle) -> Bool {
        viewModel.transferTasks[title] != nil || (title == .steam && viewModel.isInstallingSteam)
    }

    @ViewBuilder private func libraryArt(_ game: GameItem) -> some View {
        let file = URL(fileURLWithPath: game.executableRelativePath).lastPathComponent.lowercased()
        if let title = CatalogTitle.allCases.first(where: { $0.executableName.lowercased() == file || $0.installerName.lowercased() == file }) {
            StoreArt.image(title.artwork).scaledToFill().frame(width: 52, height: 52).clipShape(RoundedRectangle(cornerRadius: 8))
        } else if ["winemine.exe", "minesweeper.exe"].contains(file) {
            StoreArt.image("Minesweeper").scaledToFit().frame(width: 52, height: 52)
        } else {
            ShelfCover(identity: ShelfIdentity(game: game)).frame(width: 52, height: 52).clipShape(RoundedRectangle(cornerRadius: 8))
        }
    }
}

private struct TrailingSymbol: LabelStyle {
    func makeBody(configuration: Configuration) -> some View {
        HStack(spacing: 7) { configuration.title; configuration.icon }
    }
}

struct CatalogInstallView: View {
    @Bindable var viewModel: AppViewModel
    let title: CatalogTitle
    @Environment(\.dismiss) private var dismiss
    @State private var target: BottleID?

    var body: some View {
        VStack(alignment: .leading, spacing: 15) {
            if title == .kart {
                StoreArt.image("AlpineKart").scaledToFill().frame(width: 396, height: 150).clipped()
            }
            Text(title.rawValue).font(.largeTitle.bold())
            Text(title.category + " · Windows · " + title.version).foregroundStyle(.secondary)
            Text("Compatibility on this Mac is unverified.").font(.callout)
            if title == .kart { Text("Installer download: 723 MB").font(.callout) }
            if title != .steam, let source = URL(string: title.downloadURL.deletingLastPathComponent().absoluteString
                .replacingOccurrences(of: "/releases/download/", with: "/releases/tag/")) {
                Link("Publisher release", destination: source)
            }
            if let item = viewModel.catalogEntry(title) {
                Button("View in Library") {
                    dismiss()
                    viewModel.searchQuery = item.name
                    viewModel.selectedTab = .library
                }.buttonStyle(StoreButtonStyle())
            } else if viewModel.realRuntimes.isEmpty {
                Text("Set up Wine to run Windows software on this Mac.")
                Button("Set up Wine") { dismiss(); viewModel.selectedTab = .settings }.buttonStyle(StoreButtonStyle())
            } else {
                Picker("Environment", selection: $target) {
                    Text("Dedicated environment").tag(nil as BottleID?)
                    ForEach(viewModel.realBottles) { Text($0.name).tag(Optional($0.id)) }
                }
                Button(title == .steam ? "Download and install" : "Download installer") {
                    dismiss()
                    viewModel.selectedTab = .downloads
                    if title == .steam { viewModel.startSteamInstall(targetBottleID: target) }
                    else { viewModel.downloadCatalog(title, target: target) }
                }.buttonStyle(StoreButtonStyle())
                .disabled(viewModel.transferTasks[title] != nil || (title == .steam && viewModel.isInstallingSteam))
            }
            HStack { Spacer(); Button("Close") { dismiss() }.keyboardShortcut(.cancelAction) }
        }.padding(24).frame(width: 444)
    }
}
