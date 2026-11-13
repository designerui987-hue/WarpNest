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

    public init(
        sessionID: UUID = UUID(),
        gameID: GameID,
        bottleID: BottleID,
        lockLease: BottleLockLease,
        supervisor: ProcessSupervisor,
        startedAt: Date = Date()
    ) {
        self.sessionID = sessionID
        self.gameID = gameID
        self.bottleID = bottleID
        self.lockLease = lockLease
        self.supervisor = supervisor
        self.startedAt = startedAt
    }
}

/// Actor managing the collection of installed games, shortcut-bottle decoupling, and launch coordination.
public actor LibraryService {
    private let metadataStore: MetadataStore
    private let bottleService: BottleService
    private var games: [GameID: GameItem] = [:]
    private var activeSessions: [GameID: ActiveSession] = [:]
    private var logBuffers: [GameID: LogRingBuffer] = [:]
    private var stateListeners: [GameID: @Sendable (SessionState) -> Void] = [:]

    public init(metadataStore: MetadataStore, bottleService: BottleService) {
        self.metadataStore = metadataStore
        self.bottleService = bottleService
    }

    public func setStateListener(for id: GameID, listener: (@Sendable (SessionState) -> Void)?) {
        stateListeners[id] = listener
    }

    public func notifyStateChange(for id: GameID, state: SessionState) {
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
        isExternalExecutable: Bool = false
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

        let newGame = GameItem(
            name: name.trimmingCharacters(in: .whitespacesAndNewlines),
            bottleID: bottleID,
            executableRelativePath: executableRelativePath,
            workingDirectoryRelativePath: workingDirectoryRelativePath,
            arguments: arguments,
            environmentOverrides: environmentOverrides,
            isExternalExecutable: isExternalExecutable
        )

        games[newGame.id] = newGame
        try await persistGames()
        return newGame
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
        try await persistGames()
    }

    public func getGame(id: GameID) -> GameItem? {
        games[id]
    }

    public func getAllGames() -> [GameItem] {
        Array(games.values).sorted { $0.name < $1.name }
    }

    public func getSessionState(for id: GameID) async -> SessionState {
        guard let session = activeSessions[id] else {
            return .stopped
        }
        return await session.supervisor.isRunning ? .running : .stopped
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
        guard activeSessions[id] == nil else {
            throw LibraryServiceError.alreadyRunning(id)
        }
        guard let bottle = await bottleService.getBottle(id: game.bottleID) else {
            throw LibraryServiceError.bottleNotFound(game.bottleID)
        }
        guard let adapter = await bottleService.getAdapter(for: bottle.runtimeID) else {
            throw LibraryServiceError.runtimeUnavailable("Runtime adapter not registered for \(bottle.runtimeID)")
        }
        guard adapter.descriptor.isVerified else {
            throw LibraryServiceError.runtimeUnavailable("Runtime '\(adapter.descriptor.name)' is unverified or failed validation.")
        }

        notifyStateChange(for: id, state: .preparing)
        let buffer = getLogBuffer(for: id)
        buffer.append("[LAUNCH] Starting launch sequence for '\(game.name)' in bottle '\(bottle.name)'...")

        let bottleURL = URL(fileURLWithPath: bottle.directoryPath)

        // WN-01/WN-12: resolve absolute executable path and validate containment before passing to adapter.
        let resolvedExeURL: URL
        if game.isExternalExecutable {
            let externalURL = URL(fileURLWithPath: game.executableRelativePath).resolvingSymlinksInPath()
            guard FileManager.default.fileExists(atPath: externalURL.path) else {
                throw LibraryServiceError.executableNotFound(externalURL.path)
            }
            resolvedExeURL = externalURL
        } else {
            resolvedExeURL = try resolveAndValidateExecutable(
                relativePath: game.executableRelativePath,
                bottleURL: bottleURL
            )
        }

        let execPlan = try adapter.buildExecutionPlan(
            prefixURL: bottleURL,
            executablePath: resolvedExeURL.path,
            arguments: game.arguments,
            configuration: bottle.configuration
        )

        // Lock bottle exclusively for this active game session (WN-05)
        let lockLease: BottleLockLease
        do {
            lockLease = try await bottleService.acquireLock(
                id: game.bottleID,
                reason: "Game session '\(game.name)' is running"
            )
        } catch {
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
        let session = ActiveSession(
            sessionID: sessionID,
            gameID: id,
            bottleID: game.bottleID,
            lockLease: lockLease,
            supervisor: supervisor
        )
        activeSessions[id] = session

        var env = execPlan.environment
        // WN-12: strip reserved Wine env keys from game overrides to prevent WINEPREFIX hijacking.
        for (k, v) in game.environmentOverrides where !LibraryService.reservedWineEnvKeys.contains(k) {
            env[k] = v
        }

        Task { [weak self] in
            do {
                let status = try await supervisor.launch(
                    executableURL: execPlan.executableURL,
                    arguments: execPlan.arguments,
                    workingDirectory: resolvedWorkingDir,
                    environment: env,
                    onSpawn: { [weak self] _ in
                        Task { [weak self] in
                            // WN-10: Only emit .running once spawn actually succeeds
                            await self?.notifyStateChange(for: id, state: .running)
                        }
                    }
                )
                await self?.handleGameExit(sessionID: sessionID, id: id, status: status)
            } catch {
                buffer.append("[LAUNCH ERROR] \(error.localizedDescription)")
                await self?.notifyStateChange(for: id, state: .failed)
                await self?.handleGameExit(sessionID: sessionID, id: id, status: ProcessExitStatus(exitCode: -1))
            }
        }

        // Update last played timestamp
        var updated = game
        updated.lastPlayedAt = Date()
        games[id] = updated
        try? await persistGames()
    }

    private func handleGameExit(sessionID: UUID, id: GameID, status: ProcessExitStatus) async {
        // WN-05: Ensure this completion corresponds to the active session, guarding against obsolete callbacks
        guard let session = activeSessions[id], session.sessionID == sessionID else {
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
                Task { [weak self] in
                    while true {
                        try? await Task.sleep(nanoseconds: 1_000_000_000)
                        guard self != nil else { return }
                        let isStillRunning = await adapter.isPrefixRunning(at: bottleURL)
                        if !isStillRunning {
                            break
                        }
                    }
                    await self?.finalizeGameSession(sessionID: sessionID, id: id, status: status)
                }
                return
            }
        }

        await finalizeGameSession(sessionID: sessionID, id: id, status: status)
    }

    private func finalizeGameSession(sessionID: UUID, id: GameID, status: ProcessExitStatus) async {
        guard let session = activeSessions[id], session.sessionID == sessionID else {
            return
        }

        let duration = Date().timeIntervalSince(session.startedAt)
        if var game = games[id] {
            game.totalPlayTimeSeconds += duration
            games[id] = game
            try? await persistGames()
        }

        // Unlock bottle with matching lease token
        _ = await bottleService.releaseLock(lease: session.lockLease)
        activeSessions.removeValue(forKey: id)
        notifyStateChange(for: id, state: status.exitCode == 0 ? .stopped : .failed)
    }

    /// Stops a running game session and stops associated prefix services (wineserver -k).
    public func stopGame(id: GameID) async {
        guard let session = activeSessions[id] else { return }
        let sessionID = session.sessionID
        notifyStateChange(for: id, state: .stopping)
        await session.supervisor.terminate()

        if let bottle = await bottleService.getBottle(id: session.bottleID),
           let adapter = await bottleService.getAdapter(for: bottle.runtimeID) {
            let bottleURL = URL(fileURLWithPath: bottle.directoryPath)
            try? await adapter.stopPrefix(at: bottleURL)
        }

        // WN-05: Only unlock and clear session if it still matches the stopped session ID
        guard let current = activeSessions[id], current.sessionID == sessionID else { return }
        _ = await bottleService.releaseLock(lease: session.lockLease)
        activeSessions.removeValue(forKey: id)
        notifyStateChange(for: id, state: .stopped)
    }
}
