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
    public var appSettings: AppSettings = AppSettings()
    public var errorMessage: String?
    public var showingErrorAlert: Bool = false
    public var pendingInstallerHandoff: InstallerHandoff? = nil
    public var failedInstallerGameID: GameID? = nil
    public var isInstallingSteam: Bool = false
    public var steamInstallProgress: Double = 0.0
    public var steamInstallBytesReceived: Int64 = 0
    public var steamInstallTotalBytes: Int64 = 0
    public var steamInstallStatus: String = ""
    public var steamInstallError: String? = nil
    public var showingSteamInstallSheet: Bool = false
    public var discoveredSteamGames: [DiscoveredSteamGame] = []
    public var showingSteamDiscoverySheet: Bool = false
    private var steamInstallTask: Task<Void, Never>? = nil

    public struct InstallerHandoff: Identifiable, Sendable, Equatable {
        public let id: GameID
        public let gameName: String
        public let bottleID: BottleID
        public let detectedExecutablePath: String
        public let detectedExecutableName: String

        public init(id: GameID, gameName: String, bottleID: BottleID, detectedExecutablePath: String, detectedExecutableName: String = "Steam.exe") {
            self.id = id
            self.gameName = gameName
            self.bottleID = bottleID
            self.detectedExecutablePath = detectedExecutablePath
            self.detectedExecutableName = detectedExecutableName
        }
    }

    public let metadataStore: MetadataStore
    public let bottleService: BottleService
    public let libraryService: LibraryService
    public let diagnosticsService = DiagnosticsService()
    public let steamDownloader = SteamDownloaderService()
    public let steamDiscovery = SteamAppDiscoveryService()

    public init(baseDirectory: URL = MetadataStore.defaultAppSupportDirectory) {
        let store = MetadataStore(baseDirectory: baseDirectory)
        self.metadataStore = store
        let bService = BottleService(metadataStore: store)
        self.bottleService = bService
        self.libraryService = LibraryService(metadataStore: store, bottleService: bService)
    }

    private var startupTask: Task<Void, Never>?
    public private(set) var isLoadingLibrary = true

    public func initializeApp() async {
        if let startupTask {
            await startupTask.value
            return
        }
        let task = Task { await loadInitialState() }
        startupTask = task
        await task.value
    }

    private func loadInitialState() async {
        // Load persisted settings
        if let settings = try? await metadataStore.load(AppSettings.self, from: "settings.json", fallback: AppSettings()) {
            self.appSettings = settings
        }

        await updateSimulationRuntime()
        await rehydrateAndDiscoverRuntimes()
        await reloadData()
        isLoadingLibrary = false
    }

    public func updateSimulationRuntime() async {
        let simulationID = RuntimeID.simulation
        if appSettings.developerModeEnabled {
            let testAdapter = TestRuntimeAdapter()
            await bottleService.registerAdapter(testAdapter)
        } else {
            await bottleService.unregisterAdapter(id: simulationID)
            await bottleService.unregisterAdapter(id: RuntimeID.legacySimulation)
        }

        await updateRegisteredRuntimes()
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
                        if newState == .stopped || newState == .failed {
                            if let g = self?.games.first(where: { $0.id == game.id }), g.isInstaller {
                                await self?.checkInstallerHandoff(for: game.id)
                            }
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
        isExternalExecutable: Bool = false,
        isInstaller: Bool? = nil
    ) async throws {
        do {
            _ = try await libraryService.addGame(
                name: name,
                bottleID: bottleID,
                executableRelativePath: executablePath,
                isExternalExecutable: isExternalExecutable,
                isInstaller: isInstaller
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
        if currentState == .running || currentState == .stopFailed {
            activeSessionStates[game.id] = .stopping
            await libraryService.stopGame(id: game.id)
            activeSessionStates[game.id] = await libraryService.getSessionState(for: game.id)
            if game.isInstaller {
                await checkInstallerHandoff(for: game.id)
            }
        } else {
            activeSessionStates[game.id] = .preparing
            do {
                try await libraryService.launchGame(id: game.id)
                // State transitions (.running, .failed, .stopped) are driven by the authoritative state listener (WN-10)
            } catch {
                activeSessionStates[game.id] = .failed
                showError("Launch error: \(error.localizedDescription)")
                if game.isInstaller {
                    await checkInstallerHandoff(for: game.id)
                }
            }
        }
    }

    public func checkInstallerHandoff(for gameID: GameID) async {
        guard let game = games.first(where: { $0.id == gameID }), game.isInstaller else { return }
        if let detected = await libraryService.locateInstalledExecutable(named: "Steam.exe", for: gameID) {
            self.pendingInstallerHandoff = InstallerHandoff(
                id: gameID,
                gameName: game.name,
                bottleID: game.bottleID,
                detectedExecutablePath: detected,
                detectedExecutableName: "Steam.exe"
            )
            self.failedInstallerGameID = nil
        } else {
            // Setup finished or failed and client was not found: preserve environment and offer retry or manual selection
            self.failedInstallerGameID = gameID
            self.pendingInstallerHandoff = nil
        }
    }

    public func confirmInstallerHandoff(for gameID: GameID, targetPath: String, newName: String = "Steam") async throws {
        do {
            _ = try await libraryService.updateGameTarget(
                id: gameID,
                newExecutableRelativePath: targetPath,
                isExternal: false,
                newName: newName,
                isInstaller: false
            )
            self.pendingInstallerHandoff = nil
            self.failedInstallerGameID = nil
            await reloadData()
        } catch {
            showError("Failed to set launch target: \(error.localizedDescription)")
            throw error
        }
    }

    public func cancelInstallerHandoff() {
        self.pendingInstallerHandoff = nil
    }

    public func retryInstaller(for gameID: GameID) async {
        self.failedInstallerGameID = nil
        if let game = games.first(where: { $0.id == gameID }) {
            await toggleGameSession(game: game)
        }
    }

    public func chooseInstalledAppManually(for gameID: GameID, chosenURL: URL) async throws {
        guard let game = games.first(where: { $0.id == gameID }),
              let bottle = bottles.first(where: { $0.id == game.bottleID }) else {
            throw BottleServiceError.bottleNotFound(BottleID())
        }
        let bottleURL = URL(fileURLWithPath: bottle.directoryPath).resolvingSymlinksInPath()
        let chosenResolved = chosenURL.resolvingSymlinksInPath()
        let prefixPath = bottleURL.path.hasSuffix("/") ? bottleURL.path : bottleURL.path + "/"

        guard chosenResolved.path.hasPrefix(prefixPath) else {
            showError("Selected file must be inside the bottle's drive_c directory.")
            return
        }

        let relPath = String(chosenResolved.path.dropFirst(prefixPath.count))
        let appName = chosenURL.deletingPathExtension().lastPathComponent
        try await confirmInstallerHandoff(for: gameID, targetPath: relPath, newName: appName.isEmpty ? "Steam" : appName)
    }

    public func refreshDiagnostics() async {
        let snapshot = await Task.detached(priority: .utility) { [diagnosticsService] in
            diagnosticsService.gatherDiagnostics()
        }.value
        guard !Task.isCancelled else { return }
        diagnostics = snapshot
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

    // MARK: - Steam Workflow (Phase 2)

    public func openSteamInstaller() {
        self.steamInstallError = nil
        self.steamInstallProgress = 0.0
        self.steamInstallStatus = "Ready to download and install Steam"
        self.showingSteamInstallSheet = true
    }

    public func startSteamInstall(targetBottleID: BottleID? = nil) {
        steamInstallTask?.cancel()
        steamInstallTask = Task { [weak self] in
            guard let self else { return }
            self.isInstallingSteam = true
            self.steamInstallProgress = 0.0
            self.steamInstallError = nil
            self.steamInstallStatus = "Preparing installation..."

            do {
                // 1. Resolve or create target bottle
                let bottle: Bottle
                if let targetID = targetBottleID, let found = bottles.first(where: { $0.id == targetID }) {
                    bottle = found
                } else if let existingSteamBottle = bottles.first(where: { $0.name.localizedCaseInsensitiveCompare("Steam") == .orderedSame }) {
                    bottle = existingSteamBottle
                } else {
                    self.steamInstallStatus = "Creating dedicated Steam bottle..."
                    let validRuntimes = registeredRuntimes.filter {
                        $0.isVerified && (!$0.isSimulation || appSettings.developerModeEnabled)
                    }
                    guard let runtime = validRuntimes.first else {
                        throw BottleServiceError.runtimeNotFound(RuntimeID("default"))
                    }
                    let config = BottleConfiguration(
                        win64: true,
                        windowsVersion: "win10",
                        graphicsBackend: .automatic,
                        syncBackend: .esync
                    )
                    bottle = try await bottleService.createBottle(
                        name: "Steam",
                        runtimeID: runtime.id,
                        configuration: config
                    )
                    await reloadData()
                }

                // 2. Download official verified SteamSetup.exe
                self.steamInstallStatus = "Downloading official Steam installer..."
                let baseDir = await metadataStore.baseDirectory
                let downloadsDir = baseDir.appendingPathComponent("Downloads", isDirectory: true)
                let destinationURL = downloadsDir.appendingPathComponent("SteamSetup.exe")

                let installerURL = try await steamDownloader.downloadSteamInstaller(
                    to: destinationURL,
                    onProgress: { [weak self] received, total, fraction in
                        Task { @MainActor [weak self] in
                            guard let self else { return }
                            self.steamInstallBytesReceived = received
                            self.steamInstallTotalBytes = total
                            self.steamInstallProgress = fraction
                            if total > 0 {
                                let mbReceived = Double(received) / (1024 * 1024)
                                let mbTotal = Double(total) / (1024 * 1024)
                                self.steamInstallStatus = String(format: "Downloading Steam installer (%.1f MB / %.1f MB)...", mbReceived, mbTotal)
                            } else {
                                self.steamInstallStatus = "Downloading Steam installer..."
                            }
                        }
                    }
                )

                try Task.checkCancellation()

                // 3. Register installer shortcut in library if not already present
                self.steamInstallStatus = "Configuring Steam installer in bottle..."
                let installerGame: GameItem
                if let existing = games.first(where: { $0.bottleID == bottle.id && $0.isInstaller && $0.name == "Steam Setup" }) {
                    installerGame = existing
                } else {
                    installerGame = try await libraryService.addGame(
                        name: "Steam Setup",
                        bottleID: bottle.id,
                        executableRelativePath: installerURL.path,
                        arguments: ["/S"],
                        isExternalExecutable: true,
                        isInstaller: true
                    )
                    await reloadData()
                }

                // 4. Launch silent installer inside the prefix
                self.steamInstallStatus = "Running Steam setup..."
                self.showingSteamInstallSheet = false
                self.isInstallingSteam = false

                try await libraryService.launchGame(id: installerGame.id)
                await reloadData()

            } catch is CancellationError {
                self.isInstallingSteam = false
                self.steamInstallStatus = "Installation cancelled."
            } catch {
                self.isInstallingSteam = false
                self.steamInstallError = error.localizedDescription
                self.steamInstallStatus = "Installation failed."
            }
        }
    }

    public func cancelSteamInstall() {
        steamInstallTask?.cancel()
        steamInstallTask = nil
        isInstallingSteam = false
        steamInstallStatus = "Installation cancelled."
        showingSteamInstallSheet = false
    }

    public func discoverSteamGames(in bottleID: BottleID) async {
        guard let bottle = bottles.first(where: { $0.id == bottleID }) else { return }
        let discovered = steamDiscovery.discoverGames(in: bottle)
        self.discoveredSteamGames = discovered
        self.showingSteamDiscoverySheet = true
    }

    public func addDiscoveredGame(_ discovered: DiscoveredSteamGame) async {
        guard let relPath = discovered.relativeExecutablePath else {
            showError("Executable for '\(discovered.name)' could not be located.")
            return
        }
        do {
            _ = try await libraryService.addGame(
                name: discovered.name,
                bottleID: discovered.bottleID,
                executableRelativePath: relPath,
                isInstaller: false
            )
            await reloadData()
            self.discoveredSteamGames.removeAll(where: { $0.id == discovered.id })
            if self.discoveredSteamGames.isEmpty {
                self.showingSteamDiscoverySheet = false
            }
        } catch {
            showError("Failed to add '\(discovered.name)': \(error.localizedDescription)")
        }
    }
}

public enum SidebarSection: String, CaseIterable, Identifiable {
    case library = "Library"
    case bottles = "Environments"
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
