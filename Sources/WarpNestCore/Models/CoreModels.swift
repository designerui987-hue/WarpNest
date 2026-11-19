import Foundation

/// Unique identifier for an installed game or application.
public struct GameID: Hashable, Codable, Sendable, CustomStringConvertible {
    public let rawValue: UUID

    private enum CodingKeys: String, CodingKey {
        case rawValue
    }

    public init(rawValue: UUID = UUID()) {
        self.rawValue = rawValue
    }

    public var description: String { rawValue.uuidString }

    public init(from decoder: Decoder) throws {
        if let single = try? decoder.singleValueContainer(), let uuid = try? single.decode(UUID.self) {
            self.rawValue = uuid
        } else {
            let container = try decoder.container(keyedBy: CodingKeys.self)
            self.rawValue = try container.decode(UUID.self, forKey: .rawValue)
        }
    }

    public func encode(to encoder: Encoder) throws {
        var container = encoder.singleValueContainer()
        try container.encode(rawValue)
    }
}

/// Unique identifier for a Wine prefix/bottle.
public struct BottleID: Hashable, Codable, Sendable, CustomStringConvertible {
    public let rawValue: UUID

    private enum CodingKeys: String, CodingKey {
        case rawValue
    }

    public init(rawValue: UUID = UUID()) {
        self.rawValue = rawValue
    }

    public var description: String { rawValue.uuidString }

    public init(from decoder: Decoder) throws {
        if let single = try? decoder.singleValueContainer(), let uuid = try? single.decode(UUID.self) {
            self.rawValue = uuid
        } else {
            let container = try decoder.container(keyedBy: CodingKeys.self)
            self.rawValue = try container.decode(UUID.self, forKey: .rawValue)
        }
    }

    public func encode(to encoder: Encoder) throws {
        var container = encoder.singleValueContainer()
        try container.encode(rawValue)
    }
}

/// Unique identifier for a registered compatibility runtime.
public struct RuntimeID: Hashable, Codable, Sendable, CustomStringConvertible {
    public let rawValue: String

    private enum CodingKeys: String, CodingKey {
        case rawValue
    }

    public init(_ rawValue: String) {
        self.rawValue = rawValue
    }

    public var description: String { rawValue }

    /// Canonical shared identifier for the simulated test engine.
    public static let simulation = RuntimeID("test-simulation")
    /// Deprecated legacy identifier retained for seamless persisted migration.
    public static let legacySimulation = RuntimeID("test-adapter-v1")

    public init(from decoder: Decoder) throws {
        if let single = try? decoder.singleValueContainer(), let str = try? single.decode(String.self) {
            self.rawValue = str
        } else {
            let container = try decoder.container(keyedBy: CodingKeys.self)
            self.rawValue = try container.decode(String.self, forKey: .rawValue)
        }
    }

    public func encode(to encoder: Encoder) throws {
        var container = encoder.singleValueContainer()
        try container.encode(rawValue)
    }
}

/// Graphics backend supported by a runtime or requested by a bottle.
public enum GraphicsBackend: String, Codable, Sendable, CaseIterable {
    case automatic = "Automatic"
    case wineD3D = "WineD3D (built-in Wine D3D translation)"
    case dxvk = "DXVK (not installed — sets renderer hint only)"
    case d3dMetal = "Apple D3DMetal (unsupported / not distributed)"

    public var displayName: String { rawValue }

    /// Whether this backend is verified supported and executable out-of-the-box in this build.
    public var isSupported: Bool {
        switch self {
        case .automatic, .wineD3D: return true
        case .dxvk, .d3dMetal: return false
        }
    }

    /// Whether the backend requires manual installation (not bundled by WarpNest).
    public var isInstallRequired: Bool {
        switch self {
        case .dxvk, .d3dMetal: return true
        case .wineD3D, .automatic: return false
        }
    }

    /// Human-readable note describing capability limits and configuration behaviour.
    public var capabilityNote: String {
        switch self {
        case .automatic:
            return "Uses the runtime's default graphics configuration."
        case .wineD3D:
            return "Uses Wine's built-in D3D translation layer. Verified available in standard Wine builds."
        case .dxvk:
            return "DXVK libraries must be installed manually in the bottle. This option sets WINE_D3D_CONFIG=renderer=vulkan only."
        case .d3dMetal:
            return "Apple D3DMetal is proprietary and not distributed with WarpNest. It cannot be used without external Game Porting Toolkit components."
        }
    }

    public init(from decoder: Decoder) throws {
        let container = try decoder.singleValueContainer()
        let raw = try container.decode(String.self)
        // Backward-compatible decoding: preserve legacy configurations truthfully without silent substitution
        if raw == "d3dMetal" || raw == "D3DMetal" || raw == "Apple D3DMetal (unsupported / not distributed)" {
            self = .d3dMetal
        } else if raw == "dxvk" || raw == "DXVK" || raw == "DXVK (DirectX 9/10/11 -> Vulkan -> Metal)" {
            self = .dxvk
        } else if raw == "wineD3D" || raw == "WineD3D" || raw == "WineD3D (DirectX -> OpenGL/Metal)" {
            self = .wineD3D
        } else if let match = GraphicsBackend(rawValue: raw) {
            self = match
        } else {
            self = .automatic
        }
    }
}

/// Synchronization method for Windows threads.
public enum SyncBackend: String, Codable, Sendable, CaseIterable {
    case standard = "Standard Wine Sync"
    case esync = "ESync (Eventfd)"
    case msync = "MSync (Mach Port Sync)"
}

/// Global application configuration settings persisted to disk.
public struct AppSettings: Codable, Sendable, Equatable {
    public var developerModeEnabled: Bool
    public var defaultSyncBackend: SyncBackend
    public var defaultHighResolutionMode: Bool

    public init(
        developerModeEnabled: Bool = false,
        defaultSyncBackend: SyncBackend = .esync,
        defaultHighResolutionMode: Bool = true
    ) {
        self.developerModeEnabled = developerModeEnabled
        self.defaultSyncBackend = defaultSyncBackend
        self.defaultHighResolutionMode = defaultHighResolutionMode
    }
}

/// Configuration options for a bottle.
public struct BottleConfiguration: Codable, Sendable, Equatable {
    public var win64: Bool
    public var windowsVersion: String
    public var graphicsBackend: GraphicsBackend
    public var syncBackend: SyncBackend
    public var highResolutionMode: Bool
    public var environmentVariables: [String: String]

    public init(
        win64: Bool = true,
        windowsVersion: String = "win10",
        graphicsBackend: GraphicsBackend = .automatic,
        syncBackend: SyncBackend = .esync,
        highResolutionMode: Bool = true,
        environmentVariables: [String: String] = [:]
    ) {
        self.win64 = win64
        self.windowsVersion = windowsVersion
        self.graphicsBackend = graphicsBackend
        self.syncBackend = syncBackend
        self.highResolutionMode = highResolutionMode
        self.environmentVariables = environmentVariables
    }
}

/// Metadata model representing an isolated Wine prefix.
public struct Bottle: Identifiable, Codable, Sendable, Equatable {
    public let id: BottleID
    public var name: String
    public var runtimeID: RuntimeID
    public var directoryPath: String
    public var configuration: BottleConfiguration
    public var createdAt: Date
    public var lastUsedAt: Date?

    public init(
        id: BottleID = BottleID(),
        name: String,
        runtimeID: RuntimeID,
        directoryPath: String,
        configuration: BottleConfiguration = BottleConfiguration(),
        createdAt: Date = Date(),
        lastUsedAt: Date? = nil
    ) {
        self.id = id
        self.name = name
        self.runtimeID = runtimeID
        self.directoryPath = directoryPath
        self.configuration = configuration
        self.createdAt = createdAt
        self.lastUsedAt = lastUsedAt
    }

    public init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        self.id = try container.decode(BottleID.self, forKey: .id)
        self.name = try container.decode(String.self, forKey: .name)
        let rID = try container.decode(RuntimeID.self, forKey: .runtimeID)
        // Transparent migration of legacy test-adapter-v1 to canonical test-simulation
        self.runtimeID = (rID == RuntimeID.legacySimulation) ? RuntimeID.simulation : rID
        self.directoryPath = try container.decode(String.self, forKey: .directoryPath)
        self.configuration = try container.decode(BottleConfiguration.self, forKey: .configuration)
        self.createdAt = try container.decodeIfPresent(Date.self, forKey: .createdAt) ?? Date()
        self.lastUsedAt = try container.decodeIfPresent(Date.self, forKey: .lastUsedAt)
    }
}

/// A runtime entry persisted to disk so imported runtimes survive restarts.
public struct PersistedRuntime: Codable, Sendable, Identifiable {
    public let id: RuntimeID          // stable UUID-based identifier
    public let displayName: String
    public let executablePath: String // absolute path to wine binary
    public let rootPath: String       // absolute path to runtime root
    public let version: String        // from wine --version or "unknown"
    public let importedAt: Date
    public let isUserImported: Bool   // false = auto-discovered

    public init(
        id: RuntimeID,
        displayName: String,
        executablePath: String,
        rootPath: String,
        version: String,
        importedAt: Date,
        isUserImported: Bool
    ) {
        self.id = id
        self.displayName = displayName
        self.executablePath = executablePath
        self.rootPath = rootPath
        self.version = version
        self.importedAt = importedAt
        self.isUserImported = isUserImported
    }
}

/// Status of an application launch or session.
public enum SessionState: String, Codable, Sendable, CaseIterable {
    case stopped = "Stopped"
    case preparing = "Preparing Prefix"
    case running = "Running"
    case stopping = "Stopping"
    case stopFailed = "Stop Failed"
    case failed = "Failed"
}

/// Represented game or software application installed in a bottle.
public struct GameItem: Identifiable, Codable, Sendable, Equatable {
    public let id: GameID
    public var name: String
    public var bottleID: BottleID
    public var executableRelativePath: String
    public var workingDirectoryRelativePath: String?
    public var arguments: [String]
    public var environmentOverrides: [String: String]
    public var isExternalExecutable: Bool
    public var iconPath: String?
    public var notes: String
    public var createdAt: Date
    public var lastPlayedAt: Date?
    public var totalPlayTimeSeconds: TimeInterval

    public init(
        id: GameID = GameID(),
        name: String,
        bottleID: BottleID,
        executableRelativePath: String,
        workingDirectoryRelativePath: String? = nil,
        arguments: [String] = [],
        environmentOverrides: [String: String] = [:],
        isExternalExecutable: Bool = false,
        iconPath: String? = nil,
        notes: String = "",
        createdAt: Date = Date(),
        lastPlayedAt: Date? = nil,
        totalPlayTimeSeconds: TimeInterval = 0
    ) {
        self.id = id
        self.name = name
        self.bottleID = bottleID
        self.executableRelativePath = executableRelativePath
        self.workingDirectoryRelativePath = workingDirectoryRelativePath
        self.arguments = arguments
        self.environmentOverrides = environmentOverrides
        self.isExternalExecutable = isExternalExecutable
        self.iconPath = iconPath
        self.notes = notes
        self.createdAt = createdAt
        self.lastPlayedAt = lastPlayedAt
        self.totalPlayTimeSeconds = totalPlayTimeSeconds
    }

    public init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        self.id = try container.decode(GameID.self, forKey: .id)
        self.name = try container.decode(String.self, forKey: .name)
        self.bottleID = try container.decode(BottleID.self, forKey: .bottleID)
        self.executableRelativePath = try container.decode(String.self, forKey: .executableRelativePath)
        self.workingDirectoryRelativePath = try container.decodeIfPresent(String.self, forKey: .workingDirectoryRelativePath)
        self.arguments = try container.decodeIfPresent([String].self, forKey: .arguments) ?? []
        self.environmentOverrides = try container.decodeIfPresent([String: String].self, forKey: .environmentOverrides) ?? [:]
        self.isExternalExecutable = try container.decodeIfPresent(Bool.self, forKey: .isExternalExecutable) ?? false
        self.iconPath = try container.decodeIfPresent(String.self, forKey: .iconPath)
        self.notes = try container.decodeIfPresent(String.self, forKey: .notes) ?? ""
        self.createdAt = try container.decodeIfPresent(Date.self, forKey: .createdAt) ?? Date()
        self.lastPlayedAt = try container.decodeIfPresent(Date.self, forKey: .lastPlayedAt)
        self.totalPlayTimeSeconds = try container.decodeIfPresent(TimeInterval.self, forKey: .totalPlayTimeSeconds) ?? 0
    }
}
