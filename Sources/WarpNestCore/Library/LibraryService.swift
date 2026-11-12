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
        }
    }
}

/// Active running game session tracking model.
public struct ActiveSession: Sendable {
    public let gameID: GameID
    public let bottleID: BottleID
    public let supervisor: ProcessSupervisor
    public let startedAt: Date

    public init(gameID: GameID, bottleID: BottleID, supervisor: ProcessSupervisor, startedAt: Date = Date()) {
        self.gameID = gameID
        self.bottleID = bottleID
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

    public func addGame(
        name: String,
        bottleID: BottleID,
        executableRelativePath: String,
        workingDirectoryRelativePath: String? = nil,
        arguments: [String] = [],
        environmentOverrides: [String: String] = [:]
    ) async throws -> GameItem {
        guard let bottle = await bottleService.getBottle(id: bottleID) else {
            throw LibraryServiceError.bottleNotFound(bottleID)
        }

        // Validate executable file existence inside bottle prefix
        let bottleURL = URL(fileURLWithPath: bottle.directoryPath)
        let fullExeURL = bottleURL.appendingPathComponent(executableRelativePath)
        guard FileManager.default.fileExists(atPath: fullExeURL.path) else {
            throw LibraryServiceError.executableNotFound(fullExeURL.path)
        }

        let newGame = GameItem(
            name: name.trimmingCharacters(in: .whitespacesAndNewlines),
            bottleID: bottleID,
            executableRelativePath: executableRelativePath,
            workingDirectoryRelativePath: workingDirectoryRelativePath,
            arguments: arguments,
            environmentOverrides: environmentOverrides
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

        // Lock bottle for this active running game session!
        do {
            try await bottleService.lockBottle(id: game.bottleID, reason: "Game session '\(game.name)' is running")
        } catch {
            throw LibraryServiceError.bottleBusy(game.bottleID, "Bottle is currently locked by another operation")
        }

        notifyStateChange(for: id, state: .preparing)
        let buffer = getLogBuffer(for: id)
        buffer.append("[LAUNCH] Starting launch sequence for '\(game.name)' in bottle '\(bottle.name)'...")

        let bottleURL = URL(fileURLWithPath: bottle.directoryPath)
        let execPlan = try adapter.buildExecutionPlan(
            prefixURL: bottleURL,
            executablePath: game.executableRelativePath,
            arguments: game.arguments,
            configuration: bottle.configuration
        )

        // Resolve working directory: user override, or folder containing executable, or drive_c
        let resolvedWorkingDir: URL
        if let customWorkingRel = game.workingDirectoryRelativePath, !customWorkingRel.isEmpty {
            resolvedWorkingDir = bottleURL.appendingPathComponent(customWorkingRel)
        } else {
            let exeURL = bottleURL.appendingPathComponent(game.executableRelativePath)
            resolvedWorkingDir = exeURL.deletingLastPathComponent()
        }

        let supervisor = ProcessSupervisor(logBuffer: buffer)
        let session = ActiveSession(gameID: id, bottleID: game.bottleID, supervisor: supervisor)
        activeSessions[id] = session

        var env = execPlan.environment
        for (k, v) in game.environmentOverrides {
            env[k] = v
        }

        Task { [weak self] in
            do {
                await self?.notifyStateChange(for: id, state: .running)
                let status = try await supervisor.launch(
                    executableURL: execPlan.executableURL,
                    arguments: execPlan.arguments,
                    workingDirectory: resolvedWorkingDir,
                    environment: env
                )
                await self?.handleGameExit(id: id, status: status)
            } catch {
                buffer.append("[LAUNCH ERROR] \(error.localizedDescription)")
                await self?.notifyStateChange(for: id, state: .failed)
                await self?.handleGameExit(id: id, status: ProcessExitStatus(exitCode: -1))
            }
        }

        // Update last played timestamp
        var updated = game
        updated.lastPlayedAt = Date()
        games[id] = updated
        try? await persistGames()
    }

    private func handleGameExit(id: GameID, status: ProcessExitStatus) async {
        if let session = activeSessions[id] {
            let duration = Date().timeIntervalSince(session.startedAt)
            if var game = games[id] {
                game.totalPlayTimeSeconds += duration
                games[id] = game
                try? await persistGames()
            }
            // Unlock bottle now that the game has exited
            await bottleService.unlockBottle(id: session.bottleID)
        }
        activeSessions.removeValue(forKey: id)
        notifyStateChange(for: id, state: status.exitCode == 0 ? .stopped : .failed)
    }

    /// Stops a running game session and stops associated prefix services (wineserver -k).
    public func stopGame(id: GameID) async {
        guard let session = activeSessions[id] else { return }
        notifyStateChange(for: id, state: .stopping)
        await session.supervisor.terminate()

        if let bottle = await bottleService.getBottle(id: session.bottleID),
           let adapter = await bottleService.getAdapter(for: bottle.runtimeID) {
            let bottleURL = URL(fileURLWithPath: bottle.directoryPath)
            try? await adapter.stopPrefix(at: bottleURL)
        }

        await bottleService.unlockBottle(id: session.bottleID)
        activeSessions.removeValue(forKey: id)
        notifyStateChange(for: id, state: .stopped)
    }
}
