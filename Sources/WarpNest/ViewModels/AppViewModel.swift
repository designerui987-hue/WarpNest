import SwiftUI
import WarpNestCore

@Observable
@MainActor
public final class AppViewModel {
    public var selectedTab: SidebarSection = .library
    public var games: [GameItem] = []
    public var bottles: [Bottle] = []
    public var registeredRuntimes: [RuntimeDescriptor] = []
    public var selectedGameID: GameID?
    public var selectedBottleID: BottleID?
    public var searchQuery: String = ""
    public var isGridView: Bool = true
    public var activeSessionStates: [GameID: SessionState] = [:]
    public var diagnostics: SystemDiagnostics?
    public var liveLogs: [String] = []
    public var appSettings: AppSettings = AppSettings()
    public var errorMessage: String?
    public var showingErrorAlert: Bool = false

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
        // Load persisted settings
        if let settings = try? await metadataStore.load(AppSettings.self, from: "settings.json", fallback: AppSettings()) {
            self.appSettings = settings
        }

        // Only register simulated test engine if developer mode is explicitly enabled
        if appSettings.developerModeEnabled {
            let testAdapter = TestRuntimeAdapter()
            await bottleService.registerAdapter(testAdapter)
        }

        // Discover and validate real Wine runtimes
        await discoverAndValidateRuntimes()

        diagnostics = diagnosticsService.gatherDiagnostics()
        await reloadData()
    }

    public func saveSettings() async {
        try? await metadataStore.save(appSettings, to: "settings.json")
    }

    public func discoverAndValidateRuntimes() async {
        let candidatePaths = [
            "/Applications/Wine Staging.app",
            "/Applications/Wine Devel.app",
            "/Applications/Wine Stable.app",
            "/usr/local",
            "/opt/homebrew"
        ]

        for path in candidatePaths {
            let url = URL(fileURLWithPath: path)
            if let adapter = try? WineRuntimeAdapter(rootDirectory: url) {
                // Actually validate via wine --version!
                if let isValid = try? await adapter.validate(), isValid {
                    var verifiedAdapter = adapter
                    if let version = await adapter.queryVersion() {
                        verifiedAdapter.descriptor.version = version
                    }
                    verifiedAdapter.descriptor.isVerified = true
                    await bottleService.registerAdapter(verifiedAdapter)
                }
            }
        }
        await updateRegisteredRuntimes()
    }

    public func importRuntime(from url: URL) async throws {
        do {
            let adapter = try WineRuntimeAdapter(rootDirectory: url)
            guard try await adapter.validate() else {
                throw RuntimeAdapterError.runtimeValidationFailed("The binary at \(url.path) failed executable validation or could not run.")
            }
            var verifiedAdapter = adapter
            if let version = await adapter.queryVersion() {
                verifiedAdapter.descriptor.version = version
            }
            verifiedAdapter.descriptor.isVerified = true
            await bottleService.registerAdapter(verifiedAdapter)
            await updateRegisteredRuntimes()
        } catch {
            showError("Failed to import runtime: \(error.localizedDescription)")
            throw error
        }
    }

    private func updateRegisteredRuntimes() async {
        let adapters = await bottleService.getAllRegisteredAdapters()
        self.registeredRuntimes = adapters.map { $0.descriptor }
    }

    public func reloadData() async {
        do {
            bottles = try await bottleService.loadBottles()
            games = try await libraryService.loadGames()
            await updateRegisteredRuntimes()

            for game in games {
                let state = await libraryService.getSessionState(for: game.id)
                activeSessionStates[game.id] = state

                // Attach state event listener
                await libraryService.setStateListener(for: game.id) { [weak self] newState in
                    Task { @MainActor [weak self] in
                        self?.activeSessionStates[game.id] = newState
                        if let gid = self?.selectedGameID, gid == game.id {
                            await self?.updateLogs(for: game.id)
                        }
                    }
                }
            }
        } catch {
            showError("Error loading library data: \(error.localizedDescription)")
        }
    }

    public var filteredGames: [GameItem] {
        if searchQuery.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
            return games
        }
        return games.filter { $0.name.localizedCaseInsensitiveContains(searchQuery) }
    }

    public func createBottle(name: String, runtimeID: RuntimeID, configuration: BottleConfiguration) async throws {
        do {
            _ = try await bottleService.createBottle(name: name, runtimeID: runtimeID, configuration: configuration)
            await reloadData()
        } catch {
            showError("Failed to create bottle: \(error.localizedDescription)")
            throw error
        }
    }

    public func addGame(name: String, bottleID: BottleID, executablePath: String) async throws {
        do {
            _ = try await libraryService.addGame(name: name, bottleID: bottleID, executableRelativePath: executablePath)
            await reloadData()
        } catch {
            showError("Failed to add game: \(error.localizedDescription)")
            throw error
        }
    }

    public func toggleGameSession(game: GameItem) async {
        let currentState = activeSessionStates[game.id] ?? .stopped
        if currentState == .running {
            activeSessionStates[game.id] = .stopping
            await libraryService.stopGame(id: game.id)
            activeSessionStates[game.id] = .stopped
        } else {
            activeSessionStates[game.id] = .preparing
            do {
                try await libraryService.launchGame(id: game.id)
                activeSessionStates[game.id] = .running
            } catch {
                activeSessionStates[game.id] = .failed
                showError("Launch error: \(error.localizedDescription)")
            }
        }
        await updateLogs(for: game.id)
    }

    public func updateLogs(for gameID: GameID) async {
        let buffer = await libraryService.getLogBuffer(for: gameID)
        liveLogs = buffer.getAllLines()
    }

    public func showError(_ message: String) {
        self.errorMessage = message
        self.showingErrorAlert = true
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
