import SwiftUI
import WarpNestCore

struct MainWindowView: View {
    @Bindable var viewModel: AppViewModel

    @State private var discoverSearch = ""
    @State private var downloadSearch = ""
    @FocusState private var searchFocused: Bool

    private var search: Binding<String> {
        switch viewModel.selectedTab {
        case .library: return $viewModel.searchQuery
        case .downloads: return $downloadSearch
        default: return $discoverSearch
        }
    }

    var body: some View {
        VStack(spacing: 0) {
            if viewModel.isLoadingLibrary {
                ProgressView("Opening your library…").frame(maxWidth: .infinity, maxHeight: .infinity)
            } else {
                switch viewModel.selectedTab {
                case .discover: DiscoverView(viewModel: viewModel, query: discoverSearch)
                case .library: LibraryView(viewModel: viewModel)
                case .downloads: DownloadsView(viewModel: viewModel, query: downloadSearch)
                case .bottles: BottlesView(viewModel: viewModel)
                case .diagnostics: DiagnosticsView(viewModel: viewModel)
                case .settings: SettingsView(viewModel: viewModel)
                }
            }
        }
        .background(Color(red: 0.982, green: 0.977, blue: 0.972))
        .toolbar {
            ToolbarItem(placement: .navigation) {
                Menu {
                    ForEach([SidebarSection.bottles, .diagnostics, .settings]) { page in
                        Button(page.rawValue) { viewModel.selectedTab = page }
                    }
                } label: {
                    HStack(spacing: 6) {
                        Text("W").font(.system(size: 23, weight: .black)).foregroundStyle(.orange)
                        Text("WarpNest").font(.headline.bold())
                    }
                }.menuStyle(.borderlessButton).help("Environments, diagnostics, and settings")
            }
            ToolbarItem(placement: .principal) {
                HStack(spacing: 22) {
                    ForEach([SidebarSection.discover, .library, .downloads]) { page in
                        Button {
                            viewModel.selectedTab = page
                        } label: {
                            Text(page.rawValue).font(.system(size: 15, weight: viewModel.selectedTab == page ? .bold : .medium))
                                .padding(.vertical, 7)
                                .overlay(alignment: .bottom) {
                                    if viewModel.selectedTab == page {
                                        Capsule().frame(height: 2)
                                    }
                                }
                        }.buttonStyle(.plain)
                        .accessibilityAddTraits(viewModel.selectedTab == page ? .isSelected : [])
                    }
                }
            }
            ToolbarItem(placement: .primaryAction) {
                if [.discover, .library, .downloads].contains(viewModel.selectedTab) {
                    HStack(spacing: 6) {
                        Image(systemName: "magnifyingglass").foregroundStyle(.secondary)
                        TextField("Search", text: search).textFieldStyle(.plain)
                            .focused($searchFocused).accessibilityLabel("Search " + viewModel.selectedTab.rawValue)
                    }
                    .padding(6).frame(width: 152)
                    .overlay(RoundedRectangle(cornerRadius: 6).strokeBorder(.secondary.opacity(0.4)))
                }
            }
        }
        .preferredColorScheme(.light)
        .frame(minWidth: 900, minHeight: 600)
        .alert("WarpNest Notice", isPresented: $viewModel.showingErrorAlert) {
            Button("OK", role: .cancel) {}
        } message: {
            Text(viewModel.errorMessage ?? "")
        }
        .task {
            await viewModel.initializeApp()
        }
    }
}

@main
struct WarpNestApp: App {
    // Single application-scoped service container shared by all windows (WN-06)
    @State private var sharedViewModel = AppViewModel()

    init() {
        if CommandLine.arguments.contains("--verify-gamer-ux") {
            Task { @MainActor in
                await executeGamerUXVerification()
                exit(0)
            }
        }
    }

    var body: some Scene {
        WindowGroup {
            MainWindowView(viewModel: sharedViewModel)
        }
        .windowResizability(.contentMinSize)
        .windowToolbarStyle(.unified(showsTitle: false))
        .defaultSize(width: 1120, height: 720)
    }
}
