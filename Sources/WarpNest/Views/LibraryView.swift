import SwiftUI
import WarpNestCore

struct LibraryView: View {
    @Bindable var viewModel: AppViewModel
    @State private var showingAddGameSheet = false
    @State private var newGameName = ""
    @State private var newGameBottleID: BottleID?
    @State private var newGameExecutable = "drive_c/Program Files/Game/game.exe"

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
                    Text("Create a bottle and add a Windows executable or installer to get started.")
                        .foregroundColor(.secondary)
                    Button("Add Your First Game") {
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
                Text("Please create at least one bottle before adding games.")
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

            TextField("Executable Path (e.g. drive_c/game.exe)", text: $newGameExecutable)
                .textFieldStyle(.roundedBorder)

            HStack {
                Spacer()
                Button("Cancel") {
                    showingAddGameSheet = false
                }
                Button("Add") {
                    if let bottleID = newGameBottleID ?? viewModel.bottles.first?.id {
                        Task {
                            try? await viewModel.addGame(
                                name: newGameName.isEmpty ? "New Game" : newGameName,
                                bottleID: bottleID,
                                executablePath: newGameExecutable
                            )
                            showingAddGameSheet = false
                            newGameName = ""
                        }
                    }
                }
                .buttonStyle(.borderedProminent)
                .disabled(viewModel.bottles.isEmpty)
            }
        }
        .padding()
        .frame(width: 440)
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
                        .fill(state == .running ? Color.green : Color.gray)
                        .frame(width: 8, height: 8)
                    Text(state.rawValue)
                        .font(.caption)
                        .foregroundColor(.secondary)
                }
            }

            HStack {
                let isRunning = (viewModel.activeSessionStates[game.id] ?? .stopped) == .running
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
            Button(isRunning ? "Stop" : "Play") {
                Task {
                    await viewModel.toggleGameSession(game: game)
                }
            }
            .buttonStyle(.bordered)
            .tint(isRunning ? .red : .accentColor)
        }
        .padding(.vertical, 4)
    }
}
