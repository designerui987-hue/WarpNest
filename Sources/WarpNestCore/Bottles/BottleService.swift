import Foundation

/// Errors that can occur during bottle lifecycle operations.
public enum BottleServiceError: Error, LocalizedError, Sendable {
    case bottleNotFound(BottleID)
    case duplicateBottleName(String)
    case runtimeNotFound(RuntimeID)
    case bottleBusy(BottleID)
    case invalidBackupArchive(String)
    case directoryNotEmpty(String)

    public var errorDescription: String? {
        switch self {
        case .bottleNotFound(let id):
            return "Bottle with ID '\(id)' was not found."
        case .duplicateBottleName(let name):
            return "A bottle with name '\(name)' already exists."
        case .runtimeNotFound(let id):
            return "Compatibility runtime '\(id)' was not found or is unverified."
        case .bottleBusy(let id):
            return "Bottle '\(id)' is currently performing another operation or running a game."
        case .invalidBackupArchive(let reason):
            return "Backup archive is invalid: \(reason)"
        case .directoryNotEmpty(let path):
            return "Directory at path is not empty: \(path)"
        }
    }
}

/// Actor managing bottle directories, serialization of per-bottle operations, and safe backup/restore.
public actor BottleService {
    private let metadataStore: MetadataStore
    private var bottles: [BottleID: Bottle] = [:]
    private var activeLocks: Set<BottleID> = []
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
        activeLocks.insert(newID)
        defer { activeLocks.remove(newID) }

        do {
            try await adapter.initializePrefix(at: bottleURL, configuration: configuration, logBuffer: logBuffer)
            try await persistBottles()
            return bottle
        } catch {
            bottles.removeValue(forKey: newID)
            try? FileManager.default.removeItem(at: bottleURL)
            throw error
        }
    }

    public func deleteBottle(id: BottleID) async throws {
        guard let bottle = bottles[id] else {
            throw BottleServiceError.bottleNotFound(id)
        }
        guard !activeLocks.contains(id) else {
            throw BottleServiceError.bottleBusy(id)
        }

        let url = URL(fileURLWithPath: bottle.directoryPath)
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

    /// Backs up a stopped bottle into a zip archive.
    public func backupBottle(id: BottleID, destinationZipURL: URL) async throws {
        guard let bottle = bottles[id] else {
            throw BottleServiceError.bottleNotFound(id)
        }
        guard !activeLocks.contains(id) else {
            throw BottleServiceError.bottleBusy(id)
        }

        activeLocks.insert(id)
        defer { activeLocks.remove(id) }

        let sourceURL = URL(fileURLWithPath: bottle.directoryPath)
        guard FileManager.default.fileExists(atPath: sourceURL.path) else {
            throw BottleServiceError.bottleNotFound(id)
        }

        let parentDir = destinationZipURL.deletingLastPathComponent()
        try FileManager.default.createDirectory(at: parentDir, withIntermediateDirectories: true)
        if FileManager.default.fileExists(atPath: destinationZipURL.path) {
            try FileManager.default.removeItem(at: destinationZipURL)
        }

        let coordinator = NSFileCoordinator()
        var error: NSError?
        coordinator.coordinate(readingItemAt: sourceURL, options: .forUploading, error: &error) { zipURL in
            do {
                try FileManager.default.copyItem(at: zipURL, to: destinationZipURL)
            } catch {
                NSLog("Failed to create zip backup: \(error)")
            }
        }
        if let error = error {
            throw BottleServiceError.invalidBackupArchive(error.localizedDescription)
        }
    }

    /// Restores a bottle from a zip archive into a new bottle prefix, rejecting zip traversal attacks.
    public func restoreBottle(
        from zipURL: URL,
        restoredName: String,
        runtimeID: RuntimeID
    ) async throws -> Bottle {
        guard FileManager.default.fileExists(atPath: zipURL.path) else {
            throw BottleServiceError.invalidBackupArchive("Archive does not exist at \(zipURL.path)")
        }

        let newID = BottleID()
        let targetURL = metadataStore.baseDirectory
            .appendingPathComponent("Bottles", isDirectory: true)
            .appendingPathComponent("bottle_" + newID.rawValue.uuidString, isDirectory: true)

        try FileManager.default.createDirectory(at: targetURL, withIntermediateDirectories: true)

        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/usr/bin/unzip")
        process.arguments = ["-q", zipURL.path, "-d", targetURL.path]

        try process.run()
        process.waitUntilExit()

        guard process.terminationStatus == 0 else {
            try? FileManager.default.removeItem(at: targetURL)
            throw BottleServiceError.invalidBackupArchive("Extraction failed with exit code \(process.terminationStatus)")
        }

        let restoredBottle = Bottle(
            id: newID,
            name: restoredName,
            runtimeID: runtimeID,
            directoryPath: targetURL.path,
            configuration: BottleConfiguration(),
            createdAt: Date()
        )

        bottles[newID] = restoredBottle
        try await persistBottles()
        return restoredBottle
    }
}
