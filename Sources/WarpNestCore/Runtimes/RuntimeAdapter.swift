import Foundation

/// Capability descriptor of a registered compatibility runtime.
public struct RuntimeDescriptor: Identifiable, Codable, Sendable, Equatable {
    public let id: RuntimeID
    public var name: String
    public var version: String
    public var rootPath: String
    public var isVerified: Bool
    public var isSimulation: Bool
    public var supportedArchitectures: [String]
    public var supportedGraphicsBackends: [GraphicsBackend]

    public init(
        id: RuntimeID,
        name: String,
        version: String,
        rootPath: String,
        isVerified: Bool,
        isSimulation: Bool = false,
        supportedArchitectures: [String] = ["x86_64", "arm64"],
        supportedGraphicsBackends: [GraphicsBackend] = [.dxvk, .wineD3D]
    ) {
        self.id = id
        self.name = name
        self.version = version
        self.rootPath = rootPath
        self.isVerified = isVerified
        self.isSimulation = isSimulation
        self.supportedArchitectures = supportedArchitectures
        self.supportedGraphicsBackends = supportedGraphicsBackends
    }
}

/// Errors from Runtime Adapters.
public enum RuntimeAdapterError: Error, LocalizedError, Sendable {
    case binaryNotFound(String)
    case runtimeValidationFailed(String)
    case unsupportedArchitecture(String)
    case winebootFailed(Int32)
    case winebootTimedOut
    case wineCommandFailed(String)
    case permissionDenied(String)

    public var errorDescription: String? {
        switch self {
        case .binaryNotFound(let path):
            return "Runtime binary not found at path: \(path)"
        case .runtimeValidationFailed(let reason):
            return "Runtime validation failed: \(reason)"
        case .unsupportedArchitecture(let arch):
            return "Architecture '\(arch)' is not supported by this runtime."
        case .winebootFailed(let code):
            return "wineboot failed with exit code \(code)"
        case .winebootTimedOut:
            return "Wine prefix initialization timed out (exceeded 120 seconds)."
        case .wineCommandFailed(let msg):
            return "Wine command failed: \(msg)"
        case .permissionDenied(let path):
            return "Executable permissions missing or denied for: \(path)"
        }
    }
}

/// Protocol abstracting interaction with a Windows compatibility runtime engine.
public protocol RuntimeAdapter: Sendable {
    var descriptor: RuntimeDescriptor { get }

    /// Validates that the runtime's binaries exist, have executable permissions, and execute properly.
    func validate() async throws -> Bool

    /// Initializes a fresh prefix/bottle directory structure with bounded timeout.
    func initializePrefix(at prefixURL: URL, configuration: BottleConfiguration, logBuffer: LogRingBuffer) async throws

    /// Generates the process execution command arguments for running a program in a bottle.
    func buildExecutionPlan(
        prefixURL: URL,
        executablePath: String,
        arguments: [String],
        configuration: BottleConfiguration
    ) throws -> (executableURL: URL, arguments: [String], environment: [String: String])

    /// Stops any running wineserver or services associated with the prefix.
    func stopPrefix(at prefixURL: URL) async throws
}
