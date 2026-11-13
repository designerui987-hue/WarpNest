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

        // Developer mode simulation adapter handling (WN-09)
        let simulationID = RuntimeID("test-simulation")
        if appSettings.developerModeEnabled {
            let testAdapter = TestRuntimeAdapter()
            await bottleService.registerAdapter(testAdapter)
        } else {
            await bottleService.unregisterAdapter(id: simulationID)
        }

        // Rehydrate persisted runtimes, then discover new Wine runtimes (WN-03)
        await rehydrateAndDiscoverRuntimes()

        diagnostics = diagnosticsService.gatherDiagnostics()
        await reloadData()
    }

    public func saveSettings() async {
        try? await metadataStore.save(appSettings, to: "settings.json")
    }

    public func rehydrateAndDiscoverRuntimes() async {
        var persisted = (try? await metadataStore.loadRuntimeRegistry()) ?? []
        var registeredRoots = Set<String>()

        // 1. Rehydrate previously saved runtimes
        for entry in persisted {
            registeredRoots.insert(URL(fileURLWithPath: entry.rootPath).resolvingSymlinksInPath().path)
            let rootURL = URL(fileURLWithPath: entry.rootPath)

            if FileManager.default.fileExists(atPath: rootURL.path),
               let adapter = try? WineRuntimeAdapter(rootDirectory: rootURL, stableID: entry.id) {
                if let isValid = try? await adapter.validate(), isValid {
                    var verifiedAdapter = adapter
                    verifiedAdapter.descriptor.version = entry.version != "unknown" ? entry.version : (await adapter.queryVersion() ?? "unknown")
                    verifiedAdapter.descriptor.isVerified = true
                    await bottleService.registerAdapter(verifiedAdapter)
                } else {
                    var unverified = adapter
                    unverified.descriptor.isVerified = false
                    unverified.descriptor.version = "Validation Failed"
                    await bottleService.registerAdapter(unverified)
                }
            }
        }

        // 2. Discover standard candidate paths not yet registered
        let candidatePaths = [
            "/Applications/Wine Staging.app",
            "/Applications/Wine Devel.app",
            "/Applications/Wine Stable.app",
            "/usr/local",
            "/opt/homebrew"
        ]

        var newEntries: [PersistedRuntime] = []
        for path in candidatePaths {
            let url = URL(fileURLWithPath: path).resolvingSymlinksInPath()
            guard !registeredRoots.contains(url.path) else { continue }

            if let adapter = try? WineRuntimeAdapter(rootDirectory: url) {
                if let isValid = try? await adapter.validate(), isValid {
                    var verifiedAdapter = adapter
                    let ver = await adapter.queryVersion() ?? "unknown"
                    verifiedAdapter.descriptor.version = ver
                    verifiedAdapter.descriptor.isVerified = true
                    await bottleService.registerAdapter(verifiedAdapter)

                    let newPersisted = PersistedRuntime(
                        id: verifiedAdapter.descriptor.id,
                        displayName: verifiedAdapter.descriptor.name,
                        executablePath: verifiedAdapter.wineExecutableURL.path,
                        rootPath: url.path,
                        version: ver,
                        importedAt: Date(),
                        isUserImported: false
                    )
                    newEntries.append(newPersisted)
                    registeredRoots.insert(url.path)
                }
            }
        }

        if !newEntries.isEmpty {
            persisted.append(contentsOf: newEntries)
            try? await metadataStore.saveRuntimeRegistry(persisted)
        }

        await updateRegisteredRuntimes()
    }

    public func discoverAndValidateRuntimes() async {
        await rehydrateAndDiscoverRuntimes()
    }

    public func importRuntime(from url: URL) async throws {
        do {
            let canonicalURL = url.resolvingSymlinksInPath()
            var persisted = (try? await metadataStore.loadRuntimeRegistry()) ?? []
            
            // P1: Preserve existing stable runtime ID if re-importing the same canonical root
            let existingEntry = persisted.first {
                URL(fileURLWithPath: $0.rootPath).resolvingSymlinksInPath().path == canonicalURL.path
            }
            let stableID = existingEntry?.id

            let adapter = try WineRuntimeAdapter(rootDirectory: canonicalURL, stableID: stableID)
            guard try await adapter.validate() else {
                throw RuntimeAdapterError.runtimeValidationFailed("The binary at \(url.path) failed executable validation or could not run.")
            }
            var verifiedAdapter = adapter
            let ver = await adapter.queryVersion() ?? "unknown"
            verifiedAdapter.descriptor.version = ver
            verifiedAdapter.descriptor.isVerified = true
            await bottleService.registerAdapter(verifiedAdapter)

            // Persist the user-imported runtime with its stable ID (WN-03)
            persisted.removeAll { URL(fileURLWithPath: $0.rootPath).resolvingSymlinksInPath().path == canonicalURL.path }
            persisted.append(PersistedRuntime(
                id: verifiedAdapter.descriptor.id,
                displayName: verifiedAdapter.descriptor.name,
                executablePath: verifiedAdapter.wineExecutableURL.path,
                rootPath: canonicalURL.path,
                version: ver,
                importedAt: existingEntry?.importedAt ?? Date(),
                isUserImported: true
            ))
            // Propagate persistence errors honestly instead of reporting false success
            try await metadataStore.saveRuntimeRegistry(persisted)

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

    public func addGame(
        name: String,
        bottleID: BottleID,
        executablePath: String,
        isExternalExecutable: Bool = false
    ) async throws {
        do {
            _ = try await libraryService.addGame(
                name: name,
                bottleID: bottleID,
                executableRelativePath: executablePath,
                isExternalExecutable: isExternalExecutable
            )
            await reloadData()
        } catch {
            showError("Failed to add game: \(error.localizedDescription)")
            throw error
        }
    }

    public func toggleGameSession(game: GameItem) async {
        selectedGameID = game.id
        let currentState = activeSessionStates[game.id] ?? .stopped
        if currentState == .running {
            activeSessionStates[game.id] = .stopping
            await libraryService.stopGame(id: game.id)
        } else {
            activeSessionStates[game.id] = .preparing
            // Attach live log listener for active game (WN-10)
            let buffer = await libraryService.getLogBuffer(for: game.id)
            buffer.setLineHandler { [weak self] _ in
                Task { @MainActor [weak self] in
                    if self?.selectedGameID == game.id {
                        self?.liveLogs = buffer.getAllLines()
                    }
                }
            }

            do {
                try await libraryService.launchGame(id: game.id)
                // State transitions (.running, .failed, .stopped) are driven by the authoritative state listener (WN-10)
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

    public func backupBottle(id: BottleID, to destinationURL: URL) async throws {
        do {
            try await bottleService.backupBottle(id: id, destinationZipURL: destinationURL)
        } catch {
            showError("Failed to backup bottle: \(error.localizedDescription)")
            throw error
        }
    }

    public func restoreBottle(from sourceURL: URL, name: String, runtimeID: RuntimeID) async throws -> Bottle {
        do {
            let bottle = try await bottleService.restoreBottle(from: sourceURL, restoredName: name, runtimeID: runtimeID)
            await reloadData()
            return bottle
        } catch {
            showError("Failed to restore bottle: \(error.localizedDescription)")
            throw error
        }
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
