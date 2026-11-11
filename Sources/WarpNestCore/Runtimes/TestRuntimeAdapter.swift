import Foundation

/// Fast, deterministic mock/test adapter for unit testing and CI without requiring a 300MB external Wine runtime.
public struct TestRuntimeAdapter: RuntimeAdapter {
    public let descriptor: RuntimeDescriptor
    private let simulatedBinaryURL: URL

    public init(simulatedBinaryURL: URL = URL(fileURLWithPath: "/bin/echo")) {
        self.simulatedBinaryURL = simulatedBinaryURL
        self.descriptor = RuntimeDescriptor(
            id: RuntimeID("test-adapter-v1"),
            name: "WarpNest Test Runtime Adapter",
            version: "1.0-simulated",
            rootPath: "/usr/bin",
            isVerified: true,
            supportedArchitectures: ["arm64", "x86_64"],
            supportedGraphicsBackends: [.automatic, .wineD3D, .dxvk]
        )
    }

    public func validate() async throws -> Bool {
        return FileManager.default.fileExists(atPath: simulatedBinaryURL.path)
    }

    public func initializePrefix(at prefixURL: URL, configuration: BottleConfiguration, logBuffer: LogRingBuffer) async throws {
        logBuffer.append("[TEST ADAPTER] Initializing prefix at \(prefixURL.path)")
        let driveC = prefixURL.appendingPathComponent("drive_c", isDirectory: true)
        let progFiles = driveC.appendingPathComponent("Program Files", isDirectory: true)
        let windows = driveC.appendingPathComponent("windows", isDirectory: true)
        let system32 = windows.appendingPathComponent("system32", isDirectory: true)

        try FileManager.default.createDirectory(at: progFiles, withIntermediateDirectories: true)
        try FileManager.default.createDirectory(at: system32, withIntermediateDirectories: true)

        let systemReg = prefixURL.appendingPathComponent("system.reg")
        let userReg = prefixURL.appendingPathComponent("user.reg")
        let regData = "WINE REGISTRY Version 2\n[Software\\\\Wine]\n\"Version\"=\"TestAdapter\"\n".data(using: .utf8)!
        try regData.write(to: systemReg)
        try regData.write(to: userReg)

        logBuffer.append("[TEST ADAPTER] Bottle prefix initialized successfully.")
    }

    public func buildExecutionPlan(
        prefixURL: URL,
        executablePath: String,
        arguments: [String],
        configuration: BottleConfiguration
    ) throws -> (executableURL: URL, arguments: [String], environment: [String: String]) {
        // In the test adapter, we execute the simulated binary (/bin/echo or similar) with the program path as an argument.
        var args = ["Simulated Execution in prefix \(prefixURL.lastPathComponent):", executablePath]
        args.append(contentsOf: arguments)

        var env = [
            "WINEPREFIX": prefixURL.path,
            "WINEDEBUG": "-all",
            "WARPNEST_TEST_MODE": "1"
        ]
        if configuration.syncBackend == .esync {
            env["WINEESYNC"] = "1"
        }

        return (simulatedBinaryURL, args, env)
    }

    public func stopPrefix(at prefixURL: URL) async throws {
        // No-op for simulated prefix
    }
}
