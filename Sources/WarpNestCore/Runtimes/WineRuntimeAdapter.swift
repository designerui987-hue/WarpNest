import Foundation

/// Production Wine Runtime Adapter supporting Wine-Staging, WineCX, and standard macOS Wine distributions.
/// Represents a real compatibility runtime with lazy verification and true version querying.
public struct WineRuntimeAdapter: RuntimeAdapter {
    public var descriptor: RuntimeDescriptor
    public let wineExecutableURL: URL
    public let winebootExecutableURL: URL
    public let wineserverExecutableURL: URL

    /// Initializes an adapter for a Wine distribution root.
    /// Supports both standard UNIX layouts (root/bin/wine) and macOS App bundles (root/Contents/Resources/wine/bin/wine).
    public init(rootDirectory: URL, stableID: RuntimeID? = nil) throws {
        let fileManager = FileManager.default

        let directBin = rootDirectory.appendingPathComponent("bin", isDirectory: true)
        let appBundleBin = rootDirectory.appendingPathComponent("Contents/Resources/wine/bin", isDirectory: true)

        let binDir: URL
        if fileManager.fileExists(atPath: directBin.path) {
            binDir = directBin
        } else if fileManager.fileExists(atPath: appBundleBin.path) {
            binDir = appBundleBin
        } else {
            throw RuntimeAdapterError.binaryNotFound(directBin.path)
        }

        let wine64URL = binDir.appendingPathComponent("wine64")
        let wineURL = binDir.appendingPathComponent("wine")
        let winebootURL = binDir.appendingPathComponent("wineboot")
        let wineserverURL = binDir.appendingPathComponent("wineserver")

        let actualWine = fileManager.fileExists(atPath: wine64URL.path) ? wine64URL : wineURL

        guard fileManager.fileExists(atPath: actualWine.path) else {
            throw RuntimeAdapterError.binaryNotFound(actualWine.path)
        }

        guard fileManager.isExecutableFile(atPath: actualWine.path) else {
            throw RuntimeAdapterError.permissionDenied(actualWine.path)
        }

        // Validate required companion executables (WN-03 / WN-12)
        guard fileManager.fileExists(atPath: winebootURL.path) else {
            throw RuntimeAdapterError.binaryNotFound(winebootURL.path)
        }
        guard fileManager.isExecutableFile(atPath: winebootURL.path) else {
            throw RuntimeAdapterError.permissionDenied(winebootURL.path)
        }

        guard fileManager.fileExists(atPath: wineserverURL.path) else {
            throw RuntimeAdapterError.binaryNotFound(wineserverURL.path)
        }
        guard fileManager.isExecutableFile(atPath: wineserverURL.path) else {
            throw RuntimeAdapterError.permissionDenied(wineserverURL.path)
        }

        self.wineExecutableURL = actualWine
        self.winebootExecutableURL = winebootURL
        self.wineserverExecutableURL = wineserverURL

        let detectedArchs = Self.detectArchitectures(for: actualWine)
        let assignedID = stableID ?? RuntimeID("wine-" + UUID().uuidString)
        self.descriptor = RuntimeDescriptor(
            id: assignedID,
            name: "Wine (\(rootDirectory.lastPathComponent))",
            version: "Unknown (Unvalidated)",
            rootPath: rootDirectory.path,
            isVerified: false,
            isSimulation: false,
            supportedArchitectures: detectedArchs,
            supportedGraphicsBackends: [.automatic, .wineD3D]
        )
    }

    /// Inspects the binary Mach-O header to truthfully determine supported architectures without hardcoding.
    public static func detectArchitectures(for binaryURL: URL) -> [String] {
        guard let handle = try? FileHandle(forReadingFrom: binaryURL) else {
            return ["unknown"]
        }
        defer { try? handle.close() }
        let headerData = handle.readData(ofLength: 4)
        guard headerData.count == 4 else { return ["unknown"] }
        let magic = headerData.withUnsafeBytes { $0.load(as: UInt32.self) }

        if magic == 0xfeedfacf || magic == 0xcffaedfe {
            let cpuData = handle.readData(ofLength: 4)
            guard cpuData.count == 4 else { return ["unknown"] }
            let cpuType = cpuData.withUnsafeBytes { $0.load(as: UInt32.self) }
            if cpuType == 0x0100000c || cpuType == 0x0c000001 {
                return ["arm64"]
            } else if cpuType == 0x01000007 || cpuType == 0x07000001 {
                return ["x86_64"]
            }
        } else if magic == 0xcafebabe || magic == 0xbebafeca {
            return ["x86_64", "arm64"]
        } else if magic == 0x7f454c46 {
            return ["x86_64"]
        }
        return ["unknown"]
    }

    /// Validates the runtime by executing `wine --version` with a bounded timeout and checking executable permissions.
    public func validate() async throws -> Bool {
        let fileManager = FileManager.default
        guard fileManager.fileExists(atPath: wineExecutableURL.path),
              fileManager.isExecutableFile(atPath: wineExecutableURL.path),
              fileManager.fileExists(atPath: winebootExecutableURL.path),
              fileManager.isExecutableFile(atPath: winebootExecutableURL.path),
              fileManager.fileExists(atPath: wineserverExecutableURL.path),
              fileManager.isExecutableFile(atPath: wineserverExecutableURL.path) else {
            return false
        }

        let supervisor = ProcessSupervisor()
        let valTask = Task {
            try await supervisor.launch(
                executableURL: wineExecutableURL,
                arguments: ["--version"]
            )
        }

        let timeoutTask = Task {
            try await Task.sleep(nanoseconds: 5_000_000_000)
            await supervisor.terminate()
        }

        do {
            let status = try await valTask.value
            timeoutTask.cancel()
            return status.exitCode == 0 && !status.wasCancelled
        } catch {
            timeoutTask.cancel()
            return false
        }
    }

    /// Queries the actual runtime version string via `wine --version` with a bounded deadline.
    public func queryVersion() async -> String? {
        let buffer = LogRingBuffer()
        let sup = ProcessSupervisor(logBuffer: buffer)
        let queryTask = Task {
            try await sup.launch(
                executableURL: wineExecutableURL,
                arguments: ["--version"]
            )
        }
        let timeoutTask = Task {
            try await Task.sleep(nanoseconds: 5_000_000_000)
            await sup.terminate()
        }
        do {
            let status = try await queryTask.value
            timeoutTask.cancel()
            if status.exitCode == 0 && !status.wasCancelled {
                let lines = buffer.getAllLines()
                for line in lines {
                    if line.starts(with: "[STDOUT] ") {
                        let ver = String(line.dropFirst(9)).trimmingCharacters(in: .whitespacesAndNewlines)
                        if !ver.isEmpty { return ver }
                    }
                }
            }
        } catch {
            timeoutTask.cancel()
            return nil
        }
        return nil
    }

    /// Initializes a wine prefix with a 120-second bounded timeout.
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

        let initTask = Task {
            try await supervisor.launch(
                executableURL: winebootExecutableURL,
                arguments: ["-u"],
                environment: env
            )
        }

        let timeoutTask = Task {
            try await Task.sleep(nanoseconds: 120_000_000_000)
            await supervisor.terminate()
        }

        let status: ProcessExitStatus
        do {
            status = try await initTask.value
            timeoutTask.cancel()
        } catch {
            timeoutTask.cancel()
            throw error
        }

        guard status.exitCode == 0 else {
            if status.wasCancelled {
                throw RuntimeAdapterError.winebootTimedOut
            }
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
        // executablePath must be an absolute path resolved and validated by LibraryService (WN-01).
        // LibraryService.resolveAndValidateExecutable guarantees it is absolute and inside the bottle.
        assert(executablePath.hasPrefix("/"), "executablePath must be an absolute path")

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

        switch configuration.graphicsBackend {
        case .d3dMetal:
            throw RuntimeAdapterError.unsupportedConfiguration("Apple D3DMetal is proprietary and not distributed with WarpNest. It cannot be used without external Game Porting Toolkit components.")
        case .dxvk:
            // NOTE: sets renderer hint only; does not install or verify DXVK
            env["WINE_D3D_CONFIG"] = "renderer=vulkan"
        case .wineD3D:
            env["WINE_D3D_CONFIG"] = "renderer=gl"
        case .automatic:
            break
        }

        // WN-12: strip reserved Wine keys from bottle configuration overrides so callers cannot
        // redirect WINEPREFIX, WINESERVER, WINELOADER, WINEDLLPATH, or WINEDEBUG away from managed values.
        let reservedKeys: Set<String> = ["WINEPREFIX", "WINESERVER", "WINELOADER", "WINEDLLPATH", "WINEDEBUG"]
        for (k, v) in configuration.environmentVariables where !reservedKeys.contains(k) {
            env[k] = v
        }

        return (wineExecutableURL, args, env)
    }

    public func stopPrefix(at prefixURL: URL) async throws {
        guard FileManager.default.fileExists(atPath: wineserverExecutableURL.path) else { return }
        let supervisor = ProcessSupervisor()
        let status = try await supervisor.launch(
            executableURL: wineserverExecutableURL,
            arguments: ["-k"],
            environment: ["WINEPREFIX": prefixURL.path]
        )
        guard status.exitCode == 0 else {
            throw RuntimeAdapterError.wineCommandFailed("wineserver -k failed with exit code \(status.exitCode)")
        }
    }

    public func isPrefixRunning(at prefixURL: URL) async -> Bool {
        guard FileManager.default.fileExists(atPath: wineserverExecutableURL.path) else { return false }
        let p = Process()
        p.executableURL = wineserverExecutableURL
        p.arguments = ["-k0"]
        p.environment = ["WINEPREFIX": prefixURL.path]
        do {
            try p.run()
            p.waitUntilExit()
            return p.terminationStatus == 0
        } catch {
            return false
        }
    }
}
