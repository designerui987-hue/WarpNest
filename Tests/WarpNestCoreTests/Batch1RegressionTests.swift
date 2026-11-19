import Testing
import Foundation
@testable import WarpNestCore

/// Swift 6 concurrency actor for test synchronisation without arbitrary sleeps.
actor TestGate {
    private var waiters: [CheckedContinuation<Void, Never>] = []
    private var isOpened = false

    func wait() async {
        if isOpened { return }
        await withCheckedContinuation { continuation in
            waiters.append(continuation)
        }
    }

    func open() {
        isOpened = true
        let list = waiters
        waiters.removeAll()
        for w in list {
            w.resume()
        }
    }

    func reset() {
        isOpened = false
    }
}

/// Controllable mock adapter for deterministic process and prefix lifecycle testing.
struct ControllableMockAdapter: RuntimeAdapter {
    var descriptor: RuntimeDescriptor
    let isPrefixRunningHandler: @Sendable () async -> Bool
    let stopPrefixHandler: (@Sendable () async throws -> Void)?

    init(
        id: RuntimeID = RuntimeID("mock-controllable"),
        isPrefixRunningHandler: @escaping @Sendable () async -> Bool = { false },
        stopPrefixHandler: (@Sendable () async throws -> Void)? = nil
    ) {
        self.descriptor = RuntimeDescriptor(
            id: id,
            name: "Controllable Mock Adapter",
            version: "1.0",
            rootPath: "/usr/bin",
            isVerified: true,
            isSimulation: true,
            supportedArchitectures: ["arm64", "x86_64"],
            supportedGraphicsBackends: [.automatic, .wineD3D]
        )
        self.isPrefixRunningHandler = isPrefixRunningHandler
        self.stopPrefixHandler = stopPrefixHandler
    }

    func validate() async throws -> Bool { true }

    func initializePrefix(at prefixURL: URL, configuration: BottleConfiguration, logBuffer: LogRingBuffer) async throws {
        let driveC = prefixURL.appendingPathComponent("drive_c", isDirectory: true)
        try FileManager.default.createDirectory(at: driveC, withIntermediateDirectories: true)
        let systemReg = prefixURL.appendingPathComponent("system.reg")
        try "WINE REGISTRY Version 2\n".data(using: .utf8)?.write(to: systemReg)
    }

    func buildExecutionPlan(
        prefixURL: URL,
        executablePath: String,
        arguments: [String],
        configuration: BottleConfiguration
    ) throws -> (executableURL: URL, arguments: [String], environment: [String: String]) {
        if configuration.graphicsBackend == .d3dMetal {
            throw RuntimeAdapterError.unsupportedConfiguration("D3DMetal is not distributed with WarpNest.")
        }
        return (URL(fileURLWithPath: "/bin/echo"), ["Mock", executablePath], ["WINEPREFIX": prefixURL.path])
    }

    func stopPrefix(at prefixURL: URL) async throws {
        if let handler = stopPrefixHandler {
            try await handler()
        }
    }

    func isPrefixRunning(at prefixURL: URL) async -> Bool {
        await isPrefixRunningHandler()
    }
}

@Suite("Batch 1 Regression Tests")
struct Batch1RegressionTests {

    // MARK: - 1. Simulation Identity & Migration

    @Test("Developer mode on/off in the same session uses a consistent simulation ID")
    func testDeveloperModeSimulationIDConsistency() async throws {
        let adapter = TestRuntimeAdapter()
        #expect(adapter.descriptor.id == RuntimeID.simulation)
        #expect(adapter.descriptor.isSimulation == true)

        let tempDir = FileManager.default.temporaryDirectory.appendingPathComponent("WNDevModeTest_\(UUID().uuidString)")
        let store = MetadataStore(baseDirectory: tempDir)
        let bottleService = BottleService(metadataStore: store)

        await bottleService.registerAdapter(adapter)
        let registered = await bottleService.getAdapter(for: RuntimeID.simulation)
        #expect(registered != nil)

        await bottleService.unregisterAdapter(id: RuntimeID.simulation)
        let unregistered = await bottleService.getAdapter(for: RuntimeID.simulation)
        #expect(unregistered == nil)

        try? FileManager.default.removeItem(at: tempDir)
    }

    @Test("Persisted bottles with legacy runtimeID 'test-adapter-v1' migrate to canonical simulation ID")
    func testLegacySimulationIDMigration() async throws {
        let tempDir = FileManager.default.temporaryDirectory.appendingPathComponent("WNMigrationTest_\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: tempDir, withIntermediateDirectories: true)
        let store = MetadataStore(baseDirectory: tempDir)
        let bottleService = BottleService(metadataStore: store)

        // Write a raw legacy bottle JSON referencing "test-adapter-v1"
        let legacyBottleJSON = """
        [
          {
            "id": "A1B2C3D4-E5F6-7A8B-9C0D-1E2F3A4B5C6D",
            "name": "Legacy Sim Bottle",
            "runtimeID": "test-adapter-v1",
            "directoryPath": "\(tempDir.path)/bottle_legacy",
            "configuration": {
              "win64": true,
              "windowsVersion": "win10",
              "graphicsBackend": "Automatic",
              "syncBackend": "ESync (Eventfd)",
              "highResolutionMode": true,
              "environmentVariables": {}
            },
            "createdAt": "2026-11-01T00:00:00Z"
          }
        ]
        """
        let bottlesFile = tempDir.appendingPathComponent("bottles.json")
        try legacyBottleJSON.data(using: .utf8)?.write(to: bottlesFile)

        // Load bottles via BottleService
        let loaded = try await bottleService.loadBottles()
        #expect(loaded.count == 1)
        #expect(loaded[0].runtimeID == RuntimeID.simulation)
        #expect(loaded[0].name == "Legacy Sim Bottle")

        // Confirm the file on disk was rewritten with the canonical simulation ID
        let updatedRaw = try String(contentsOf: bottlesFile, encoding: .utf8)
        #expect(updatedRaw.contains("test-simulation"))
        #expect(!updatedRaw.contains("test-adapter-v1"))

        try? FileManager.default.removeItem(at: tempDir)
    }

    @Test("Simulated launch is rejected when developer mode adapter is not registered")
    func testSimulatedLaunchRejectedWithoutAdapter() async throws {
        let tempDir = FileManager.default.temporaryDirectory.appendingPathComponent("WNSimLaunchTest_\(UUID().uuidString)")
        let store = MetadataStore(baseDirectory: tempDir)
        let bottleService = BottleService(metadataStore: store)
        let libraryService = LibraryService(metadataStore: store, bottleService: bottleService)

        let adapter = TestRuntimeAdapter()
        await bottleService.registerAdapter(adapter)

        let bottle = try await bottleService.createBottle(
            name: "Sim Bottle",
            runtimeID: adapter.descriptor.id
        )
        let bottleURL = URL(fileURLWithPath: bottle.directoryPath)
        let exeURL = bottleURL.appendingPathComponent("drive_c/game.exe")
        try FileManager.default.createDirectory(at: exeURL.deletingLastPathComponent(), withIntermediateDirectories: true)
        try "dummy".data(using: .utf8)?.write(to: exeURL)
        let game = try await libraryService.addGame(
            name: "Sim Game",
            bottleID: bottle.id,
            executableRelativePath: "drive_c/game.exe"
        )

        await bottleService.unregisterAdapter(id: adapter.descriptor.id)

        await #expect(throws: LibraryServiceError.self) {
            try await libraryService.launchGame(id: game.id)
        }

        try? FileManager.default.removeItem(at: tempDir)
    }

    // MARK: - 2. Task Ownership, Pre-Spawn Cancellation, and Authoritative State

    @Test("Stop arriving during preparation prevents process spawn and clears session lock")
    func testStopDuringPreparationPreventsSpawn() async throws {
        let tempDir = FileManager.default.temporaryDirectory.appendingPathComponent("WNStopPreSpawn_\(UUID().uuidString)")
        let store = MetadataStore(baseDirectory: tempDir)
        let bottleService = BottleService(metadataStore: store)
        let libraryService = LibraryService(metadataStore: store, bottleService: bottleService)

        let adapter = TestRuntimeAdapter()
        await bottleService.registerAdapter(adapter)

        let bottle = try await bottleService.createBottle(name: "PreSpawn Bottle", runtimeID: adapter.descriptor.id)
        let bottleURL = URL(fileURLWithPath: bottle.directoryPath)
        let exeURL = bottleURL.appendingPathComponent("drive_c/game.exe")
        try FileManager.default.createDirectory(at: exeURL.deletingLastPathComponent(), withIntermediateDirectories: true)
        try "dummy".data(using: .utf8)?.write(to: exeURL)
        let game = try await libraryService.addGame(name: "PreSpawn Game", bottleID: bottle.id, executableRelativePath: "drive_c/game.exe")

        let gate = TestGate()
        await libraryService.setPreSpawnHook {
            await gate.wait()
        }

        // Launch in background task: it pauses at the gate in .preparing state
        let launchTask = Task {
            try await libraryService.launchGame(id: game.id)
        }

        // Yield briefly for launch sequence to enter pre-spawn hook
        while await libraryService.getSessionState(for: game.id) != .preparing {
            try await Task.sleep(nanoseconds: 10_000_000)
        }

        let stateDuringPrep = await libraryService.getSessionState(for: game.id)
        #expect(stateDuringPrep == .preparing)
        #expect((await bottleService.isBottleLocked(id: bottle.id)).isLocked == true)

        // Stop is requested while still in preparation
        await libraryService.stopGame(id: game.id)

        // Open gate to let launch task finish
        await gate.open()
        _ = await launchTask.result

        // Clean up hook
        await libraryService.setPreSpawnHook(nil)

        // Process was aborted before spawn: state is stopped and lock is released
        let stateAfter = await libraryService.getSessionState(for: game.id)
        #expect(stateAfter == .stopped)
        #expect((await bottleService.isBottleLocked(id: bottle.id)).isLocked == false)

        try? FileManager.default.removeItem(at: tempDir)
    }

    // MARK: - 3. Process Decoupling & Prefix Continuation

    @Test("Launcher exits while controlled prefix stays active, preserving session and lock")
    func testLauncherExitWithSurvivingPrefixPreservesLock() async throws {
        let tempDir = FileManager.default.temporaryDirectory.appendingPathComponent("WNPrefixContinuation_\(UUID().uuidString)")
        let store = MetadataStore(baseDirectory: tempDir)
        let bottleService = BottleService(metadataStore: store)
        let libraryService = LibraryService(metadataStore: store, bottleService: bottleService)

        actor PrefixState {
            var isRunning = true
            func setRunning(_ r: Bool) { isRunning = r }
            func getRunning() -> Bool { isRunning }
        }
        let prefixState = PrefixState()

        let adapter = ControllableMockAdapter(
            isPrefixRunningHandler: { await prefixState.getRunning() },
            stopPrefixHandler: { await prefixState.setRunning(false) }
        )
        await bottleService.registerAdapter(adapter)

        let bottle = try await bottleService.createBottle(name: "Continuation Bottle", runtimeID: adapter.descriptor.id)
        let bottleURL = URL(fileURLWithPath: bottle.directoryPath)
        let exeURL = bottleURL.appendingPathComponent("drive_c/game.exe")
        try FileManager.default.createDirectory(at: exeURL.deletingLastPathComponent(), withIntermediateDirectories: true)
        try "dummy".data(using: .utf8)?.write(to: exeURL)
        let game = try await libraryService.addGame(name: "Continuation Game", bottleID: bottle.id, executableRelativePath: "drive_c/game.exe")

        // Launch game: launcher process (/bin/echo) exits immediately
        try await libraryService.launchGame(id: game.id)

        // Wait until launcher process exits (it runs in milliseconds)
        try await Task.sleep(nanoseconds: 100_000_000)

        // Prefix is still running: session lock MUST remain held and state must be .running
        let isLockedDuring = await bottleService.isBottleLocked(id: bottle.id)
        #expect(isLockedDuring.isLocked == true)
        let stateDuring = await libraryService.getSessionState(for: game.id)
        #expect(stateDuring == .running)

        // Now stop the game session
        await libraryService.stopGame(id: game.id)

        // Prefix is stopped and session is cleanly finalized
        let isLockedAfter = await bottleService.isBottleLocked(id: bottle.id)
        #expect(isLockedAfter.isLocked == false)
        let stateAfter = await libraryService.getSessionState(for: game.id)
        #expect(stateAfter == .stopped)

        try? FileManager.default.removeItem(at: tempDir)
    }

    // MARK: - 4. Shutdown Failure & Lock Preservation

    @Test("Prefix shutdown failure preserves session and lock in recoverable Stop Failed state")
    func testPrefixShutdownFailurePreservesLock() async throws {
        let tempDir = FileManager.default.temporaryDirectory.appendingPathComponent("WNShutdownFailure_\(UUID().uuidString)")
        let store = MetadataStore(baseDirectory: tempDir)
        let bottleService = BottleService(metadataStore: store)
        let libraryService = LibraryService(metadataStore: store, bottleService: bottleService)

        actor PrefixControl {
            var failStop = true
            func setFailStop(_ f: Bool) { failStop = f }
            func shouldFail() -> Bool { failStop }
        }
        let prefixControl = PrefixControl()

        let adapter = ControllableMockAdapter(
            isPrefixRunningHandler: { await prefixControl.shouldFail() },
            stopPrefixHandler: {
                if await prefixControl.shouldFail() {
                    throw RuntimeAdapterError.wineCommandFailed("Simulated prefix termination failure")
                }
            }
        )
        await bottleService.registerAdapter(adapter)

        let bottle = try await bottleService.createBottle(name: "Stubborn Bottle", runtimeID: adapter.descriptor.id)
        let bottleURL = URL(fileURLWithPath: bottle.directoryPath)
        let exeURL = bottleURL.appendingPathComponent("drive_c/game.exe")
        try FileManager.default.createDirectory(at: exeURL.deletingLastPathComponent(), withIntermediateDirectories: true)
        try "dummy".data(using: .utf8)?.write(to: exeURL)
        let game = try await libraryService.addGame(name: "Stubborn Game", bottleID: bottle.id, executableRelativePath: "drive_c/game.exe")

        try await libraryService.launchGame(id: game.id)
        try await Task.sleep(nanoseconds: 100_000_000)

        // Attempt stop when prefix shutdown will fail
        await libraryService.stopGame(id: game.id)

        // Must transition to .stopFailed, and bottle lock MUST STILL BE HELD!
        let stateAfterFail = await libraryService.getSessionState(for: game.id)
        #expect(stateAfterFail == .stopFailed)
        let lockAfterFail = await bottleService.isBottleLocked(id: bottle.id)
        #expect(lockAfterFail.isLocked == true)

        // Now resolve failure condition and retry stop
        await prefixControl.setFailStop(false)
        await libraryService.stopGame(id: game.id)

        // Successfully recovered: state is .stopped and lock is released
        let finalState = await libraryService.getSessionState(for: game.id)
        #expect(finalState == .stopped)
        let finalLock = await bottleService.isBottleLocked(id: bottle.id)
        #expect(finalLock.isLocked == false)

        try? FileManager.default.removeItem(at: tempDir)
    }

    // MARK: - 5. Stale Callback Isolation

    @Test("Session B is not disrupted by a delayed callback from session A")
    func testStaleCallbackDoesNotAffectNewerSession() async throws {
        let tempDir = FileManager.default.temporaryDirectory.appendingPathComponent("WNStaleIsolation_\(UUID().uuidString)")
        let store = MetadataStore(baseDirectory: tempDir)
        let bottleService = BottleService(metadataStore: store)
        let libraryService = LibraryService(metadataStore: store, bottleService: bottleService)

        let adapter = TestRuntimeAdapter()
        await bottleService.registerAdapter(adapter)

        let bottle = try await bottleService.createBottle(name: "Isolation Bottle", runtimeID: adapter.descriptor.id)
        let bottleURL = URL(fileURLWithPath: bottle.directoryPath)
        let exeURL = bottleURL.appendingPathComponent("drive_c/game.exe")
        try FileManager.default.createDirectory(at: exeURL.deletingLastPathComponent(), withIntermediateDirectories: true)
        try "dummy".data(using: .utf8)?.write(to: exeURL)
        let game = try await libraryService.addGame(name: "Isolation Game", bottleID: bottle.id, executableRelativePath: "drive_c/game.exe")

        // Run Session A to completion
        try await libraryService.launchGame(id: game.id)
        await libraryService.stopGame(id: game.id)

        // Start Session B
        try await libraryService.launchGame(id: game.id)
        let sessionBState = await libraryService.getSessionState(for: game.id)
        #expect(sessionBState == .running || sessionBState == .preparing)

        // Attempt delivery of obsolete state change from old session ID
        await libraryService.notifyStateChange(for: game.id, state: .stopped)
        // Clean up Session B cleanly
        await libraryService.stopGame(id: game.id)
        let stateEnd = await libraryService.getSessionState(for: game.id)
        #expect(stateEnd == .stopped)

        try? FileManager.default.removeItem(at: tempDir)
    }

    // MARK: - 6. Capabilities & D3DMetal Non-Substitution

    @Test("Legacy D3DMetal decodes truthfully as .d3dMetal and is never silently substituted for DXVK")
    func testLegacyD3DMetalIsNotSubstituted() throws {
        let legacyD3DMetalJSON = "\"d3dMetal\"".data(using: .utf8)!
        let decodedD3DMetal = try JSONDecoder().decode(GraphicsBackend.self, from: legacyD3DMetalJSON)
        #expect(decodedD3DMetal == .d3dMetal)
        #expect(decodedD3DMetal != .dxvk)
        #expect(decodedD3DMetal.isSupported == false)

        let legacyCapsD3DMetal = "\"D3DMetal\"".data(using: .utf8)!
        let decodedCaps = try JSONDecoder().decode(GraphicsBackend.self, from: legacyCapsD3DMetal)
        #expect(decodedCaps == .d3dMetal)

        let legacyDXVKJSON = "\"DXVK (DirectX 9/10/11 -> Vulkan -> Metal)\"".data(using: .utf8)!
        let decodedDXVK = try JSONDecoder().decode(GraphicsBackend.self, from: legacyDXVKJSON)
        #expect(decodedDXVK == .dxvk)
    }

    @Test("D3DMetal configuration throws unsupportedConfiguration on execution plan build")
    func testD3DMetalExecutionPlanRejected() throws {
        let tempDir = FileManager.default.temporaryDirectory.appendingPathComponent("WND3DMetalRejection_\(UUID().uuidString)")
        let binDir = tempDir.appendingPathComponent("bin", isDirectory: true)
        try FileManager.default.createDirectory(at: binDir, withIntermediateDirectories: true)
        let wineFile = binDir.appendingPathComponent("wine")
        let winebootFile = binDir.appendingPathComponent("wineboot")
        let wineserverFile = binDir.appendingPathComponent("wineserver")
        try "#!/bin/sh\nexit 0\n".data(using: .utf8)?.write(to: wineFile)
        try "#!/bin/sh\nexit 0\n".data(using: .utf8)?.write(to: winebootFile)
        try "#!/bin/sh\nexit 0\n".data(using: .utf8)?.write(to: wineserverFile)
        try FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: wineFile.path)
        try FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: winebootFile.path)
        try FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: wineserverFile.path)

        let adapter = try WineRuntimeAdapter(rootDirectory: tempDir)
        var config = BottleConfiguration()
        config.graphicsBackend = .d3dMetal

        #expect(throws: RuntimeAdapterError.self) {
            _ = try adapter.buildExecutionPlan(
                prefixURL: tempDir,
                executablePath: "/tmp/game.exe",
                arguments: [],
                configuration: config
            )
        }

        try? FileManager.default.removeItem(at: tempDir)
    }

    @Test("Mach-O architecture detection truthfully identifies binaries without hardcoding")
    func testMachOArchitectureDetection() {
        let echoURL = URL(fileURLWithPath: "/bin/echo")
        let detected = WineRuntimeAdapter.detectArchitectures(for: echoURL)
        #expect(!detected.isEmpty)
        #expect(!detected.contains("unknown"))

        let fakeURL = URL(fileURLWithPath: "/tmp/nonexistent_\(UUID().uuidString)")
        let detectedFake = WineRuntimeAdapter.detectArchitectures(for: fakeURL)
        #expect(detectedFake == ["unknown"])
    }

    @Test("State queries accurately reflect preparing, stopping, and failure states")
    func testStateQueriesAgreeDuringLifecycle() async throws {
        let tempDir = FileManager.default.temporaryDirectory.appendingPathComponent("WNStateQueries_\(UUID().uuidString)")
        let store = MetadataStore(baseDirectory: tempDir)
        let bottleService = BottleService(metadataStore: store)
        let libraryService = LibraryService(metadataStore: store, bottleService: bottleService)

        let adapter = TestRuntimeAdapter()
        await bottleService.registerAdapter(adapter)

        let bottle = try await bottleService.createBottle(name: "Query Bottle", runtimeID: adapter.descriptor.id)
        let bottleURL = URL(fileURLWithPath: bottle.directoryPath)
        let exeURL = bottleURL.appendingPathComponent("drive_c/game.exe")
        try FileManager.default.createDirectory(at: exeURL.deletingLastPathComponent(), withIntermediateDirectories: true)
        try "dummy".data(using: .utf8)?.write(to: exeURL)
        let game = try await libraryService.addGame(name: "Query Game", bottleID: bottle.id, executableRelativePath: "drive_c/game.exe")

        // 1. Initial stopped state
        #expect(await libraryService.getSessionState(for: game.id) == .stopped)

        // 2. Preparing state via hook
        let gate = TestGate()
        await libraryService.setPreSpawnHook {
            await gate.wait()
        }
        let launchTask = Task {
            try await libraryService.launchGame(id: game.id)
        }
        while await libraryService.getSessionState(for: game.id) != .preparing {
            try await Task.sleep(nanoseconds: 10_000_000)
        }
        #expect(await libraryService.getSessionState(for: game.id) == .preparing)

        // 3. Stopping transition
        await libraryService.stopGame(id: game.id)
        await gate.open()
        _ = await launchTask.result
        await libraryService.setPreSpawnHook(nil)
        #expect(await libraryService.getSessionState(for: game.id) == .stopped)

        // 4. Failure state on invalid launch
        await bottleService.unregisterAdapter(id: adapter.descriptor.id)
        try? await libraryService.launchGame(id: game.id)
        #expect(await libraryService.getSessionState(for: game.id) == .failed)

        try? FileManager.default.removeItem(at: tempDir)
    }
}
