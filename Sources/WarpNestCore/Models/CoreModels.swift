import Foundation

/// Unique identifier for an installed game or application.
public struct GameID: Hashable, Codable, Sendable, CustomStringConvertible {
    public let rawValue: UUID

    public init(rawValue: UUID = UUID()) {
        self.rawValue = rawValue
    }

    public var description: String { rawValue.uuidString }
}

/// Unique identifier for a Wine prefix/bottle.
public struct BottleID: Hashable, Codable, Sendable, CustomStringConvertible {
    public let rawValue: UUID

    public init(rawValue: UUID = UUID()) {
        self.rawValue = rawValue
    }

    public var description: String { rawValue.uuidString }
}

/// Unique identifier for a registered compatibility runtime.
public struct RuntimeID: Hashable, Codable, Sendable, CustomStringConvertible {
    public let rawValue: String

    public init(_ rawValue: String) {
        self.rawValue = rawValue
    }

    public var description: String { rawValue }
}

/// Graphics backend supported by a runtime or requested by a bottle.
public enum GraphicsBackend: String, Codable, Sendable, CaseIterable {
    case automatic = "Automatic"
    case dxvk = "DXVK (DirectX 9/10/11 -> Vulkan -> Metal)"
    case wineD3D = "WineD3D (DirectX -> OpenGL/Metal)"

    public var displayName: String { rawValue }
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
}

/// Status of an application launch or session.
public enum SessionState: String, Codable, Sendable {
    case stopped = "Stopped"
    case preparing = "Preparing Prefix"
    case running = "Running"
    case stopping = "Stopping"
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
        self.iconPath = iconPath
        self.notes = notes
        self.createdAt = createdAt
        self.lastPlayedAt = lastPlayedAt
        self.totalPlayTimeSeconds = totalPlayTimeSeconds
    }
}
