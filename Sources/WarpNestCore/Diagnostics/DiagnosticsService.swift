import Foundation

/// System diagnostics and hardware report for troubleshooting.
public struct SystemDiagnostics: Codable, Sendable {
    public let osVersion: String
    public let architecture: String
    public let physicalMemoryGB: Double
    public let rosettaActive: Bool
    public let freeDiskSpaceGB: Double
    public let xcodeAvailable: Bool
    public let recordedAt: Date

    public init(
        osVersion: String,
        architecture: String,
        physicalMemoryGB: Double,
        rosettaActive: Bool,
        freeDiskSpaceGB: Double,
        xcodeAvailable: Bool,
        recordedAt: Date = Date()
    ) {
        self.osVersion = osVersion
        self.architecture = architecture
        self.physicalMemoryGB = physicalMemoryGB
        self.rosettaActive = rosettaActive
        self.freeDiskSpaceGB = freeDiskSpaceGB
        self.xcodeAvailable = xcodeAvailable
        self.recordedAt = recordedAt
    }
}

/// Service that gathers hardware environment data and prepares exportable diagnostic bundles.
public struct DiagnosticsService: Sendable {
    public init() {}

    public func gatherDiagnostics() -> SystemDiagnostics {
        let osVer = ProcessInfo.processInfo.operatingSystemVersionString
        let mem = Double(ProcessInfo.processInfo.physicalMemory) / (1024 * 1024 * 1024)

        var isRosetta = false
        #if arch(arm64)
        // Check if Rosetta 2 translation is functional on host
        let testProcess = Process()
        testProcess.executableURL = URL(fileURLWithPath: "/usr/bin/arch")
        testProcess.arguments = ["-x86_64", "/usr/bin/uname", "-m"]
        let pipe = Pipe()
        testProcess.standardOutput = pipe
        try? testProcess.run()
        testProcess.waitUntilExit()
        isRosetta = testProcess.terminationStatus == 0
        #endif

        let fileManager = FileManager.default
        var freeDiskGB: Double = 0
        if let attrs = try? fileManager.attributesOfFileSystem(forPath: NSHomeDirectory()),
           let freeSpace = attrs[.systemFreeSize] as? NSNumber {
            freeDiskGB = Double(freeSpace.int64Value) / (1024 * 1024 * 1024)
        }

        let hasXcode = fileManager.fileExists(atPath: "/Applications/Xcode.app")

        #if arch(arm64)
        let hostArch = "arm64"
        #elseif arch(x86_64)
        let hostArch = "x86_64"
        #else
        let hostArch = "unknown"
        #endif

        return SystemDiagnostics(
            osVersion: osVer,
            architecture: hostArch,
            physicalMemoryGB: mem,
            rosettaActive: isRosetta,
            freeDiskSpaceGB: freeDiskGB,
            xcodeAvailable: hasXcode,
            recordedAt: Date()
        )
    }

    /// Prepares an exportable JSON report string.
    public func exportDiagnosticReport() -> String {
        let diag = gatherDiagnostics()
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        encoder.dateEncodingStrategy = .iso8601
        if let data = try? encoder.encode(diag), let str = String(data: data, encoding: .utf8) {
            return str
        }
        return "{}"
    }
}
