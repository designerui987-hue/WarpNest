import Foundation

/// Errors that can occur during bottle lifecycle operations.
public enum BottleServiceError: Error, LocalizedError, Sendable {
    case bottleNotFound(BottleID)
    case duplicateBottleName(String)
    case runtimeNotFound(RuntimeID)
    case runtimeUnverified(RuntimeID)
    case bottleBusy(BottleID, String)
    case invalidBackupArchive(String)
    case archiveTraversalDetected(String)
    case configurationMismatch(String)
    case directoryNotEmpty(String)

    public var errorDescription: String? {
        switch self {
        case .bottleNotFound(let id):
            return "Bottle with ID '\(id)' was not found."
        case .duplicateBottleName(let name):
            return "A bottle with name '\(name)' already exists."
        case .runtimeNotFound(let id):
            return "Compatibility runtime '\(id)' was not found or is unregistered."
        case .runtimeUnverified(let id):
            return "Compatibility runtime '\(id)' has not passed executable validation on this Mac."
        case .bottleBusy(let id, let reason):
            return "Bottle '\(id)' cannot perform this operation: \(reason)"
        case .invalidBackupArchive(let reason):
            return "Backup archive is invalid: \(reason)"
        case .archiveTraversalDetected(let path):
            return "Malicious archive entry rejected (path traversal attempt): \(path)"
        case .configurationMismatch(let msg):
            return "Configuration error: \(msg)"
        case .directoryNotEmpty(let path):
            return "Directory at path is not empty: \(path)"
        }
    }
}

/// Actor managing bottle directories, serialization of per-bottle operations, and safe backup/restore.
public actor BottleService {
    private let metadataStore: MetadataStore
    private var bottles: [BottleID: Bottle] = [:]
    private var activeLocks: [BottleID: String] = [:]
    private var runtimeAdapters: [RuntimeID: any RuntimeAdapter] = [:]

    public init(metadataStore: MetadataStore) {
        self.metadataStore = metadataStore
    }

    public func registerAdapter(_ adapter: any RuntimeAdapter) {
        runtimeAdapters[adapter.descriptor.id] = adapter
    }

    public func getAdapter(for id: RuntimeID) -> (any RuntimeAdapter)? {
        runtimeAdapters[id]
    }

    public func getAllRegisteredAdapters() -> [any RuntimeAdapter] {
        Array(runtimeAdapters.values)
    }

    public func lockBottle(id: BottleID, reason: String) throws {
        if let existing = activeLocks[id] {
            throw BottleServiceError.bottleBusy(id, existing)
        }
        activeLocks[id] = reason
    }

    public func unlockBottle(id: BottleID) {
        activeLocks.removeValue(forKey: id)
    }

    public func isBottleLocked(id: BottleID) -> (isLocked: Bool, reason: String?) {
        if let r = activeLocks[id] {
            return (true, r)
        }
        return (false, nil)
    }

    public func loadBottles() async throws -> [Bottle] {
        let loaded = try await metadataStore.load([Bottle].self, from: "bottles.json", fallback: [])
        for b in loaded {
            bottles[b.id] = b
        }
        return loaded
    }

    private func persistBottles() async throws {
        let list = Array(bottles.values).sorted { $0.createdAt < $1.createdAt }
        try await metadataStore.save(list, to: "bottles.json")
    }

    /// Creates a new bottle prefix and runs initialization via the assigned runtime adapter.
    public func createBottle(
        name: String,
        runtimeID: RuntimeID,
        configuration: BottleConfiguration = BottleConfiguration(),
        logBuffer: LogRingBuffer = LogRingBuffer()
    ) async throws -> Bottle {
        let trimmedName = name.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !bottles.values.contains(where: { $0.name.caseInsensitiveCompare(trimmedName) == .orderedSame }) else {
            throw BottleServiceError.duplicateBottleName(trimmedName)
        }

        guard let adapter = runtimeAdapters[runtimeID] else {
            throw BottleServiceError.runtimeNotFound(runtimeID)
        }

        guard adapter.descriptor.isVerified else {
            throw BottleServiceError.runtimeUnverified(runtimeID)
        }

        let newID = BottleID()
        let safeFolderName = "bottle_" + newID.rawValue.uuidString
        let bottleURL = metadataStore.baseDirectory
            .appendingPathComponent("Bottles", isDirectory: true)
            .appendingPathComponent(safeFolderName, isDirectory: true)

        let bottle = Bottle(
            id: newID,
            name: trimmedName,
            runtimeID: runtimeID,
            directoryPath: bottleURL.path,
            configuration: configuration,
            createdAt: Date()
        )

        bottles[newID] = bottle
        try lockBottle(id: newID, reason: "Initializing Wine prefix")
        defer { unlockBottle(id: newID) }

        do {
            try await adapter.initializePrefix(at: bottleURL, configuration: configuration, logBuffer: logBuffer)
            // Save bottle metadata config file directly inside bottle directory
            let configURL = bottleURL.appendingPathComponent("warpnest_bottle.json")
            let enc = JSONEncoder()
            enc.outputFormatting = [.prettyPrinted]
            let configData = try enc.encode(bottle)
            try configData.write(to: configURL, options: .atomic)

            try await persistBottles()
            return bottle
        } catch {
            bottles.removeValue(forKey: newID)
            try? FileManager.default.removeItem(at: bottleURL)
            throw error
        }
    }

    /// Deletes a bottle only if it is completely idle and not running any games or active operations.
    public func deleteBottle(id: BottleID) async throws {
        guard let bottle = bottles[id] else {
            throw BottleServiceError.bottleNotFound(id)
        }
        if let lockReason = activeLocks[id] {
            throw BottleServiceError.bottleBusy(id, lockReason)
        }

        try lockBottle(id: id, reason: "Deleting bottle")
        defer { unlockBottle(id: id) }

        // Stop prefix services before wiping
        let url = URL(fileURLWithPath: bottle.directoryPath)
        if let adapter = runtimeAdapters[bottle.runtimeID] {
            try? await adapter.stopPrefix(at: url)
        }

        try? FileManager.default.removeItem(at: url)
        bottles.removeValue(forKey: id)
        try await persistBottles()
    }

    public func getBottle(id: BottleID) -> Bottle? {
        bottles[id]
    }

    public func getAllBottles() -> [Bottle] {
        Array(bottles.values).sorted { $0.name < $1.name }
    }

    /// Backs up a stopped bottle into a zip archive with verified error propagation.
    public func backupBottle(id: BottleID, destinationZipURL: URL) async throws {
        guard let bottle = bottles[id] else {
            throw BottleServiceError.bottleNotFound(id)
        }
        if let reason = activeLocks[id] {
            throw BottleServiceError.bottleBusy(id, reason)
        }

        try lockBottle(id: id, reason: "Exporting backup archive")
        defer { unlockBottle(id: id) }

        let sourceURL = URL(fileURLWithPath: bottle.directoryPath)
        guard FileManager.default.fileExists(atPath: sourceURL.path) else {
            throw BottleServiceError.bottleNotFound(id)
        }

        let parentDir = destinationZipURL.deletingLastPathComponent()
        try FileManager.default.createDirectory(at: parentDir, withIntermediateDirectories: true)
        if FileManager.default.fileExists(atPath: destinationZipURL.path) {
            try FileManager.default.removeItem(at: destinationZipURL)
        }

        // Use standard zip with symlink preservation (-y)
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/usr/bin/zip")
        process.currentDirectoryURL = sourceURL
        process.arguments = ["-r", "-y", destinationZipURL.path, "."]

        let pipe = Pipe()
        process.standardOutput = pipe
        process.standardError = pipe

        try process.run()
        process.waitUntilExit()

        guard process.terminationStatus == 0 else {
            let data = pipe.fileHandleForReading.readDataToEndOfFile()
            let errOutput = String(data: data, encoding: .utf8) ?? "Unknown zip error"
            throw BottleServiceError.invalidBackupArchive("zip failed with code \(process.terminationStatus): \(errOutput)")
        }
    }

    /// Restores a bottle from a zip archive with strict path traversal checking and symlink validation.
    public func restoreBottle(
        from zipURL: URL,
        restoredName: String,
        runtimeID: RuntimeID
    ) async throws -> Bottle {
        guard FileManager.default.fileExists(atPath: zipURL.path) else {
            throw BottleServiceError.invalidBackupArchive("Archive does not exist at \(zipURL.path)")
        }

        // 1. Inspect archive entries to ensure no path begins with / or contains ../
        let zipListProc = Process()
        zipListProc.executableURL = URL(fileURLWithPath: "/usr/bin/zipinfo")
        zipListProc.arguments = ["-1", zipURL.path]
        let listPipe = Pipe()
        zipListProc.standardOutput = listPipe
        try zipListProc.run()
        zipListProc.waitUntilExit()

        guard zipListProc.terminationStatus == 0 else {
            throw BottleServiceError.invalidBackupArchive("Unable to read archive table of contents.")
        }

        let listData = listPipe.fileHandleForReading.readDataToEndOfFile()
        let fileEntries = (String(data: listData, encoding: .utf8) ?? "").components(separatedBy: .newlines)
        for entry in fileEntries where !entry.isEmpty {
            if entry.hasPrefix("/") || entry.contains("../") || entry.contains("..\\") {
                throw BottleServiceError.archiveTraversalDetected(entry)
            }
        }

        let newID = BottleID()
        let targetURL = metadataStore.baseDirectory
            .appendingPathComponent("Bottles", isDirectory: true)
            .appendingPathComponent("bottle_" + newID.rawValue.uuidString, isDirectory: true)

        try FileManager.default.createDirectory(at: targetURL, withIntermediateDirectories: true)

        let extractProc = Process()
        extractProc.executableURL = URL(fileURLWithPath: "/usr/bin/unzip")
        extractProc.arguments = ["-q", zipURL.path, "-d", targetURL.path]

        try extractProc.run()
        extractProc.waitUntilExit()

        guard extractProc.terminationStatus == 0 else {
            try? FileManager.default.removeItem(at: targetURL)
            throw BottleServiceError.invalidBackupArchive("Extraction failed with exit code \(extractProc.terminationStatus)")
        }

        // Recover bottle configuration if included in archive, otherwise use defaults
        var recoveredConfig = BottleConfiguration()
        let archiveConfigURL = targetURL.appendingPathComponent("warpnest_bottle.json")
        if let configData = try? Data(contentsOf: archiveConfigURL),
           let savedBottle = try? JSONDecoder().decode(Bottle.self, from: configData) {
            recoveredConfig = savedBottle.configuration
        }

        let restoredBottle = Bottle(
            id: newID,
            name: restoredName,
            runtimeID: runtimeID,
            directoryPath: targetURL.path,
            configuration: recoveredConfig,
            createdAt: Date()
        )

        bottles[newID] = restoredBottle
        try await persistBottles()
        return restoredBottle
    }
}
