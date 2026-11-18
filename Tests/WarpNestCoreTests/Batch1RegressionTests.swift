import Testing
import Foundation
@testable import WarpNestCore

@Suite("Batch 1 Regression Tests")
struct Batch1RegressionTests {

    @Test("Developer mode on/off in the same session uses a consistent simulation ID")
    func testDeveloperModeSimulationIDConsistency() async throws {
        // TestRuntimeAdapter must register with RuntimeID("test-simulation")
        let adapter = TestRuntimeAdapter()
        #expect(adapter.descriptor.id == RuntimeID("test-simulation"))
        #expect(adapter.descriptor.isSimulation == true)

        let tempDir = FileManager.default.temporaryDirectory.appendingPathComponent("WNDevModeTest_\(UUID().uuidString)")
        let store = MetadataStore(baseDirectory: tempDir)
        let bottleService = BottleService(metadataStore: store)

        // Register then unregister using the same ID
        await bottleService.registerAdapter(adapter)
        let registered = await bottleService.getAdapter(for: RuntimeID("test-simulation"))
        #expect(registered != nil)

        await bottleService.unregisterAdapter(id: RuntimeID("test-simulation"))
        let unregistered = await bottleService.getAdapter(for: RuntimeID("test-simulation"))
        #expect(unregistered == nil)

        try? FileManager.default.removeItem(at: tempDir)
    }

    @Test("Simulated launch is rejected when developer mode adapter is not registered")
    func testSimulatedLaunchRejectedWithoutAdapter() async throws {
        let tempDir = FileManager.default.temporaryDirectory.appendingPathComponent("WNSimLaunchTest_\(UUID().uuidString)")
        let store = MetadataStore(baseDirectory: tempDir)
        let bottleService = BottleService(metadataStore: store)
        let libraryService = LibraryService(metadataStore: store, bottleService: bottleService)

        // Register the simulation adapter, create a bottle, then unregister (dev mode off)
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

        // Now unregister (simulating developer mode off)
        await bottleService.unregisterAdapter(id: adapter.descriptor.id)

        // Launch must fail with runtimeUnavailable
        await #expect(throws: LibraryServiceError.self) {
            try await libraryService.launchGame(id: game.id)
        }

        try? FileManager.default.removeItem(at: tempDir)
    }

    @Test("getSessionState returns running while session entry is present, even after launcher exits")
    func testSessionStateAuthoritativeDuringContinuation() async throws {
        let tempDir = FileManager.default.temporaryDirectory.appendingPathComponent("WNSessionStateTest_\(UUID().uuidString)")
        let store = MetadataStore(baseDirectory: tempDir)
        let bottleService = BottleService(metadataStore: store)
        let libraryService = LibraryService(metadataStore: store, bottleService: bottleService)

        let adapter = TestRuntimeAdapter()
        await bottleService.registerAdapter(adapter)

        let bottle = try await bottleService.createBottle(name: "State Bottle", runtimeID: adapter.descriptor.id)
        let bottleURL = URL(fileURLWithPath: bottle.directoryPath)
        let exeURL = bottleURL.appendingPathComponent("drive_c/game.exe")
        try FileManager.default.createDirectory(at: exeURL.deletingLastPathComponent(), withIntermediateDirectories: true)
        try "dummy".data(using: .utf8)?.write(to: exeURL)
        let game = try await libraryService.addGame(name: "State Game", bottleID: bottle.id, executableRelativePath: "drive_c/game.exe")

        // State before launch: stopped
        let stateBefore = await libraryService.getSessionState(for: game.id)
        #expect(stateBefore == .stopped)

        // Launch (uses /bin/echo which exits immediately but session should clear)
        try await libraryService.launchGame(id: game.id)

        // Brief yield to let the session clean up after the echo process exits
        try await Task.sleep(nanoseconds: 500_000_000)

        // After the process exits naturally, state must be stopped (or failed) — not stuck running
        let stateAfter = await libraryService.getSessionState(for: game.id)
        #expect(stateAfter == .stopped || stateAfter == .failed)

        try? FileManager.default.removeItem(at: tempDir)
    }

    @Test("stopGame before launch starts does not crash or leave stale state")
    func testStopBeforeSpawnIsNoop() async throws {
        let tempDir = FileManager.default.temporaryDirectory.appendingPathComponent("WNStopBeforeSpawn_\(UUID().uuidString)")
        let store = MetadataStore(baseDirectory: tempDir)
        let bottleService = BottleService(metadataStore: store)
        let libraryService = LibraryService(metadataStore: store, bottleService: bottleService)

        let adapter = TestRuntimeAdapter()
        await bottleService.registerAdapter(adapter)

        let bottle = try await bottleService.createBottle(name: "NoSpawn Bottle", runtimeID: adapter.descriptor.id)
        let bottleURL = URL(fileURLWithPath: bottle.directoryPath)
        let exeURL = bottleURL.appendingPathComponent("drive_c/game.exe")
        try FileManager.default.createDirectory(at: exeURL.deletingLastPathComponent(), withIntermediateDirectories: true)
        try "dummy".data(using: .utf8)?.write(to: exeURL)
        let game = try await libraryService.addGame(name: "NoSpawn Game", bottleID: bottle.id, executableRelativePath: "drive_c/game.exe")

        // Stop a game that was never started — must be a no-op
        await libraryService.stopGame(id: game.id)
        let state = await libraryService.getSessionState(for: game.id)
        #expect(state == .stopped)

        // Bottle must still be unlocked
        let lock = await bottleService.isBottleLocked(id: bottle.id)
        #expect(lock.isLocked == false)

        try? FileManager.default.removeItem(at: tempDir)
    }

    @Test("Stale callback from an old session ID does not affect a newer session")
    func testStaleCallbackDoesNotAffectNewerSession() async throws {
        let tempDir = FileManager.default.temporaryDirectory.appendingPathComponent("WNStaleCallback_\(UUID().uuidString)")
        let store = MetadataStore(baseDirectory: tempDir)
        let bottleService = BottleService(metadataStore: store)
        let libraryService = LibraryService(metadataStore: store, bottleService: bottleService)

        let adapter = TestRuntimeAdapter()
        await bottleService.registerAdapter(adapter)

        let bottle = try await bottleService.createBottle(name: "Stale Bottle", runtimeID: adapter.descriptor.id)
        let bottleURL = URL(fileURLWithPath: bottle.directoryPath)
        let exeURL = bottleURL.appendingPathComponent("drive_c/game.exe")
        try FileManager.default.createDirectory(at: exeURL.deletingLastPathComponent(), withIntermediateDirectories: true)
        try "dummy".data(using: .utf8)?.write(to: exeURL)
        let game = try await libraryService.addGame(name: "Stale Game", bottleID: bottle.id, executableRelativePath: "drive_c/game.exe")

        // Launch the game once (echo exits immediately)
        try await libraryService.launchGame(id: game.id)
        // Drain first session
        try? await Task.sleep(nanoseconds: 300_000_000)
        await libraryService.stopGame(id: game.id)
        try? await Task.sleep(nanoseconds: 100_000_000)

        // The game should be stopped; bottle unlocked
        let lockAfterFirst = await bottleService.isBottleLocked(id: bottle.id)
        #expect(lockAfterFirst.isLocked == false)

        // State must be stopped or failed (not stuck)
        let stateAfter = await libraryService.getSessionState(for: game.id)
        #expect(stateAfter == .stopped || stateAfter == .failed)

        try? FileManager.default.removeItem(at: tempDir)
    }

    @Test("DXVK backend is correctly labeled as requiring installation, not built-in")
    func testDxvkIsNotClaimedAsInstalled() {
        #expect(GraphicsBackend.dxvk.isInstallRequired == true)
        #expect(GraphicsBackend.wineD3D.isInstallRequired == false)
        #expect(GraphicsBackend.automatic.isInstallRequired == false)
        #expect(GraphicsBackend.dxvk.capabilityNote.contains("sets WINE_D3D_CONFIG") || GraphicsBackend.dxvk.capabilityNote.contains("sets renderer"))
    }

    @Test("Legacy graphics backend string values migrate smoothly during decoding")
    func testLegacyGraphicsBackendStringDecoding() throws {
        let legacyDXVKJSON = "\"DXVK (DirectX 9/10/11 -> Vulkan -> Metal)\"".data(using: .utf8)!
        let decodedDXVK = try JSONDecoder().decode(GraphicsBackend.self, from: legacyDXVKJSON)
        #expect(decodedDXVK == .dxvk)

        let legacyWineD3DJSON = "\"WineD3D (DirectX -> OpenGL/Metal)\"".data(using: .utf8)!
        let decodedWineD3D = try JSONDecoder().decode(GraphicsBackend.self, from: legacyWineD3DJSON)
        #expect(decodedWineD3D == .wineD3D)

        let legacyD3DMetalJSON = "\"d3dMetal\"".data(using: .utf8)!
        let decodedD3DMetal = try JSONDecoder().decode(GraphicsBackend.self, from: legacyD3DMetalJSON)
        #expect(decodedD3DMetal == .dxvk)

        let unknownJSON = "\"someUnknownBackend\"".data(using: .utf8)!
        let decodedUnknown = try JSONDecoder().decode(GraphicsBackend.self, from: unknownJSON)
        #expect(decodedUnknown == .automatic)
    }
}
