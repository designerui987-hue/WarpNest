import Foundation

/// Production Wine Runtime Adapter supporting Wine-Staging, WineCX, and custom Wine distributions.
public struct WineRuntimeAdapter: RuntimeAdapter {
    public let descriptor: RuntimeDescriptor
    public let wineExecutableURL: URL
    public let winebootExecutableURL: URL
    public let wineserverExecutableURL: URL

    public init(rootDirectory: URL) throws {
        let binDir = rootDirectory.appendingPathComponent("bin", isDirectory: true)
        let wineURL = binDir.appendingPathComponent("wine")
        let wine64URL = binDir.appendingPathComponent("wine64")
        let winebootURL = binDir.appendingPathComponent("wineboot")
        let wineserverURL = binDir.appendingPathComponent("wineserver")

        let actualWine = FileManager.default.fileExists(atPath: wine64URL.path) ? wine64URL : wineURL

        guard FileManager.default.fileExists(atPath: actualWine.path) else {
            throw RuntimeAdapterError.binaryNotFound(actualWine.path)
        }

        self.wineExecutableURL = actualWine
        self.winebootExecutableURL = winebootURL
        self.wineserverExecutableURL = wineserverURL

        self.descriptor = RuntimeDescriptor(
            id: RuntimeID("wine-imported-\(rootDirectory.lastPathComponent)"),
            name: "Wine Runtime (\(rootDirectory.lastPathComponent))",
            version: "Wine-Staging / macOS",
            rootPath: rootDirectory.path,
            isVerified: true,
            supportedArchitectures: ["x86_64", "arm64"],
            supportedGraphicsBackends: [.automatic, .dxvk, .wineD3D]
        )
    }

    public func validate() async throws -> Bool {
        guard FileManager.default.fileExists(atPath: wineExecutableURL.path) else {
            return false
        }
        let supervisor = ProcessSupervisor()
        do {
            let status = try await supervisor.launch(
                executableURL: wineExecutableURL,
                arguments: ["--version"]
            )
            return status.exitCode == 0
        } catch {
            return false
        }
    }

    public func initializePrefix(at prefixURL: URL, configuration: BottleConfiguration, logBuffer: LogRingBuffer) async throws {
        logBuffer.append("[WINE ADAPTER] Initializing wine prefix at: \(prefixURL.path)")
        try FileManager.default.createDirectory(at: prefixURL, withIntermediateDirectories: true)

        guard FileManager.default.fileExists(atPath: winebootExecutableURL.path) else {
            throw RuntimeAdapterError.binaryNotFound(winebootExecutableURL.path)
        }

        let supervisor = ProcessSupervisor(logBuffer: logBuffer)
        var env: [String: String] = [
            "WINEPREFIX": prefixURL.path,
            "WINEDEBUG": "-all"
        ]
        if !configuration.win64 {
            env["WINEARCH"] = "win32"
        }

        let status = try await supervisor.launch(
            executableURL: winebootExecutableURL,
            arguments: ["-u"],
            environment: env
        )

        guard status.exitCode == 0 else {
            throw RuntimeAdapterError.winebootFailed(status.exitCode)
        }

        logBuffer.append("[WINE ADAPTER] Wineboot completed successfully.")
    }

    public func buildExecutionPlan(
        prefixURL: URL,
        executablePath: String,
        arguments: [String],
        configuration: BottleConfiguration
    ) throws -> (executableURL: URL, arguments: [String], environment: [String: String]) {
        var args = [executablePath]
        args.append(contentsOf: arguments)

        var env: [String: String] = [
            "WINEPREFIX": prefixURL.path,
            "WINEDEBUG": "-all"
        ]

        if configuration.syncBackend == .esync {
            env["WINEESYNC"] = "1"
        } else if configuration.syncBackend == .msync {
            env["WINEMSYNC"] = "1"
        }

        // Configure Graphics Backend
        switch configuration.graphicsBackend {
        case .dxvk:
            env["WINE_D3D_CONFIG"] = "renderer=vulkan"
        case .wineD3D:
            env["WINE_D3D_CONFIG"] = "renderer=gl"
        case .automatic, .d3dMetal:
            break
        }

        // Apply custom environment variables
        for (k, v) in configuration.environmentVariables {
            env[k] = v
        }

        return (wineExecutableURL, args, env)
    }

    public func stopPrefix(at prefixURL: URL) async throws {
        guard FileManager.default.fileExists(atPath: wineserverExecutableURL.path) else { return }
        let supervisor = ProcessSupervisor()
        _ = try? await supervisor.launch(
            executableURL: wineserverExecutableURL,
            arguments: ["-k"],
            environment: ["WINEPREFIX": prefixURL.path]
        )
    }
}
