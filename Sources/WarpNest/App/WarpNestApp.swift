import SwiftUI
import WarpNestCore

struct MainWindowView: View {
    @State private var viewModel = AppViewModel()

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
    var body: some Scene {
        WindowGroup {
            MainWindowView()
        }
        .windowResizability(.contentMinSize)
        .commands {
            SidebarCommands()
        }
    }
}
