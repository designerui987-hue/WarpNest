import SwiftUI
import WarpNestCore

@Observable
@MainActor
public final class AppViewModel {
    public var selectedTab: SidebarSection = .library
    public var games: [GameItem] = []
    public var bottles: [Bottle] = []
    public var selectedGameID: GameID?
    public var selectedBottleID: BottleID?
    public var searchQuery: String = ""
    public var isGridView: Bool = true
    public var activeSessionStates: [GameID: SessionState] = [:]
    public var diagnostics: SystemDiagnostics?
    public var liveLogs: [String] = []

    public let metadataStore: MetadataStore
    public let bottleService: BottleService
    public let libraryService: LibraryService
    public let diagnosticsService = DiagnosticsService()

    public init(baseDirectory: URL = MetadataStore.defaultAppSupportDirectory) {
        let store = MetadataStore(baseDirectory: baseDirectory)
        self.metadataStore = store
        let bService = BottleService(metadataStore: store)
        self.bottleService = bService
        self.libraryService = LibraryService(metadataStore: store, bottleService: bService)
    }

    public func initializeApp() async {
        // Register default test adapter
        let testAdapter = TestRuntimeAdapter()
        await bottleService.registerAdapter(testAdapter)

        // Try detecting installed Wine in common locations
        let standardWinePaths = [
            "/usr/local/bin/wine",
            "/opt/homebrew/bin/wine",
            NSHomeDirectory() + "/Applications/Wine Staging.app/Contents/Resources/wine"
        ]
        for path in standardWinePaths {
            let root = URL(fileURLWithPath: path).deletingLastPathComponent().deletingLastPathComponent()
            if let adapter = try? WineRuntimeAdapter(rootDirectory: root) {
                await bottleService.registerAdapter(adapter)
            }
        }

        diagnostics = diagnosticsService.gatherDiagnostics()
        await reloadData()
    }

    public func reloadData() async {
        do {
            bottles = try await bottleService.loadBottles()
            games = try await libraryService.loadGames()

            for game in games {
                let state = await libraryService.getSessionState(for: game.id)
                activeSessionStates[game.id] = state
            }
        } catch {
            print("Error loading data: \(error)")
        }
    }

    public var filteredGames: [GameItem] {
        if searchQuery.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
            return games
        }
        return games.filter { $0.name.localizedCaseInsensitiveContains(searchQuery) }
    }

    public func createBottle(name: String) async throws {
        _ = try await bottleService.createBottle(name: name, runtimeID: RuntimeID("test-adapter-v1"))
        await reloadData()
    }

    public func addGame(name: String, bottleID: BottleID, executablePath: String) async throws {
        _ = try await libraryService.addGame(name: name, bottleID: bottleID, executableRelativePath: executablePath)
        await reloadData()
    }

    public func toggleGameSession(game: GameItem) async {
        let currentState = activeSessionStates[game.id] ?? .stopped
        if currentState == .running {
            await libraryService.stopGame(id: game.id)
            activeSessionStates[game.id] = .stopped
        } else {
            activeSessionStates[game.id] = .preparing
            do {
                try await libraryService.launchGame(id: game.id)
                activeSessionStates[game.id] = .running
            } catch {
                activeSessionStates[game.id] = .failed
            }
        }
        await updateLogs(for: game.id)
    }

    public func updateLogs(for gameID: GameID) async {
        let buffer = await libraryService.getLogBuffer(for: gameID)
        liveLogs = buffer.getAllLines()
    }
}

public enum SidebarSection: String, CaseIterable, Identifiable {
    case library = "Library"
    case bottles = "Bottles"
    case diagnostics = "Diagnostics"
    case settings = "Settings"

    public var id: String { rawValue }
    public var iconName: String {
        switch self {
        case .library: return "gamecontroller.fill"
        case .bottles: return "shippingbox.fill"
        case .diagnostics: return "waveform.path.ecg"
        case .settings: return "gearshape.fill"
        }
    }
}
