import SwiftUI
import WarpNestCore

struct LibraryView: View {
    @Bindable var viewModel: AppViewModel
    @State private var showingAddGameSheet = false
    @State private var newGameName = ""
    @State private var newGameBottleID: BottleID?
    @State private var newGameExecutable = ""
    @State private var validationError: String?

    var body: some View {
        VStack(spacing: 0) {
            // Toolbar header
            HStack {
                HStack(spacing: 8) {
                    Image(systemName: "magnifyingglass")
                        .foregroundColor(.secondary)
                    TextField("Search library...", text: $viewModel.searchQuery)
                        .textFieldStyle(.plain)
                }
                .padding(7)
                .background(Color(NSColor.controlBackgroundColor))
                .cornerRadius(8)
                .frame(maxWidth: 320)

                Spacer()

                Picker("View Style", selection: $viewModel.isGridView) {
                    Image(systemName: "square.grid.2x2").tag(true)
                    Image(systemName: "list.bullet").tag(false)
                }
                .pickerStyle(.segmented)
                .frame(width: 80)

                Button {
                    validationError = nil
                    showingAddGameSheet = true
                } label: {
                    Label("Add Game", systemImage: "plus")
                }
                .buttonStyle(.borderedProminent)
            }
            .padding()

            Divider()

            if viewModel.filteredGames.isEmpty {
                VStack(spacing: 16) {
                    Image(systemName: "gamecontroller")
                        .font(.system(size: 48))
                        .foregroundColor(.secondary)
                    Text("No Games in Library")
                        .font(.title2)
                        .bold()
                    Text("Create a bottle and add a Windows executable (.exe) to start playing.")
                        .foregroundColor(.secondary)
                    Button("Add Game") {
                        validationError = nil
                        showingAddGameSheet = true
                    }
                    .buttonStyle(.borderedProminent)
                }
                .frame(maxWidth: .infinity, maxHeight: .infinity)
            } else {
                if viewModel.isGridView {
                    ScrollView {
                        LazyVGrid(columns: [GridItem(.adaptive(minimum: 220, maximum: 280), spacing: 20)], spacing: 20) {
                            ForEach(viewModel.filteredGames) { game in
                                GameCardView(viewModel: viewModel, game: game)
                            }
                        }
                        .padding(20)
                    }
                } else {
                    List(viewModel.filteredGames) { game in
                        GameListRowView(viewModel: viewModel, game: game)
                    }
                }
            }
        }
        .sheet(isPresented: $showingAddGameSheet) {
            addGameSheet
        }
    }

    private var addGameSheet: some View {
        VStack(alignment: .leading, spacing: 16) {
            Text("Add Game Shortcut")
                .font(.headline)

            TextField("Game Name", text: $newGameName)
                .textFieldStyle(.roundedBorder)

            if viewModel.bottles.isEmpty {
                Text("Please create a bottle first.")
                    .foregroundColor(.red)
                    .font(.caption)
            } else {
                Picker("Target Bottle", selection: $newGameBottleID) {
                    Text("Select a bottle...").tag(nil as BottleID?)
                    ForEach(viewModel.bottles) { bottle in
                        Text(bottle.name).tag(bottle.id as BottleID?)
                    }
                }
            }

            VStack(alignment: .leading, spacing: 6) {
                Text("Windows Executable (.exe)")
                    .font(.caption)
                    .foregroundColor(.secondary)
                HStack {
                    TextField("Relative path (e.g. drive_c/game.exe)", text: $newGameExecutable)
                        .textFieldStyle(.roundedBorder)
                    Button("Browse...") {
                        let panel = NSOpenPanel()
                        panel.allowedContentTypes = []
                        panel.canChooseFiles = true
                        panel.canChooseDirectories = false
                        panel.allowsMultipleSelection = false
                        if let selectedBottle = viewModel.bottles.first(where: { $0.id == (newGameBottleID ?? viewModel.bottles.first?.id) }) {
                            panel.directoryURL = URL(fileURLWithPath: selectedBottle.directoryPath)
                        }
                        if panel.runModal() == .OK, let url = panel.url {
                            if let selectedBottle = viewModel.bottles.first(where: { $0.id == (newGameBottleID ?? viewModel.bottles.first?.id) }) {
                                let prefixPath = selectedBottle.directoryPath
                                if url.path.hasPrefix(prefixPath) {
                                    var rel = String(url.path.dropFirst(prefixPath.count))
                                    if rel.hasPrefix("/") { rel.removeFirst() }
                                    newGameExecutable = rel
                                } else {
                                    newGameExecutable = url.path
                                }
                            }
                        }
                    }
                }
            }

            if let err = validationError {
                Text(err)
                    .font(.caption)
                    .foregroundColor(.red)
            }

            HStack {
                Spacer()
                Button("Cancel") {
                    showingAddGameSheet = false
                }
                Button("Add") {
                    let targetBottleID = newGameBottleID ?? viewModel.bottles.first?.id
                    guard let bottleID = targetBottleID else {
                        validationError = "Please select a bottle."
                        return
                    }
                    guard !newGameExecutable.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
                        validationError = "Executable path cannot be empty."
                        return
                    }

                    Task {
                        do {
                            try await viewModel.addGame(
                                name: newGameName.isEmpty ? "New Game" : newGameName,
                                bottleID: bottleID,
                                executablePath: newGameExecutable
                            )
                            showingAddGameSheet = false
                            newGameName = ""
                            newGameExecutable = ""
                            validationError = nil
                        } catch {
                            validationError = error.localizedDescription
                        }
                    }
                }
                .buttonStyle(.borderedProminent)
                .disabled(viewModel.bottles.isEmpty)
            }
        }
        .padding()
        .frame(width: 460)
    }
}

struct GameCardView: View {
    let viewModel: AppViewModel
    let game: GameItem

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
                    Text(state.rawValue)
                        .font(.caption)
                        .foregroundColor(.secondary)
                }
            }

            HStack {
                let state = viewModel.activeSessionStates[game.id] ?? .stopped
                let isRunning = state == .running
                let isTransitioning = state == .preparing || state == .stopping

                Button {
                    Task {
                        await viewModel.toggleGameSession(game: game)
                    }
                } label: {
                    Label(isRunning ? "Stop" : "Play", systemImage: isRunning ? "stop.fill" : "play.fill")
                        .frame(maxWidth: .infinity)
                }
                .buttonStyle(.borderedProminent)
                .tint(isRunning ? .red : .accentColor)
                .disabled(isTransitioning)
            }
        }
        .padding(12)
        .background(Color(NSColor.controlBackgroundColor))
        .cornerRadius(12)
        .overlay(
            RoundedRectangle(cornerRadius: 12)
                .stroke(Color.secondary.opacity(0.2), lineWidth: 1)
        )
    }

    private func circleColor(for state: SessionState) -> Color {
        switch state {
        case .running: return .green
        case .preparing, .stopping: return .orange
        case .failed: return .red
        case .stopped: return .gray
        }
    }
}

struct GameListRowView: View {
    let viewModel: AppViewModel
    let game: GameItem

    var body: some View {
        HStack(spacing: 16) {
            Image(systemName: "gamecontroller.fill")
                .foregroundColor(.accentColor)
                .frame(width: 28, height: 28)

            VStack(alignment: .leading, spacing: 2) {
                Text(game.name)
                    .font(.body)
                    .bold()
                Text(game.executableRelativePath)
                    .font(.caption)
                    .foregroundColor(.secondary)
            }

            Spacer()

            let state = viewModel.activeSessionStates[game.id] ?? .stopped
            Text(state.rawValue)
                .font(.caption)
                .foregroundColor(.secondary)

            let isRunning = state == .running
            let isTransitioning = state == .preparing || state == .stopping

            Button(isRunning ? "Stop" : "Play") {
                Task {
                    await viewModel.toggleGameSession(game: game)
                }
            }
            .buttonStyle(.bordered)
            .tint(isRunning ? .red : .accentColor)
            .disabled(isTransitioning)
        }
        .padding(.vertical, 4)
    }
}
