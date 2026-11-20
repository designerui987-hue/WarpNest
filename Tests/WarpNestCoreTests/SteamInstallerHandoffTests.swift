import Testing
import Foundation
@testable import WarpNestCore

@Suite("Steam Installer Handoff Tests")
struct SteamInstallerHandoffTests {

    // MARK: - 1. Success Flow
    @Test("Steam installer success handoff: locates Steam.exe, confirms handoff, persists target, and launches Steam")
    func testSteamInstallerSuccessHandoffAndLaunch() async throws {
        let tempDir = FileManager.default.temporaryDirectory.appendingPathComponent("SteamHandoffSuccess_\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: tempDir, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: tempDir) }

        let store = MetadataStore(baseDirectory: tempDir)
        let bottleService = BottleService(metadataStore: store)
        let libraryService = LibraryService(metadataStore: store, bottleService: bottleService)

        // 1. Set up simulated runtime
        let adapter = TestRuntimeAdapter()
        await bottleService.registerAdapter(adapter)

        // 2. Create dedicated bottle
        let bottle = try await bottleService.createBottle(
            name: "Steam Bottle",
            runtimeID: adapter.descriptor.id
        )
        let bottleURL = URL(fileURLWithPath: bottle.directoryPath)

        // 3. Create mock external SteamSetup.exe
        let externalSetupURL = tempDir.appendingPathComponent("SteamSetup.exe")
        try "MZ-MOCK-STEAM-SETUP".data(using: .utf8)?.write(to: externalSetupURL)

        // 4. Add Steam installer shortcut to library
        let installerGame = try await libraryService.addGame(
            name: "Steam Setup",
            bottleID: bottle.id,
            executableRelativePath: externalSetupURL.path,
            isExternalExecutable: true,
            isInstaller: true
        )
        #expect(installerGame.isExternalExecutable == true)
        #expect(installerGame.isInstaller == true)

        // 5. Run setup: simulated installer executes and writes installed Steam.exe inside the bottle
        let steamInstallDir = bottleURL.appendingPathComponent("drive_c/Program Files (x86)/Steam", isDirectory: true)
        try FileManager.default.createDirectory(at: steamInstallDir, withIntermediateDirectories: true)
        let steamExeURL = steamInstallDir.appendingPathComponent("steam.exe")
        try "MZ-MOCK-STEAM-CLIENT-EXE".data(using: .utf8)?.write(to: steamExeURL)

        try await libraryService.launchGame(id: installerGame.id)
        while await libraryService.getSessionState(for: installerGame.id) != .stopped {
            try await Task.sleep(nanoseconds: 10_000_000)
        }

        // 6. After setup exits, locate Steam.exe inside the selected bottle
        let detected = await libraryService.locateInstalledExecutable(named: "Steam.exe", for: installerGame.id)
        #expect(detected != nil, "Steam.exe must be located inside the bottle prefix")
        #expect(detected?.lowercased().hasSuffix("steam.exe") == true)

        // 7. User confirms handoff: update and persist the launch target
        guard let detectedRelPath = detected else { return }
        let updatedGame = try await libraryService.updateGameTarget(
            id: installerGame.id,
            newExecutableRelativePath: detectedRelPath,
            isExternal: false,
            newName: "Steam",
            isInstaller: false
        )

        #expect(updatedGame.name == "Steam")
        #expect(updatedGame.executableRelativePath == detectedRelPath)
        #expect(updatedGame.isExternalExecutable == false)
        #expect(updatedGame.isInstaller == false)

        // 8. Launch the installed Steam client
        try await libraryService.launchGame(id: updatedGame.id)
        while await libraryService.getSessionState(for: updatedGame.id) != .stopped {
            try await Task.sleep(nanoseconds: 10_000_000)
        }
        #expect(await libraryService.getSessionState(for: updatedGame.id) == .stopped)
    }

    // MARK: - 2. Cancellation & Failure Flow
    @Test("Steam installer cancellation: preserves environment, releases bottle lock, and enables retry")
    func testSteamInstallerCancellationPreservesEnvironment() async throws {
        let tempDir = FileManager.default.temporaryDirectory.appendingPathComponent("SteamHandoffCancel_\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: tempDir, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: tempDir) }

        let store = MetadataStore(baseDirectory: tempDir)
        let bottleService = BottleService(metadataStore: store)
        let libraryService = LibraryService(metadataStore: store, bottleService: bottleService)

        // 1. Set up simulated runner that stays active until cancelled
        let mockRunnerURL = tempDir.appendingPathComponent("mock_installer_runner.sh")
        let script = "#!/bin/sh\nexec sleep 60\n"
        try script.data(using: .utf8)?.write(to: mockRunnerURL)
        try FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: mockRunnerURL.path)

        let adapter = TestRuntimeAdapter(simulatedBinaryURL: mockRunnerURL)
        await bottleService.registerAdapter(adapter)

        // 2. Create bottle
        let bottle = try await bottleService.createBottle(
            name: "Steam Cancel Bottle",
            runtimeID: adapter.descriptor.id
        )
        let bottleURL = URL(fileURLWithPath: bottle.directoryPath)

        // 3. Add external installer
        let externalSetupURL = tempDir.appendingPathComponent("SteamSetup.exe")
        try "MZ-MOCK-SETUP".data(using: .utf8)?.write(to: externalSetupURL)
        let installerGame = try await libraryService.addGame(
            name: "Steam Setup",
            bottleID: bottle.id,
            executableRelativePath: externalSetupURL.path,
            isExternalExecutable: true,
            isInstaller: true
        )

        // 4. Launch setup
        try await libraryService.launchGame(id: installerGame.id)
        while await libraryService.getSessionState(for: installerGame.id) != .running {
            try await Task.sleep(nanoseconds: 10_000_000)
        }
        #expect(await libraryService.getSessionState(for: installerGame.id) == .running)
        #expect((await bottleService.isBottleLocked(id: bottle.id)).isLocked == true)

        // 5. User cancels / stops installer during execution
        await libraryService.stopGame(id: installerGame.id)
        while await libraryService.getSessionState(for: installerGame.id) != .stopped {
            try await Task.sleep(nanoseconds: 10_000_000)
        }

        // 6. Verify environment is preserved: bottle directory, prefix files, and configuration are intact
        #expect(FileManager.default.fileExists(atPath: bottleURL.path), "Bottle environment must be preserved")
        #expect(FileManager.default.fileExists(atPath: bottleURL.appendingPathComponent("drive_c").path))
        #expect((await bottleService.isBottleLocked(id: bottle.id)).isLocked == false, "Bottle lock must be released on cancellation")

        // 7. Steam.exe was NOT created: locateInstalledExecutable returns nil
        let detected = await libraryService.locateInstalledExecutable(named: "Steam.exe", for: installerGame.id)
        #expect(detected == nil, "Steam.exe must not be found when installation is cancelled")

        // 8. Installer shortcut remains intact and can be retried in the same preserved environment
        let savedGame = await libraryService.getGame(id: installerGame.id)
        #expect(savedGame?.isInstaller == true)
        #expect(savedGame?.executableRelativePath == externalSetupURL.path)
    }

    // MARK: - 3. Cold-Start Relaunch After Restart
    @Test("Steam relaunch after cold restart: preserves updated Steam target across app restart and relaunches directly")
    func testSteamRelaunchAfterColdRestart() async throws {
        let tempDir = FileManager.default.temporaryDirectory.appendingPathComponent("SteamColdRestart_\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: tempDir, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: tempDir) }

        let store = MetadataStore(baseDirectory: tempDir)

        // --- Phase A: Perform install & handoff ---
        let bottleServiceA = BottleService(metadataStore: store)
        let libraryServiceA = LibraryService(metadataStore: store, bottleService: bottleServiceA)

        let adapter = TestRuntimeAdapter()
        await bottleServiceA.registerAdapter(adapter)

        let bottle = try await bottleServiceA.createBottle(name: "Steam Bottle", runtimeID: adapter.descriptor.id)
        let bottleURL = URL(fileURLWithPath: bottle.directoryPath)

        let externalSetup = tempDir.appendingPathComponent("SteamSetup.exe")
        try "MZ-SETUP".data(using: .utf8)?.write(to: externalSetup)

        let installerGame = try await libraryServiceA.addGame(
            name: "Steam Setup",
            bottleID: bottle.id,
            executableRelativePath: externalSetup.path,
            isExternalExecutable: true,
            isInstaller: true
        )

        // Create installed steam.exe
        let steamDir = bottleURL.appendingPathComponent("drive_c/Program Files (x86)/Steam", isDirectory: true)
        try FileManager.default.createDirectory(at: steamDir, withIntermediateDirectories: true)
        let steamExe = steamDir.appendingPathComponent("Steam.exe")
        try "MZ-REAL-STEAM".data(using: .utf8)?.write(to: steamExe)

        // Complete handoff
        let detected = await libraryServiceA.locateInstalledExecutable(named: "Steam.exe", for: installerGame.id)
        #expect(detected != nil)
        guard let relPath = detected else { return }

        _ = try await libraryServiceA.updateGameTarget(
            id: installerGame.id,
            newExecutableRelativePath: relPath,
            isExternal: false,
            newName: "Steam",
            isInstaller: false
        )

        // --- Phase B: Simulate Cold Restart of WarpNest ---
        // Completely new services rehydrated from metadataStore
        let bottleServiceB = BottleService(metadataStore: store)
        let libraryServiceB = LibraryService(metadataStore: store, bottleService: bottleServiceB)
        await bottleServiceB.registerAdapter(adapter)

        let reloadedBottles = try await bottleServiceB.loadBottles()
        let reloadedGames = try await libraryServiceB.loadGames()

        #expect(reloadedBottles.count == 1)
        #expect(reloadedGames.count == 1)

        let steamGame = reloadedGames[0]
        #expect(steamGame.name == "Steam")
        #expect(steamGame.executableRelativePath == relPath)
        #expect(steamGame.isExternalExecutable == false)
        #expect(steamGame.isInstaller == false)

        // Verify direct launch of installed Steam client after cold start
        try await libraryServiceB.launchGame(id: steamGame.id)
        while await libraryServiceB.getSessionState(for: steamGame.id) != .stopped {
            try await Task.sleep(nanoseconds: 10_000_000)
        }
        #expect(await libraryServiceB.getSessionState(for: steamGame.id) == .stopped)
    }

    // MARK: - 4. Standalone Game Path Unchanged
    @Test("Standalone game path remains unchanged and does not trigger installer handoff")
    func testStandaloneGamePathUnchanged() async throws {
        let tempDir = FileManager.default.temporaryDirectory.appendingPathComponent("StandaloneTest_\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: tempDir, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: tempDir) }

        let store = MetadataStore(baseDirectory: tempDir)
        let bottleService = BottleService(metadataStore: store)
        let libraryService = LibraryService(metadataStore: store, bottleService: bottleService)

        let adapter = TestRuntimeAdapter()
        await bottleService.registerAdapter(adapter)

        let bottle = try await bottleService.createBottle(name: "Gaming Bottle", runtimeID: adapter.descriptor.id)
        let bottleURL = URL(fileURLWithPath: bottle.directoryPath)
        let gameExe = bottleURL.appendingPathComponent("drive_c/Games/CustomGame/game.exe")
        try FileManager.default.createDirectory(at: gameExe.deletingLastPathComponent(), withIntermediateDirectories: true)
        try "MZ-GAME".data(using: .utf8)?.write(to: gameExe)

        let standalone = try await libraryService.addGame(
            name: "Custom Game",
            bottleID: bottle.id,
            executableRelativePath: "drive_c/Games/CustomGame/game.exe"
        )

        #expect(standalone.isInstaller == false)
        #expect(standalone.isExternalExecutable == false)

        try await libraryService.launchGame(id: standalone.id)
        while await libraryService.getSessionState(for: standalone.id) != .stopped {
            try await Task.sleep(nanoseconds: 10_000_000)
        }
        #expect(await libraryService.getSessionState(for: standalone.id) == .stopped)
    }
}
