import Foundation

/// Errors that can occur during metadata storage operations.
public enum MetadataStoreError: Error, LocalizedError, Sendable {
    case directoryCreationFailed(String)
    case writeFailed(String)
    case readFailed(String)
    case decodingFailed(String)
    case encodingFailed(String)

    public var errorDescription: String? {
        switch self {
        case .directoryCreationFailed(let msg): return "Failed to create storage directory: \(msg)"
        case .writeFailed(let msg): return "Failed to write metadata: \(msg)"
        case .readFailed(let msg): return "Failed to read metadata: \(msg)"
        case .decodingFailed(let msg): return "Failed to decode metadata: \(msg)"
        case .encodingFailed(let msg): return "Failed to encode metadata: \(msg)"
        }
    }
}

/// Actor managing versioned, atomic JSON persistence for bottles, games, and app configuration.
public actor MetadataStore {
    public let baseDirectory: URL
    private let fileManager = FileManager.default
    private let encoder: JSONEncoder
    private let decoder: JSONDecoder

    public init(baseDirectory: URL) {
        self.baseDirectory = baseDirectory
        let enc = JSONEncoder()
        enc.outputFormatting = [.prettyPrinted, .sortedKeys]
        enc.dateEncodingStrategy = .iso8601
        self.encoder = enc

        let dec = JSONDecoder()
        dec.dateDecodingStrategy = .iso8601
        self.decoder = dec
    }

    /// Default application support directory for WarpNest.
    public static var defaultAppSupportDirectory: URL {
        if let override = ProcessInfo.processInfo.environment["WARPNEST_DATA_DIR"], !override.isEmpty {
            return URL(fileURLWithPath: override, isDirectory: true)
        }
        let appSupport = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask).first!
        return appSupport.appendingPathComponent("WarpNest", isDirectory: true)
    }

    /// Ensures the storage directory and subdirectories exist.
    public func ensureStorageStructure() throws {
        do {
            try fileManager.createDirectory(at: baseDirectory, withIntermediateDirectories: true)
            try fileManager.createDirectory(at: baseDirectory.appendingPathComponent("Bottles", isDirectory: true), withIntermediateDirectories: true)
            try fileManager.createDirectory(at: baseDirectory.appendingPathComponent("Backups", isDirectory: true), withIntermediateDirectories: true)
            try fileManager.createDirectory(at: baseDirectory.appendingPathComponent("Logs", isDirectory: true), withIntermediateDirectories: true)
        } catch {
            throw MetadataStoreError.directoryCreationFailed(error.localizedDescription)
        }
    }

    /// Atomically saves an encodable object by writing to a temporary file and moving into place.
    public func save<T: Encodable>(_ item: T, to filename: String) throws {
        try ensureStorageStructure()
        let targetURL = baseDirectory.appendingPathComponent(filename)
        let tempURL = baseDirectory.appendingPathComponent(".\(filename).tmp.\(UUID().uuidString)")

        let data: Data
        do {
            data = try encoder.encode(item)
        } catch {
            throw MetadataStoreError.encodingFailed(error.localizedDescription)
        }

        do {
            try data.write(to: tempURL, options: .atomic)
            if fileManager.fileExists(atPath: targetURL.path) {
                _ = try fileManager.replaceItemAt(targetURL, withItemAt: tempURL)
            } else {
                try fileManager.moveItem(at: tempURL, to: targetURL)
            }
        } catch {
            try? fileManager.removeItem(at: tempURL)
            throw MetadataStoreError.writeFailed(error.localizedDescription)
        }
    }

    /// Loads a decodable object from a file, returning default fallback if the file does not exist yet.
    public func load<T: Decodable>(_ type: T.Type, from filename: String, fallback: T) throws -> T {
        let fileURL = baseDirectory.appendingPathComponent(filename)
        guard fileManager.fileExists(atPath: fileURL.path) else {
            return fallback
        }

        do {
            let data = try Data(contentsOf: fileURL)
            return try decoder.decode(type, from: data)
        } catch {
            // WN-15 / N26: preserve corrupt data for recovery before failing
            let formatter = ISO8601DateFormatter()
            formatter.formatOptions = [.withInternetDateTime]
            let corruptBackupURL = baseDirectory.appendingPathComponent(filename + ".corrupt." + formatter.string(from: Date()))
            try? fileManager.copyItem(at: fileURL, to: corruptBackupURL)
            throw MetadataStoreError.decodingFailed(error.localizedDescription)
        }
    }

    // MARK: - Runtime Registry

    private static let runtimeRegistryFilename = "runtimes.json"

    /// Persists the full runtime registry to runtimes.json atomically.
    public func saveRuntimeRegistry(_ runtimes: [PersistedRuntime]) throws {
        try save(runtimes, to: MetadataStore.runtimeRegistryFilename)
    }

    /// Loads the runtime registry from runtimes.json, returning an empty array if not yet written.
    public func loadRuntimeRegistry() throws -> [PersistedRuntime] {
        try load([PersistedRuntime].self, from: MetadataStore.runtimeRegistryFilename, fallback: [])
    }
}
