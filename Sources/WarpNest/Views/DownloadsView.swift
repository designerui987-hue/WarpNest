import SwiftUI
import WarpNestCore

struct DownloadsView: View {
    @Bindable var viewModel: AppViewModel
    let query: String

    var body: some View {
        let visible = CatalogTitle.allCases.filter { title in
            let hasActivity = viewModel.transfers[title] != nil || viewModel.catalogEntry(title) != nil ||
                (title == .steam && (viewModel.isInstallingSteam || viewModel.steamInstallError != nil || viewModel.steamInstallStatus == "Installation cancelled."))
            return hasActivity && (query.isEmpty || title.rawValue.localizedCaseInsensitiveContains(query))
        }
        VStack(alignment: .leading, spacing: 16) {
            Text("Downloads").font(.largeTitle.bold())
            if visible.isEmpty {
                if query.isEmpty {
                    ContentUnavailableView {
                        Label("No downloads yet", systemImage: "arrow.down.circle")
                    } description: {
                        Text("Choose a Windows app or game in Discover.")
                    } actions: {
                        Button("Browse Discover") { viewModel.selectedTab = .discover }.buttonStyle(StoreButtonStyle())
                    }.frame(maxWidth: .infinity, maxHeight: .infinity)
                } else { ContentUnavailableView.search(text: query).frame(maxWidth: .infinity, maxHeight: .infinity) }
            } else {
                ScrollView {
                    VStack(spacing: 14) {
                        ForEach(visible) { title in
                            HStack(spacing: 16) {
                                StoreArt.image(title.artwork).scaledToFill().frame(width: 52, height: 52)
                                    .clipShape(RoundedRectangle(cornerRadius: 8))
                                VStack(alignment: .leading, spacing: 5) {
                                    Text(title.rawValue).font(.headline)
                                    if title == .steam && viewModel.isInstallingSteam {
                                        Text(viewModel.steamInstallStatus)
                                        ProgressView(value: viewModel.steamInstallProgress)
                                    } else if let transfer = viewModel.transfers[title], viewModel.transferTasks[title] != nil {
                                        Text(transfer.status)
                                        ProgressView(value: transfer.progress).progressViewStyle(.linear)
                                    } else if let error = title == .steam ? viewModel.steamInstallError : nil {
                                        Text(error).textSelection(.enabled)
                                    } else if viewModel.transfers[title]?.canRetry == true {
                                        Text(viewModel.transfers[title]?.status ?? "").textSelection(.enabled)
                                    } else if let item = viewModel.catalogEntry(title) {
                                        Text(item.isInstaller ? "Setup in Library" : "In Library")
                                    } else {
                                        Text(viewModel.transfers[title]?.status ?? viewModel.steamInstallStatus)
                                    }
                                }.frame(maxWidth: .infinity, alignment: .leading)
                                if title == .steam && viewModel.isInstallingSteam {
                                    Button("Cancel") { viewModel.cancelSteamInstall() }
                                } else if let task = viewModel.transferTasks[title] {
                                    Button("Cancel") { task.cancel() }
                                } else if viewModel.transfers[title]?.canRetry == true {
                                    Button("Retry") { viewModel.downloadCatalog(title, target: viewModel.transfers[title]?.target) }
                                } else if title == .steam && viewModel.steamInstallError != nil {
                                    Button("Retry") { viewModel.startSteamInstall(targetBottleID: viewModel.lastSteamTarget) }
                                } else if let item = viewModel.catalogEntry(title) {
                                    Button("View in Library") {
                                        viewModel.searchQuery = item.name
                                        viewModel.selectedTab = .library
                                    }
                                } else if title == .steam {
                                    Button("Retry") { viewModel.startSteamInstall(targetBottleID: viewModel.lastSteamTarget) }
                                }
                            }
                            Divider()
                        }
                    }
                }
            }
        }.padding(30).frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
    }
}
