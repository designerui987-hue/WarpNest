import AppKit
import SwiftUI
import UniformTypeIdentifiers
import WarpNestCore

struct LibraryView: View {
    @Bindable var viewModel: AppViewModel
    @State private var showingAddSheet = false

    private var availableBottles: [Bottle] {
        let runtimeIDs = Set(viewModel.registeredRuntimes.filter {
            $0.isVerified && (!$0.isSimulation || viewModel.appSettings.developerModeEnabled)
        }.map(\.id))
        return viewModel.bottles.filter { runtimeIDs.contains($0.runtimeID) }
    }

    private var hasRuntime: Bool {
        viewModel.registeredRuntimes.contains {
            $0.isVerified && (!$0.isSimulation || viewModel.appSettings.developerModeEnabled)
        }
    }

    var body: some View {
        let matches = viewModel.filteredGames
        let simulations = Set(viewModel.bottles.filter { $0.runtimeID == .simulation }.map(\.id))
        VStack(spacing: 0) {
            HStack(spacing: 12) {
                HStack {
                    Image(systemName: "magnifyingglass").foregroundStyle(.secondary).accessibilityHidden(true)
                    TextField("Search games and apps", text: $viewModel.searchQuery)
                        .textFieldStyle(.plain)
                }
                .padding(7)
                .background(Color(nsColor: .controlBackgroundColor), in: RoundedRectangle(cornerRadius: 8))
                .frame(maxWidth: 320)
                Spacer()
                Picker("Library layout", selection: $viewModel.isGridView) {
                    Label("Grid", systemImage: "square.grid.2x2").tag(true)
                    Label("List", systemImage: "list.bullet").tag(false)
                }
                .labelStyle(.iconOnly)
                .labelsHidden()
                .pickerStyle(.segmented)
                .frame(width: 80)
                if !viewModel.games.isEmpty {
                    Button(action: { viewModel.openSteamInstaller() }) {
                        Label("Install Steam", systemImage: "arrow.down.circle")
                    }
                    .buttonStyle(.bordered)

                    Button(action: openSetupOrAdd) { Label("Add game or app", systemImage: "plus") }
                        .buttonStyle(.borderedProminent)
                }
            }
            .padding()
            Divider()
            if let handoff = viewModel.pendingInstallerHandoff {
                HStack(spacing: 12) {
                    Image(systemName: "checkmark.circle.fill")
                        .foregroundColor(.green)
                        .font(.title2)
                    VStack(alignment: .leading, spacing: 2) {
                        Text("Steam Installation Detected").bold()
                        Text("Found Steam.exe at: \(handoff.detectedExecutablePath)")
                            .font(.caption)
                            .foregroundColor(.secondary)
                    }
                    Spacer()
                    Button("Keep Installer") {
                        viewModel.cancelInstallerHandoff()
                    }
                    .buttonStyle(.borderless)
                    Button("Confirm Steam") {
                        Task {
                            try? await viewModel.confirmInstallerHandoff(for: handoff.id, targetPath: handoff.detectedExecutablePath)
                        }
                    }
                    .buttonStyle(.borderedProminent)
                }
                .padding(12)
                .background(Color.green.opacity(0.12))
                .cornerRadius(10)
                .padding(.horizontal)
            } else if let failedID = viewModel.failedInstallerGameID, let failedGame = viewModel.games.first(where: { $0.id == failedID }) {
                HStack(spacing: 12) {
                    Image(systemName: "exclamationmark.triangle.fill")
                        .foregroundColor(.orange)
                        .font(.title2)
                    VStack(alignment: .leading, spacing: 2) {
                        Text("Setup Ended: Steam.exe Not Found").bold()
                        Text("The environment and files were preserved.")
                            .font(.caption)
                            .foregroundColor(.secondary)
                    }
                    Spacer()
                    Button("Retry Setup") {
                        Task { await viewModel.retryInstaller(for: failedID) }
                    }
                    .buttonStyle(.borderedProminent)
                    Button("Choose Installed App…") {
                        chooseAppForFailedGame(failedGame)
                    }
                    .buttonStyle(.bordered)
                    Button("Dismiss") {
                        viewModel.failedInstallerGameID = nil
                    }
                    .buttonStyle(.borderless)
                }
                .padding(12)
                .background(Color.orange.opacity(0.12))
                .cornerRadius(10)
                .padding(.horizontal)
            }
            if viewModel.games.isEmpty {
                ContentUnavailableView {
                    Label("Your game and app library", systemImage: "gamecontroller")
                } description: {
                    Text(!hasRuntime ? "Import a Wine runtime in Settings to run Windows games and apps on this Mac."
                         : availableBottles.isEmpty ? "Create an environment (bottle) to hold your Windows files and settings."
                         : "Choose a Windows game, app, or installer to add its shortcut.")
                } actions: {
                    HStack(spacing: 12) {
                        Button(action: { viewModel.openSteamInstaller() }) {
                            Label("Install Steam", systemImage: "arrow.down.circle")
                        }
                        .buttonStyle(.bordered)

                        Button(!hasRuntime ? "Set up Wine" : availableBottles.isEmpty ? "Set up an environment" : "Add game or app",
                               action: openSetupOrAdd)
                            .buttonStyle(.borderedProminent)
                    }
                }
            } else if matches.isEmpty {
                ContentUnavailableView {
                    Label("No matching games or apps", systemImage: "magnifyingglass")
                } description: {
                    Text("Try a different name.")
                } actions: {
                    Button("Clear search") { viewModel.searchQuery = "" }
                }
            } else if viewModel.isGridView {
                ScrollView {
                    LazyVGrid(columns: [GridItem(.adaptive(minimum: 200, maximum: 300), spacing: 16)], spacing: 16) {
                        ForEach(matches) { game in GameCardView(viewModel: viewModel, game: game, simulated: simulations.contains(game.bottleID)) }
                    }
                    .padding(20)
                }
            } else {
                List(matches) { game in GameListRowView(viewModel: viewModel, game: game, simulated: simulations.contains(game.bottleID)) }
            }
        }
        .navigationTitle("Library")
        .sheet(isPresented: $showingAddSheet) {
            AddShortcutSheet(viewModel: viewModel, bottles: availableBottles)
        }
        .sheet(isPresented: $viewModel.showingSteamInstallSheet) {
            SteamInstallSheet(viewModel: viewModel, bottles: availableBottles)
        }
        .sheet(isPresented: $viewModel.showingSteamDiscoverySheet) {
            SteamDiscoverySheet(viewModel: viewModel)
        }
    }

    private func openSetupOrAdd() {
        if !hasRuntime { viewModel.selectedTab = .settings }
        else if availableBottles.isEmpty { viewModel.selectedTab = .bottles }
        else { showingAddSheet = true }
    }

    private func chooseAppForFailedGame(_ game: GameItem) {
        guard let bottle = availableBottles.first(where: { $0.id == game.bottleID }) else { return }
        let panel = NSOpenPanel()
        panel.canChooseDirectories = false
        panel.allowedContentTypes = [UTType(filenameExtension: "exe") ?? .data]
        panel.directoryURL = URL(fileURLWithPath: bottle.directoryPath).appendingPathComponent("drive_c")
        panel.message = "Choose the installed Windows executable for \(game.name)"
        guard panel.runModal() == .OK, let url = panel.url else { return }
        Task {
            try? await viewModel.chooseInstalledAppManually(for: game.id, chosenURL: url)
        }
    }
}

private struct AddShortcutSheet: View {
    let viewModel: AppViewModel
    let bottles: [Bottle]
    @Environment(\.dismiss) private var dismiss
    @State private var bottleID: BottleID?
    @State private var file: URL?
    @State private var name = ""
    @State private var error: String?
    @State private var saving = false

    init(viewModel: AppViewModel, bottles: [Bottle]) {
        self.viewModel = viewModel
        self.bottles = bottles
        _bottleID = State(initialValue: bottles.count == 1 ? bottles.first?.id : nil)
    }

    private var bottle: Bottle? { bottles.first { $0.id == bottleID } }

    // Resolve the selected file against the actual destination at submission time.
    private var target: (path: String, external: Bool)? {
        guard let file, let bottle else { return nil }
        let prefix = URL(fileURLWithPath: bottle.directoryPath).resolvingSymlinksInPath().standardizedFileURL.path + "/"
        let path = file.resolvingSymlinksInPath().standardizedFileURL.path
        return path.hasPrefix(prefix) ? (String(path.dropFirst(prefix.count)), false) : (path, true)
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 16) {
            Text("Add game or app").font(.title2.bold())
            Picker("Environment", selection: $bottleID) {
                Text("Choose an environment").tag(nil as BottleID?)
                ForEach(bottles) { b in
                    Text(b.runtimeID == .simulation ? "\(b.name) (Simulated)" : b.name).tag(Optional(b.id))
                }
            }
            .onChange(of: bottleID) { _, _ in
                file = nil
                name = ""
                error = nil
            }
            VStack(alignment: .leading, spacing: 6) {
                Button(file == nil ? "Choose Windows file…" : "Change Windows file…", action: chooseFile)
                    .disabled(bottle == nil)
                Text(file?.lastPathComponent ?? "Select the .exe for your game, app, or installer.")
                    .foregroundStyle(.secondary)
                    .lineLimit(2)
                if target?.external == true {
                    Text("This shortcut uses the file at its current location. Moving it will break the shortcut.")
                        .font(.callout)
                        .foregroundStyle(.secondary)
                }
            }
            TextField("Library name", text: $name)
                .textFieldStyle(.roundedBorder)
            if let error { Text(error).foregroundStyle(.red) }
            HStack {
                Spacer()
                Button("Cancel") { dismiss() }.keyboardShortcut(.cancelAction)
                Button("Add to library", action: save)
                    .keyboardShortcut(.defaultAction)
                    .disabled(target == nil || name.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
            }
        }
        .padding(24)
        .frame(width: 440)
        .disabled(saving)
        .interactiveDismissDisabled(saving)
    }

    private func chooseFile() {
        guard let bottle else { return }
        let panel = NSOpenPanel()
        panel.canChooseDirectories = false
        panel.allowedContentTypes = [UTType(filenameExtension: "exe") ?? .data]
        panel.directoryURL = URL(fileURLWithPath: bottle.directoryPath).appendingPathComponent("drive_c")
        guard panel.runModal() == .OK, let url = panel.url else { return }
        let suggested = url.deletingPathExtension().lastPathComponent
        if name.isEmpty || name == file?.deletingPathExtension().lastPathComponent { name = suggested }
        file = url
        error = nil
    }

    private func save() {
        guard !saving, let bottle, let target else { return }
        saving = true
        Task {
            defer { saving = false }
            do {
                try await viewModel.addGame(name: name.trimmingCharacters(in: .whitespacesAndNewlines),
                                            bottleID: bottle.id, executablePath: target.path,
                                            isExternalExecutable: target.external)
                viewModel.searchQuery = ""
                dismiss()
            } catch { self.error = error.localizedDescription }
        }
    }
}

struct GameCardView: View {
    let viewModel: AppViewModel
    let game: GameItem
    let simulated: Bool

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            ZStack {
                RoundedRectangle(cornerRadius: 10)
                    .fill(Color.accentColor.opacity(0.15))
                    .frame(height: 120)

                Image(systemName: "gamecontroller.fill")
                    .font(.system(size: 40))
                    .foregroundColor(.accentColor)
            }

            VStack(alignment: .leading, spacing: 4) {
                Text(game.name)
                    .font(.headline)
                    .lineLimit(1)

                let state = viewModel.activeSessionStates[game.id] ?? .stopped
                HStack(spacing: 6) {
                    Circle()
                        .fill(circleColor(for: state))
                        .frame(width: 8, height: 8)
                    if simulated { Text("Simulated").font(.caption) }
                    if game.isInstaller {
                        Text("Installer")
                            .font(.caption2)
                            .padding(.horizontal, 4)
                            .padding(.vertical, 1)
                            .background(Color.blue.opacity(0.2))
                            .foregroundColor(.blue)
                            .cornerRadius(4)
                    }
                    Text(state.rawValue)
                        .font(.caption)
                        .foregroundColor(.secondary)
                }
            }

            HStack {
                let state = viewModel.activeSessionStates[game.id] ?? .stopped
                let isRunning = state == .running || state == .stopFailed
                let isTransitioning = state == .preparing || state == .stopping
                let buttonTitle = state == .stopFailed ? "Retry Stop" : (isRunning ? "Stop" : (game.isInstaller ? "Run Setup" : "Play"))
                let buttonIcon = isRunning ? "stop.fill" : "play.fill"

                Button {
                    Task {
                        await viewModel.toggleGameSession(game: game)
                    }
                } label: {
                    Label(buttonTitle, systemImage: buttonIcon)
                        .frame(maxWidth: .infinity)
                }
                .buttonStyle(.borderedProminent)
                .tint(isRunning ? .red : .accentColor)
                .disabled(isTransitioning)
                .accessibilityLabel("\(buttonTitle) \(game.name)")
            }
        }
        .padding(12)
        .background(Color(NSColor.controlBackgroundColor))
        .cornerRadius(12)
        .overlay(
            RoundedRectangle(cornerRadius: 12)
                .stroke(Color.secondary.opacity(0.2), lineWidth: 1)
        )
        .contextMenu {
            if game.name.localizedCaseInsensitiveContains("steam") || game.executableRelativePath.localizedCaseInsensitiveContains("steam") {
                Button {
                    Task { await viewModel.discoverSteamGames(in: game.bottleID) }
                } label: {
                    Label("Scan for Installed Steam Games", systemImage: "arrow.clockwise")
                }
            }
        }
    }

    private func circleColor(for state: SessionState) -> Color {
        switch state {
        case .running: return .green
        case .preparing, .stopping: return .orange
        case .failed, .stopFailed: return .red
        case .stopped: return .gray
        }
    }
}

struct GameListRowView: View {
    let viewModel: AppViewModel
    let game: GameItem
    let simulated: Bool

    var body: some View {
        HStack(spacing: 16) {
            Image(systemName: "gamecontroller.fill")
                .foregroundColor(.accentColor)
                .frame(width: 28, height: 28)

            VStack(alignment: .leading, spacing: 2) {
                Text(game.name)
                    .font(.body)
                    .bold()
                Text(simulated ? "Simulated · " + game.executableRelativePath : game.executableRelativePath)
                    .lineLimit(1)
                    .truncationMode(.middle)
                    .font(.caption)
                    .foregroundColor(.secondary)
            }

            Spacer()

            let state = viewModel.activeSessionStates[game.id] ?? .stopped
            Text(state.rawValue)
                .font(.caption)
                .foregroundColor(.secondary)

            let isRunning = state == .running || state == .stopFailed
            let isTransitioning = state == .preparing || state == .stopping
            let buttonTitle = state == .stopFailed ? "Retry Stop" : (isRunning ? "Stop" : (game.isInstaller ? "Run Setup" : "Play"))

            Button(buttonTitle) {
                Task {
                    await viewModel.toggleGameSession(game: game)
                }
            }
            .buttonStyle(.bordered)
            .tint(isRunning ? .red : .accentColor)
            .disabled(isTransitioning)
            .accessibilityLabel("\(buttonTitle) \(game.name)")
        }
        .padding(.vertical, 4)
        .contextMenu {
            if game.name.localizedCaseInsensitiveContains("steam") || game.executableRelativePath.localizedCaseInsensitiveContains("steam") {
                Button {
                    Task { await viewModel.discoverSteamGames(in: game.bottleID) }
                } label: {
                    Label("Scan for Installed Steam Games", systemImage: "arrow.clockwise")
                }
            }
        }
    }
}

// MARK: - Steam Sheets (Phase 2)

struct SteamInstallSheet: View {
    @Bindable var viewModel: AppViewModel
    let bottles: [Bottle]
    @Environment(\.dismiss) private var dismiss

    @State private var selectedBottleID: BottleID?

    var body: some View {
        VStack(alignment: .leading, spacing: 20) {
            HStack(spacing: 12) {
                Image(systemName: "arrow.down.circle.fill")
                    .foregroundColor(.accentColor)
                    .font(.system(size: 32))

                VStack(alignment: .leading, spacing: 2) {
                    Text("Install Steam")
                        .font(.title2)
                        .bold()
                    Text("Downloads and sets up official Steam client with verified cryptographic integrity.")
                        .font(.caption)
                        .foregroundColor(.secondary)
                }
            }

            Divider()

            if viewModel.isInstallingSteam {
                VStack(alignment: .leading, spacing: 10) {
                    ProgressView(value: viewModel.steamInstallProgress, total: 1.0)
                        .progressViewStyle(.linear)

                    HStack {
                        Text(viewModel.steamInstallStatus)
                            .font(.subheadline)
                        Spacer()
                        if viewModel.steamInstallTotalBytes > 0 {
                            Text(String(format: "%.0f%%", viewModel.steamInstallProgress * 100))
                                .font(.subheadline)
                                .monospacedDigit()
                                .foregroundColor(.secondary)
                        }
                    }

                    HStack {
                        Spacer()
                        Button("Cancel") {
                            viewModel.cancelSteamInstall()
                        }
                        .buttonStyle(.bordered)
                    }
                }
                .padding(.vertical, 8)
            } else if let error = viewModel.steamInstallError {
                VStack(alignment: .leading, spacing: 12) {
                    HStack(spacing: 8) {
                        Image(systemName: "exclamationmark.triangle.fill")
                            .foregroundColor(.red)
                        Text("Installation Failed")
                            .bold()
                            .foregroundColor(.red)
                    }
                    Text(error)
                        .font(.caption)
                        .foregroundColor(.secondary)

                    HStack {
                        Spacer()
                        Button("Dismiss") {
                            viewModel.steamInstallError = nil
                            dismiss()
                        }
                        .buttonStyle(.bordered)

                        Button("Retry") {
                            viewModel.startSteamInstall(targetBottleID: selectedBottleID)
                        }
                        .buttonStyle(.borderedProminent)
                    }
                }
            } else {
                VStack(alignment: .leading, spacing: 14) {
                    Text("Target Environment:")
                        .font(.headline)

                    Picker("Environment", selection: $selectedBottleID) {
                        Text("Create Dedicated Steam Bottle (Recommended)").tag(BottleID?.none)
                        ForEach(bottles) { bottle in
                            Text(bottle.name).tag(BottleID?.some(bottle.id))
                        }
                    }
                    .labelsHidden()

                    Text("Official source: cdn.fastly.steamstatic.com\nVerified SHA-256: 7d365453...12bcb")
                        .font(.caption2)
                        .foregroundColor(.secondary)

                    HStack {
                        Spacer()
                        Button("Cancel") {
                            dismiss()
                        }
                        .keyboardShortcut(.cancelAction)

                        Button("Download & Install") {
                            viewModel.startSteamInstall(targetBottleID: selectedBottleID)
                        }
                        .buttonStyle(.borderedProminent)
                        .keyboardShortcut(.defaultAction)
                    }
                }
            }
        }
        .padding(24)
        .frame(width: 460)
    }
}

struct SteamDiscoverySheet: View {
    @Bindable var viewModel: AppViewModel
    @Environment(\.dismiss) private var dismiss

    var body: some View {
        VStack(alignment: .leading, spacing: 16) {
            HStack {
                Image(systemName: "sparkles")
                    .foregroundColor(.accentColor)
                    .font(.title2)
                VStack(alignment: .leading, spacing: 2) {
                    Text("Discovered Steam Games")
                        .font(.headline)
                    Text("The following games were found installed in the Steam environment:")
                        .font(.caption)
                        .foregroundColor(.secondary)
                }
                Spacer()
            }

            Divider()

            if viewModel.discoveredSteamGames.isEmpty {
                Text("No games found in steamapps.")
                    .foregroundColor(.secondary)
                    .padding()
            } else {
                ScrollView {
                    VStack(spacing: 8) {
                        ForEach(viewModel.discoveredSteamGames) { game in
                            HStack {
                                VStack(alignment: .leading, spacing: 2) {
                                    Text(game.name)
                                        .font(.body)
                                        .bold()
                                    Text("AppID: \(game.appID) · \(game.relativeExecutablePath ?? "No exe found")")
                                        .font(.caption2)
                                        .foregroundColor(.secondary)
                                }
                                Spacer()
                                Button("Add Shortcut") {
                                    Task {
                                        await viewModel.addDiscoveredGame(game)
                                    }
                                }
                                .buttonStyle(.borderedProminent)
                                .disabled(game.relativeExecutablePath == nil)
                            }
                            .padding(8)
                            .background(Color(NSColor.controlBackgroundColor))
                            .cornerRadius(8)
                        }
                    }
                }
                .frame(maxHeight: 260)
            }

            HStack {
                Spacer()
                Button("Done") {
                    dismiss()
                }
                .keyboardShortcut(.defaultAction)
            }
        }
        .padding(20)
        .frame(width: 480)
    }
}
