import Foundation

/// Errors that can occur during library operations.
public enum LibraryServiceError: Error, LocalizedError, Sendable {
    case gameNotFound(GameID)
    case bottleNotFound(BottleID)
    case duplicateGameName(String)
    case executableNotFound(String)
    case launchFailed(String)
    case alreadyRunning(GameID)
    case runtimeUnavailable(String)
    case bottleBusy(BottleID, String)
    case pathEscapesBottle(String)

    public var errorDescription: String? {
        switch self {
        case .gameNotFound(let id): return "Game shortcut '\(id)' was not found."
        case .bottleNotFound(let id): return "Referenced bottle '\(id)' was not found."
        case .duplicateGameName(let name): return "A game named '\(name)' already exists in the library."
        case .executableNotFound(let path): return "Windows executable was not found at: \(path)"
        case .launchFailed(let reason): return "Failed to launch game: \(reason)"
        case .alreadyRunning(let id): return "Game '\(id)' is already running."
        case .runtimeUnavailable(let msg): return "Runtime is unavailable: \(msg)"
        case .bottleBusy(let id, let reason): return "Bottle '\(id)' cannot start game: \(reason)"
        case .pathEscapesBottle(let path): return "Path '\(path)' escapes the bottle directory and is not permitted."
        }
    }
}

/// Active running game session tracking model with owned session and lock tokens (WN-04/WN-05).
public struct ActiveSession: Sendable {
    public let sessionID: UUID
    public let gameID: GameID
    public let bottleID: BottleID
    public let lockLease: BottleLockLease
    public let supervisor: ProcessSupervisor
    public let startedAt: Date
    public var state: SessionState
    public var isFinalized: Bool
    public var launchTask: Task<Void, Never>?
    public var pollingTask: Task<Void, Never>?

    public init(
        sessionID: UUID = UUID(),
        gameID: GameID,
        bottleID: BottleID,
        lockLease: BottleLockLease,
        supervisor: ProcessSupervisor,
        startedAt: Date = Date(),
        state: SessionState = .preparing,
        isFinalized: Bool = false,
        launchTask: Task<Void, Never>? = nil,
        pollingTask: Task<Void, Never>? = nil
    ) {
        self.sessionID = sessionID
        self.gameID = gameID
        self.bottleID = bottleID
        self.lockLease = lockLease
        self.supervisor = supervisor
        self.startedAt = startedAt
        self.state = state
        self.isFinalized = isFinalized
        self.launchTask = launchTask
        self.pollingTask = pollingTask
    }
}

/// Actor managing the collection of installed games, shortcut-bottle decoupling, and launch coordination.
public actor LibraryService {
    private let metadataStore: MetadataStore
    private let bottleService: BottleService
    private var games: [GameID: GameItem] = [:]
    private var activeSessions: [GameID: ActiveSession] = [:]
    private var sessionStates: [GameID: SessionState] = [:]
    private var logBuffers: [GameID: LogRingBuffer] = [:]
    private var stateListeners: [GameID: @Sendable (SessionState) -> Void] = [:]
    private var preSpawnHook: (@Sendable () async -> Void)?

    public init(metadataStore: MetadataStore, bottleService: BottleService) {
        self.metadataStore = metadataStore
        self.bottleService = bottleService
    }

    public func setStateListener(for id: GameID, listener: (@Sendable (SessionState) -> Void)?) {
        stateListeners[id] = listener
    }

    public func setPreSpawnHook(_ hook: (@Sendable () async -> Void)?) {
        self.preSpawnHook = hook
    }

    public func notifyStateChange(for id: GameID, state: SessionState) {
        transitionState(for: id, state: state)
    }

    private func transitionState(for id: GameID, state: SessionState) {
        sessionStates[id] = state
        if var session = activeSessions[id] {
            session.state = state
            activeSessions[id] = session
        }
        stateListeners[id]?(state)
    }

    public func loadGames() async throws -> [GameItem] {
        let loaded = try await metadataStore.load([GameItem].self, from: "library.json", fallback: [])
        for g in loaded {
            games[g.id] = g
        }
        return loaded
    }

    private func persistGames() async throws {
        let list = Array(games.values).sorted { $0.name < $1.name }
        try await metadataStore.save(list, to: "library.json")
    }

    /// Reserved Wine environment keys that LibraryService manages and must not be overridden by game or bottle config.
    private static let reservedWineEnvKeys: Set<String> = [
        "WINEPREFIX", "WINESERVER", "WINELOADER", "WINEDLLPATH", "WINEDEBUG"
    ]

    /// Resolves `relativePath` against `bottleURL`, resolves symlinks on both sides, verifies the
    /// result is contained within the bottle (WN-12 path traversal protection), and checks existence.
    /// - Returns: The absolute, symlink-resolved URL of the executable.
    /// - Throws: `LibraryServiceError.pathEscapesBottle` on containment failure,
    ///           `LibraryServiceError.executableNotFound` if the file does not exist.
    private func resolveAndValidateExecutable(relativePath: String, bottleURL: URL) throws -> URL {
        let resolvedBottle = bottleURL.resolvingSymlinksInPath()
        let rawExeURL = bottleURL.appendingPathComponent(relativePath)
        let resolvedExe = rawExeURL.resolvingSymlinksInPath()

        // Ensure the resolved exe path is inside the bottle (guards against ../../ traversal).
        let bottlePath = resolvedBottle.path.hasSuffix("/") ? resolvedBottle.path : resolvedBottle.path + "/"
        guard resolvedExe.path.hasPrefix(bottlePath) || resolvedExe.path == resolvedBottle.path else {
            throw LibraryServiceError.pathEscapesBottle(relativePath)
        }

        guard FileManager.default.fileExists(atPath: resolvedExe.path) else {
            throw LibraryServiceError.executableNotFound(resolvedExe.path)
        }

        return resolvedExe
    }

    public func addGame(
        name: String,
        bottleID: BottleID,
        executableRelativePath: String,
        workingDirectoryRelativePath: String? = nil,
        arguments: [String] = [],
        environmentOverrides: [String: String] = [:],
        isExternalExecutable: Bool = false,
        isInstaller: Bool? = nil
    ) async throws -> GameItem {
        guard let bottle = await bottleService.getBottle(id: bottleID) else {
            throw LibraryServiceError.bottleNotFound(bottleID)
        }

        let bottleURL = URL(fileURLWithPath: bottle.directoryPath)
        if isExternalExecutable {
            // Explicit external executable/installer outside bottle
            let externalURL = URL(fileURLWithPath: executableRelativePath).resolvingSymlinksInPath()
            guard FileManager.default.fileExists(atPath: externalURL.path) else {
                throw LibraryServiceError.executableNotFound(externalURL.path)
            }
        } else {
            // Validate executable file existence inside bottle prefix, with path containment check (WN-12).
            _ = try resolveAndValidateExecutable(relativePath: executableRelativePath, bottleURL: bottleURL)
        }

        let defaultIsInstaller: Bool
        if let explicit = isInstaller {
            defaultIsInstaller = explicit
        } else {
            let lowerName = name.lowercased()
            let lowerExe = executableRelativePath.lowercased()
            defaultIsInstaller = isExternalExecutable && (
                lowerName.contains("installer") ||
                lowerName.contains("setup") ||
                lowerExe.contains("setup.exe") ||
                lowerExe.contains("steamsetup")
            )
        }

        let newGame = GameItem(
            name: name.trimmingCharacters(in: .whitespacesAndNewlines),
            bottleID: bottleID,
            executableRelativePath: executableRelativePath,
            workingDirectoryRelativePath: workingDirectoryRelativePath,
            arguments: arguments,
            environmentOverrides: environmentOverrides,
            isExternalExecutable: isExternalExecutable,
            isInstaller: defaultIsInstaller
        )

        games[newGame.id] = newGame
        try await persistGames()
        return newGame
    }

    /// Locates an installed executable (such as Steam.exe) inside the bottle containing the specified game/installer.
    public func locateInstalledExecutable(named name: String = "Steam.exe", for gameID: GameID) async -> String? {
        guard let game = games[gameID] else { return nil }
        return await bottleService.locateInstalledExecutable(named: name, in: game.bottleID)
    }

    /// Updates a game item's executable target, e.g. when handing off from an installer to an installed application.
    @discardableResult
    public func updateGameTarget(
        id: GameID,
        newExecutableRelativePath: String,
        isExternal: Bool = false,
        newName: String? = nil,
        isInstaller: Bool = false,
        newArguments: [String]? = nil
    ) async throws -> GameItem {
        guard var game = games[id] else {
            throw LibraryServiceError.gameNotFound(id)
        }
        guard let bottle = await bottleService.getBottle(id: game.bottleID) else {
            throw LibraryServiceError.bottleNotFound(game.bottleID)
        }

        let bottleURL = URL(fileURLWithPath: bottle.directoryPath)
        if !isExternal {
            // Validate that the target exists inside the bottle
            _ = try resolveAndValidateExecutable(relativePath: newExecutableRelativePath, bottleURL: bottleURL)
        } else {
            let externalURL = URL(fileURLWithPath: newExecutableRelativePath).resolvingSymlinksInPath()
            guard FileManager.default.fileExists(atPath: externalURL.path) else {
                throw LibraryServiceError.executableNotFound(externalURL.path)
            }
        }

        game.executableRelativePath = newExecutableRelativePath
        game.isExternalExecutable = isExternal
        game.isInstaller = isInstaller
        if let newName = newName, !newName.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
            game.name = newName.trimmingCharacters(in: .whitespacesAndNewlines)
        }
        game.workingDirectoryRelativePath = nil

        if let args = newArguments {
            game.arguments = args
        } else if !isInstaller {
            // When converting installer to app, strip installer flags (/S)
            // If Steam, apply default Wine CEF hardware-acceleration bypass flags
            if newExecutableRelativePath.localizedCaseInsensitiveContains("steam.exe") {
                game.arguments = ["-cef-disable-gpu", "-cef-disable-gpu-compositing", "-no-cef-sandbox"]
            } else {
                game.arguments = []
            }
        }

        games[id] = game
        try await persistGames()
        return game
    }

    public func updateGameArguments(id: GameID, arguments: [String]) async throws {
        guard var game = games[id] else {
            throw LibraryServiceError.gameNotFound(id)
        }
        game.arguments = arguments
        games[id] = game
        try await persistGames()
    }

    /// Removes a game shortcut from the library without deleting the underlying bottle or files.
    public func removeGame(id: GameID) async throws {
        guard games[id] != nil else {
            throw LibraryServiceError.gameNotFound(id)
        }
        if activeSessions[id] != nil {
            await stopGame(id: id)
        }
        games.removeValue(forKey: id)
        logBuffers.removeValue(forKey: id)
        stateListeners.removeValue(forKey: id)
        sessionStates.removeValue(forKey: id)
        try await persistGames()
    }

    public func getGame(id: GameID) -> GameItem? {
        games[id]
    }

    public func getAllGames() -> [GameItem] {
        Array(games.values).sorted { $0.name < $1.name }
    }

    public func getSessionState(for id: GameID) async -> SessionState {
        return sessionStates[id] ?? .stopped
    }

    public func getLogBuffer(for id: GameID) -> LogRingBuffer {
        if let existing = logBuffers[id] {
            return existing
        }
        let buffer = LogRingBuffer()
        logBuffers[id] = buffer
        return buffer
    }

    /// Launches a game with supervised process execution and bounded log streaming.
    public func launchGame(id: GameID) async throws {
        guard let game = games[id] else {
            throw LibraryServiceError.gameNotFound(id)
        }
        let currentState = sessionStates[id] ?? .stopped
        guard currentState == .stopped || currentState == .failed else {
            throw LibraryServiceError.alreadyRunning(id)
        }
        guard let bottle = await bottleService.getBottle(id: game.bottleID) else {
            transitionState(for: id, state: .failed)
            throw LibraryServiceError.bottleNotFound(game.bottleID)
        }
        guard let adapter = await bottleService.getAdapter(for: bottle.runtimeID) else {
            transitionState(for: id, state: .failed)
            throw LibraryServiceError.runtimeUnavailable("Runtime adapter not registered for \(bottle.runtimeID)")
        }
        guard adapter.descriptor.isVerified else {
            transitionState(for: id, state: .failed)
            throw LibraryServiceError.runtimeUnavailable("Runtime '\(adapter.descriptor.name)' is unverified or failed validation.")
        }

        transitionState(for: id, state: .preparing)
        let buffer = getLogBuffer(for: id)
        buffer.append("[LAUNCH] Starting launch sequence for '\(game.name)' in bottle '\(bottle.name)'...")

        let bottleURL = URL(fileURLWithPath: bottle.directoryPath)

        // WN-01/WN-12: resolve absolute executable path and validate containment before passing to adapter.
        let resolvedExeURL: URL
        if game.isExternalExecutable {
            let externalURL = URL(fileURLWithPath: game.executableRelativePath).resolvingSymlinksInPath()
            guard FileManager.default.fileExists(atPath: externalURL.path) else {
                transitionState(for: id, state: .failed)
                throw LibraryServiceError.executableNotFound(externalURL.path)
            }
            resolvedExeURL = externalURL
        } else {
            do {
                resolvedExeURL = try resolveAndValidateExecutable(
                    relativePath: game.executableRelativePath,
                    bottleURL: bottleURL
                )
            } catch {
                transitionState(for: id, state: .failed)
                throw error
            }
        }

        let execPlan: (executableURL: URL, arguments: [String], environment: [String: String])
        do {
            execPlan = try adapter.buildExecutionPlan(
                prefixURL: bottleURL,
                executablePath: resolvedExeURL.path,
                arguments: game.arguments,
                configuration: bottle.configuration
            )
        } catch {
            transitionState(for: id, state: .failed)
            throw error
        }

        // Lock bottle exclusively for this active game session (WN-05)
        let lockLease: BottleLockLease
        do {
            lockLease = try await bottleService.acquireLock(
                id: game.bottleID,
                reason: "Game session '\(game.name)' is running"
            )
        } catch {
            transitionState(for: id, state: .failed)
            throw LibraryServiceError.bottleBusy(game.bottleID, "Bottle is currently locked by another operation")
        }

        // Resolve working directory: user override, or folder containing the (absolute) executable.
        let resolvedWorkingDir: URL
        if let customWorkingRel = game.workingDirectoryRelativePath, !customWorkingRel.isEmpty {
            resolvedWorkingDir = bottleURL.appendingPathComponent(customWorkingRel)
        } else {
            resolvedWorkingDir = resolvedExeURL.deletingLastPathComponent()
        }

        let sessionID = UUID()
        let supervisor = ProcessSupervisor(logBuffer: buffer)
        var session = ActiveSession(
            sessionID: sessionID,
            gameID: id,
            bottleID: game.bottleID,
            lockLease: lockLease,
            supervisor: supervisor,
            state: .preparing
        )

        var env = execPlan.environment
        // WN-12: strip reserved Wine env keys from game overrides to prevent WINEPREFIX hijacking.
        for (k, v) in game.environmentOverrides where !LibraryService.reservedWineEnvKeys.contains(k) {
            env[k] = v
        }

        let launchTask = Task { [weak self] in
            guard !Task.isCancelled else { return }
            if let hook = await self?.preSpawnHook {
                await hook()
            }
            guard !Task.isCancelled else { return }
            guard let self = self, await self.verifySessionActive(id: id, sessionID: sessionID) else { return }
            do {
                let status = try await supervisor.launch(
                    executableURL: execPlan.executableURL,
                    arguments: execPlan.arguments,
                    workingDirectory: resolvedWorkingDir,
                    environment: env,
                    onSpawn: { [weak self] _ in
                        Task { [weak self] in
                            guard let self = self else { return }
                            if await self.verifySessionActive(id: id, sessionID: sessionID) {
                                await self.transitionState(for: id, state: .running)
                            }
                        }
                    }
                )
                await self.handleGameExit(sessionID: sessionID, id: id, status: status)
            } catch {
                buffer.append("[LAUNCH ERROR] \(error.localizedDescription)")
                await self.handleLaunchFailure(sessionID: sessionID, id: id, error: error)
            }
        }

        session.launchTask = launchTask
        activeSessions[id] = session

        // Update last played timestamp
        var updated = game
        updated.lastPlayedAt = Date()
        games[id] = updated
        try? await persistGames()
    }

    private func verifySessionActive(id: GameID, sessionID: UUID) -> Bool {
        guard let s = activeSessions[id], s.sessionID == sessionID, !s.isFinalized else { return false }
        return s.state != .stopping && s.state != .stopped
    }

    private func handleLaunchFailure(sessionID: UUID, id: GameID, error: Error) async {
        guard let session = activeSessions[id], session.sessionID == sessionID, !session.isFinalized else {
            return
        }
        _ = await bottleService.releaseLock(lease: session.lockLease)
        activeSessions.removeValue(forKey: id)
        transitionState(for: id, state: .failed)
    }

    private func handleGameExit(sessionID: UUID, id: GameID, status: ProcessExitStatus) async {
        // WN-05: Ensure this completion corresponds to the active session, guarding against obsolete callbacks
        guard let session = activeSessions[id], session.sessionID == sessionID, !session.isFinalized else {
            return
        }

        // Do not equate termination of the original launcher with termination of the game (Phase 1B).
        // If wineserver or child processes are still running in this prefix, preserve the active session and lock.
        if let bottle = await bottleService.getBottle(id: session.bottleID),
           let adapter = await bottleService.getAdapter(for: bottle.runtimeID) {
            let bottleURL = URL(fileURLWithPath: bottle.directoryPath)
            if await adapter.isPrefixRunning(at: bottleURL) {
                let buffer = getLogBuffer(for: id)
                buffer.append("[SESSION] Launcher exited (status \(status.exitCode)), but prefix child processes are active. Preserving session lock...")
                
                let pollingTask = Task { [weak self] in
                    while !Task.isCancelled {
                        try? await Task.sleep(nanoseconds: 200_000_000)
                        guard self != nil else { return }
                        let isStillRunning = await adapter.isPrefixRunning(at: bottleURL)
                        if !isStillRunning {
                            break
                        }
                    }
                    if !Task.isCancelled {
                        await self?.finalizeGameSession(sessionID: sessionID, id: id, status: status)
                    }
                }
                
                var updatedSession = session
                updatedSession.pollingTask = pollingTask
                activeSessions[id] = updatedSession
                return
            }
        }

        await finalizeGameSession(sessionID: sessionID, id: id, status: status)
    }

    private func finalizeGameSession(sessionID: UUID, id: GameID, status: ProcessExitStatus) async {
        guard var session = activeSessions[id], session.sessionID == sessionID, !session.isFinalized else {
            return
        }
        session.isFinalized = true
        activeSessions[id] = session

        let duration = Date().timeIntervalSince(session.startedAt)
        if var game = games[id] {
            game.totalPlayTimeSeconds += duration
            games[id] = game
            try? await persistGames()
        }

        // Unlock bottle with matching lease token
        _ = await bottleService.releaseLock(lease: session.lockLease)
        activeSessions.removeValue(forKey: id)
        transitionState(for: id, state: (status.exitCode == 0 || status.wasCancelled) ? .stopped : .failed)
    }

    /// Stops a running game session and stops associated prefix services (wineserver -k).
    public func stopGame(id: GameID) async {
        guard let session = activeSessions[id], !session.isFinalized else { return }
        let sessionID = session.sessionID

        // Cancel pending launch or polling tasks immediately
        session.launchTask?.cancel()
        session.pollingTask?.cancel()

        transitionState(for: id, state: .stopping)

        // If the process was still in preparation (not yet spawned), abort and release lock cleanly
        let isSuperRunning = await session.supervisor.isRunning
        if session.state == .preparing && !isSuperRunning {
            await session.supervisor.terminate()
            _ = await bottleService.releaseLock(lease: session.lockLease)
            activeSessions.removeValue(forKey: id)
            transitionState(for: id, state: .stopped)
            return
        }

        await session.supervisor.terminate()

        // Bounded verification that the direct process stopped
        let procStopped = await session.supervisor.waitForExit(timeoutSeconds: 5.0)

        // Bounded stop and verification of prefix services
        var prefixStopped = true
        if let bottle = await bottleService.getBottle(id: session.bottleID),
           let adapter = await bottleService.getAdapter(for: bottle.runtimeID) {
            let bottleURL = URL(fileURLWithPath: bottle.directoryPath)
            do {
                try await adapter.stopPrefix(at: bottleURL)
            } catch {
                prefixStopped = false
            }
            let deadline = Date().addingTimeInterval(5.0)
            while await adapter.isPrefixRunning(at: bottleURL) && Date() < deadline {
                try? await Task.sleep(nanoseconds: 100_000_000)
            }
            if await adapter.isPrefixRunning(at: bottleURL) {
                prefixStopped = false
            }
        }

        // WN-05: Ensure session is still matching and not previously finalized
        guard let current = activeSessions[id], current.sessionID == sessionID, !current.isFinalized else {
            if sessionStates[id] == .stopping {
                transitionState(for: id, state: .stopped)
            }
            return
        }

        if procStopped && prefixStopped {
            await finalizeGameSession(sessionID: sessionID, id: id, status: ProcessExitStatus(exitCode: 0, wasCancelled: true))
        } else {
            // Failure or unknown shutdown status: PRESERVE session and bottle lock for recovery!
            let buffer = getLogBuffer(for: id)
            buffer.append("[STOP ERROR] Shutdown could not be confirmed (procStopped=\(procStopped), prefixStopped=\(prefixStopped)). Session lock retained.")
            transitionState(for: id, state: .stopFailed)
        }
    }
}
