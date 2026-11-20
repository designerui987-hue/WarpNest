import Testing
import Foundation
@testable import WarpNestCore

@Suite("Manual Verification Checklist Tests")
struct ManualChecklistVerificationTests {

    // MARK: - 1. Developer Mode Simulation
    @Test("Checklist Item 1: Developer Mode Simulation (Enable -> Create Bottle -> Launch -> Disable -> Launch Rejected)")
    func testDeveloperModeSimulationChecklist() async throws {
        let tempDir = FileManager.default.temporaryDirectory.appendingPathComponent("ChecklistDevMode_\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: tempDir, withIntermediateDirectories: true)
        let store = MetadataStore(baseDirectory: tempDir)
        let bottleService = BottleService(metadataStore: store)
        let libraryService = LibraryService(metadataStore: store, bottleService: bottleService)

        // Step 1: Settings → Enable Developer Mode
        // Verify "Simulation Test Engine" appears in registered runtimes with ID test-simulation
        let simulationAdapter = TestRuntimeAdapter()
        #expect(simulationAdapter.descriptor.id == RuntimeID.simulation)
        #expect(simulationAdapter.descriptor.id.rawValue == "test-simulation")
        #expect(simulationAdapter.descriptor.name.contains("Simulated Test Engine"))
        #expect(simulationAdapter.descriptor.isSimulation == true)

        await bottleService.registerAdapter(simulationAdapter)
        let registeredRuntimes = await bottleService.getAllRegisteredAdapters().map { $0.descriptor }
        let simDescriptor = registeredRuntimes.first { $0.id == RuntimeID.simulation }
        #expect(simDescriptor != nil, "Simulation Test Engine must appear in registered runtimes")
        #expect(simDescriptor?.name.contains("Simulated Test Engine") == true)
        #expect(simDescriptor?.id.rawValue == "test-simulation")

        // Step 2: Create a bottle using the simulation engine; launch a simulated game
        let bottle = try await bottleService.createBottle(
            name: "Simulated Test Bottle",
            runtimeID: RuntimeID.simulation
        )
        #expect(bottle.runtimeID == RuntimeID.simulation)

        let bottleURL = URL(fileURLWithPath: bottle.directoryPath)
        let exeURL = bottleURL.appendingPathComponent("drive_c/game.exe")
        try FileManager.default.createDirectory(at: exeURL.deletingLastPathComponent(), withIntermediateDirectories: true)
        try "dummy".data(using: .utf8)?.write(to: exeURL)

        let game = try await libraryService.addGame(
            name: "Simulated Game",
            bottleID: bottle.id,
            executableRelativePath: "drive_c/game.exe"
        )

        // Launch simulated game
        try await libraryService.launchGame(id: game.id)

        // Wait for natural exit and session finalization
        while await libraryService.getSessionState(for: game.id) != .stopped {
            try await Task.sleep(nanoseconds: 10_000_000)
        }
        #expect(await libraryService.getSessionState(for: game.id) == .stopped)
        #expect((await bottleService.isBottleLocked(id: bottle.id)).isLocked == false)

        // Step 3: Settings → Disable Developer Mode
        // Verify the simulated game cannot launch and simulation engine is removed from bottle creation
        await bottleService.unregisterAdapter(id: RuntimeID.simulation)
        await bottleService.unregisterAdapter(id: RuntimeID.legacySimulation)

        let runtimesAfterDisable = await bottleService.getAllRegisteredAdapters().map { $0.descriptor }
        #expect(!runtimesAfterDisable.contains { $0.id == RuntimeID.simulation }, "Simulation engine must be removed from available runtimes")
        #expect(!runtimesAfterDisable.contains { $0.id == RuntimeID.legacySimulation })

        // Verify launching the simulated game fails
        await #expect(throws: LibraryServiceError.self) {
            try await libraryService.launchGame(id: game.id)
        }
        let stateAfterRejection = await libraryService.getSessionState(for: game.id)
        #expect(stateAfterRejection == .failed, "State must transition to .failed on launch rejection")

        try? FileManager.default.removeItem(at: tempDir)
    }

    // MARK: - 2. Truthful Capabilities
    @Test("Checklist Item 2: Truthful Capabilities (DXVK/D3DMetal notes, unsupported backends blocked)")
    func testTruthfulCapabilitiesChecklist() async throws {
        // Step 1: Open Bottles → click New Bottle
        // Verify that DXVK and Apple D3DMetal appear disabled with notes stating they are not installed/distributed
        let dxvk = GraphicsBackend.dxvk
        #expect(dxvk.isSupported == false, "DXVK must not be claimed as supported out-of-the-box")
        #expect(dxvk.isInstallRequired == true, "DXVK must require manual installation")
        #expect(dxvk.displayName.contains("not installed"), "DXVK displayName must clarify it is not installed")
        #expect(dxvk.capabilityNote.contains("installed manually"), "DXVK capability note must explain configuration limitation")

        let d3dMetal = GraphicsBackend.d3dMetal
        #expect(d3dMetal.isSupported == false, "D3DMetal must not be claimed as supported")
        #expect(d3dMetal.isInstallRequired == true, "D3DMetal must require proprietary files")
        #expect(d3dMetal.displayName.contains("unsupported"), "D3DMetal displayName must clarify it is unsupported")
        #expect(d3dMetal.capabilityNote.contains("not distributed"), "D3DMetal note must truthfully state it is not distributed")

        // Verify supported backends
        #expect(GraphicsBackend.automatic.isSupported == true)
        #expect(GraphicsBackend.wineD3D.isSupported == true)

        // Step 2: Verify the Create Bottle button / validation is disabled if an unsupported backend is selected
        // In BottlesView: guard graphicsBackend.isSupported else { createError = ...; return }
        for unsupported in [GraphicsBackend.dxvk, GraphicsBackend.d3dMetal] {
            #expect(!unsupported.isSupported, "\(unsupported.displayName) must fail the isSupported check in UI create action")
        }

        // Verify runtime adapter explicitly rejects execution plans with unsupported backends
        let adapter = ControllableMockAdapter()
        let configWithD3DMetal = BottleConfiguration(graphicsBackend: .d3dMetal)
        #expect(throws: RuntimeAdapterError.self) {
            _ = try adapter.buildExecutionPlan(
                prefixURL: URL(fileURLWithPath: "/tmp/prefix"),
                executablePath: "C:\\game.exe",
                arguments: [],
                configuration: configWithD3DMetal
            )
        }
    }

    // MARK: - 3. Recoverable Stop Failure
    @Test("Checklist Item 3: Recoverable Stop Failure (unresponsive prefix -> Stop Failed red button -> Retry Stop)")
    func testRecoverableStopFailureChecklist() async throws {
        let tempDir = FileManager.default.temporaryDirectory.appendingPathComponent("ChecklistStopFail_\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: tempDir, withIntermediateDirectories: true)
        let store = MetadataStore(baseDirectory: tempDir)
        let bottleService = BottleService(metadataStore: store)
        let libraryService = LibraryService(metadataStore: store, bottleService: bottleService)

        actor PrefixHarness {
            var isStuck = true
            func setStuck(_ stuck: Bool) { isStuck = stuck }
            func checkStuck() -> Bool { isStuck }
        }
        let prefixHarness = PrefixHarness()

        let adapter = ControllableMockAdapter(
            isPrefixRunningHandler: {
                await prefixHarness.checkStuck()
            },
            stopPrefixHandler: {
                if await prefixHarness.checkStuck() {
                    throw RuntimeAdapterError.wineCommandFailed("Simulated unresponsive wineserver process")
                }
            }
        )
        await bottleService.registerAdapter(adapter)

        let bottle = try await bottleService.createBottle(name: "Hang Prefix Bottle", runtimeID: adapter.descriptor.id)
        let bottleURL = URL(fileURLWithPath: bottle.directoryPath)
        let exeURL = bottleURL.appendingPathComponent("drive_c/game.exe")
        try FileManager.default.createDirectory(at: exeURL.deletingLastPathComponent(), withIntermediateDirectories: true)
        try "dummy".data(using: .utf8)?.write(to: exeURL)

        let game = try await libraryService.addGame(name: "Hang Prefix Game", bottleID: bottle.id, executableRelativePath: "drive_c/game.exe")

        // Start game
        try await libraryService.launchGame(id: game.id)
        try await Task.sleep(nanoseconds: 100_000_000)
        #expect(await libraryService.getSessionState(for: game.id) == .running)
        #expect((await bottleService.isBottleLocked(id: bottle.id)).isLocked == true)

        // Step 1: Wine prefix becomes unresponsive during stop
        await libraryService.stopGame(id: game.id)

        // Step 2: Verify game transitions to Stop Failed (SessionState.stopFailed / "Stop Failed")
        let failedState = await libraryService.getSessionState(for: game.id)
        #expect(failedState == .stopFailed, "State must be .stopFailed")
        #expect(failedState.rawValue == "Stop Failed")

        // Step 3: Verify the bottle lock remains held until the process is successfully terminated
        let lockDuringFailure = await bottleService.isBottleLocked(id: bottle.id)
        #expect(lockDuringFailure.isLocked == true, "Bottle lock must remain held during .stopFailed")

        // Step 4: User clicks "Retry Stop" (prefix unblocks)
        await prefixHarness.setStuck(false)
        await libraryService.stopGame(id: game.id)

        // Step 5: Verify shutdown completes, state becomes .stopped, and lock is released
        let finalState = await libraryService.getSessionState(for: game.id)
        #expect(finalState == .stopped, "State must transition to .stopped after successful retry stop")
        let finalLock = await bottleService.isBottleLocked(id: bottle.id)
        #expect(finalLock.isLocked == false, "Bottle lock must be released after confirmed shutdown")

        try? FileManager.default.removeItem(at: tempDir)
    }

    // MARK: - 4. Pre-Spawn Cancellation
    @Test("Checklist Item 4: Pre-Spawn Cancellation (Click Play -> Click Stop while preparing -> process not spawned)")
    func testPreSpawnCancellationChecklist() async throws {
        let tempDir = FileManager.default.temporaryDirectory.appendingPathComponent("ChecklistPreSpawn_\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: tempDir, withIntermediateDirectories: true)
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

        // Step 1: Click Play on a game (enters preparing state and pauses at hook)
        let launchTask = Task {
            try await libraryService.launchGame(id: game.id)
        }

        // Wait until preparing state is reached
        while await libraryService.getSessionState(for: game.id) != .preparing {
            try await Task.sleep(nanoseconds: 10_000_000)
        }

        #expect(await libraryService.getSessionState(for: game.id) == .preparing)
        #expect((await bottleService.isBottleLocked(id: bottle.id)).isLocked == true)

        // Step 2: Immediately click Stop while in the preparing state
        await libraryService.stopGame(id: game.id)

        // Step 3: Open gate to allow launch task to finalize
        await gate.open()
        _ = await launchTask.result
        await libraryService.setPreSpawnHook(nil)

        // Step 4: Verify the process is not spawned and the state cleanly returns to Ready / Stopped
        let finalState = await libraryService.getSessionState(for: game.id)
        #expect(finalState == .stopped, "State must cleanly return to .stopped")

        let finalLock = await bottleService.isBottleLocked(id: bottle.id)
        #expect(finalLock.isLocked == false, "Bottle lock must be released after pre-spawn cancellation")

        try? FileManager.default.removeItem(at: tempDir)
    }
}
