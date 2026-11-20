import SwiftUI
import WarpNestCore

struct MainWindowView: View {
    @Bindable var viewModel: AppViewModel

    var body: some View {
        NavigationSplitView {
            List(SidebarSection.allCases, selection: $viewModel.selectedTab) { section in
                NavigationLink(value: section) {
                    Label(section.rawValue, systemImage: section.iconName)
                }
            }
            .navigationTitle("WarpNest")
            .listStyle(.sidebar)
        } detail: {
            if viewModel.isLoadingLibrary {
                ProgressView("Opening your library…")
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
            } else {
                switch viewModel.selectedTab {
                case .library:
                    LibraryView(viewModel: viewModel)
                case .bottles:
                    BottlesView(viewModel: viewModel)
                case .diagnostics:
                    DiagnosticsView(viewModel: viewModel)
                case .settings:
                    SettingsView(viewModel: viewModel)
                }
            }
        }
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
        .commands {
            SidebarCommands()
        }
    }
}
