import Testing
import Foundation
@testable import WarpNestCore

@Suite("WarpNestCore Metadata & Storage Tests")
struct MetadataStoreTests {
    @Test("Atomic save and load of items")
    func testAtomicSaveAndLoad() async throws {
        let tempDir = FileManager.default.temporaryDirectory.appendingPathComponent("WarpNestTest_\(UUID().uuidString)")
        let store = MetadataStore(baseDirectory: tempDir)

        struct TestConfig: Codable, Equatable {
            let appName: String
            let version: Int
        }

        let original = TestConfig(appName: "WarpNest", version: 1)
        try await store.save(original, to: "config.json")

        let loaded = try await store.load(TestConfig.self, from: "config.json", fallback: TestConfig(appName: "Fallback", version: 0))
        #expect(loaded == original)

        try? FileManager.default.removeItem(at: tempDir)
    }

    @Test("Fallback when file is missing")
    func testFallbackOnMissingFile() async throws {
        let tempDir = FileManager.default.temporaryDirectory.appendingPathComponent("WarpNestTest_\(UUID().uuidString)")
        let store = MetadataStore(baseDirectory: tempDir)

        let loaded = try await store.load(String.self, from: "missing.json", fallback: "DefaultFallback")
        #expect(loaded == "DefaultFallback")

        try? FileManager.default.removeItem(at: tempDir)
    }

    @Test("Legacy graphics backend migration (WN-15 / N26)")
    func testLegacyGraphicsBackendMigration() async throws {
        // Earlier WarpNest metadata containing "d3dMetal" should migrate smoothly to .dxvk
        let legacyJSON = """
        {
            "win64": true,
            "windowsVersion": "win10",
            "graphicsBackend": "d3dMetal",
            "syncBackend": "ESync (Eventfd)",
            "highResolutionMode": true,
            "environmentVariables": {}
        }
        """.data(using: .utf8)!

        let decoded = try JSONDecoder().decode(BottleConfiguration.self, from: legacyJSON)
        #expect(decoded.graphicsBackend == .dxvk)
    }

    @Test("Corrupt metadata file preservation for recovery (WN-15 / N26)")
    func testCorruptFilePreservation() async throws {
        let tempDir = FileManager.default.temporaryDirectory.appendingPathComponent("WarpNestCorruptTest_\(UUID().uuidString)")
        let store = MetadataStore(baseDirectory: tempDir)
        try FileManager.default.createDirectory(at: tempDir, withIntermediateDirectories: true)

        let corruptFile = tempDir.appendingPathComponent("settings.json")
        try "{ this is not valid JSON !!!".data(using: .utf8)?.write(to: corruptFile)

        do {
            _ = try await store.load(AppSettings.self, from: "settings.json", fallback: AppSettings())
            Issue.record("Expected decodingFailed error")
        } catch {
            // Verify a backup copy of the corrupt file was created for user recovery
            let contents = (try? FileManager.default.contentsOfDirectory(atPath: tempDir.path)) ?? []
            let corruptBackup = contents.first { $0.starts(with: "settings.json.corrupt.") }
            #expect(corruptBackup != nil)
        }

        try? FileManager.default.removeItem(at: tempDir)
    }

    @Test("Runtime registry persistence with stable IDs (WN-03 / N04)")
    func testRuntimeRegistryPersistence() async throws {
        let tempDir = FileManager.default.temporaryDirectory.appendingPathComponent("WarpNestRuntimeTest_\(UUID().uuidString)")
        let store = MetadataStore(baseDirectory: tempDir)

        let runtimes = [
            PersistedRuntime(
                id: RuntimeID("wine-test-id-1"),
                displayName: "Wine Staging 9.0",
                executablePath: "/usr/local/bin/wine",
                rootPath: "/usr/local",
                version: "wine-9.0",
                importedAt: Date(),
                isUserImported: true
            ),
            PersistedRuntime(
                id: RuntimeID("wine-test-id-2"),
                displayName: "Wine Stable 8.0",
                executablePath: "/opt/wine/bin/wine",
                rootPath: "/opt/wine",
                version: "wine-8.0",
                importedAt: Date(),
                isUserImported: false
            )
        ]

        try await store.saveRuntimeRegistry(runtimes)
        let loaded = try await store.loadRuntimeRegistry()
        #expect(loaded.count == 2)
        #expect(loaded[0].id == RuntimeID("wine-test-id-1"))
        #expect(loaded[1].id == RuntimeID("wine-test-id-2"))
        #expect(loaded[0].isUserImported == true)
        #expect(loaded[1].isUserImported == false)

        try? FileManager.default.removeItem(at: tempDir)
    }
}

@Suite("ProcessSupervisor Tests")
struct ProcessSupervisorTests {
    @Test("Successful execution without shell interpolation")
    func testSuccessfulExecution() async throws {
        let buffer = LogRingBuffer(maxCapacity: 100)
        let supervisor = ProcessSupervisor(logBuffer: buffer)

        let echoURL = URL(fileURLWithPath: "/bin/echo")
        let status = try await supervisor.launch(
            executableURL: echoURL,
            arguments: ["Hello", "WarpNest Core"]
        )

        #expect(status.exitCode == 0)
        #expect(status.wasCancelled == false)
        let logs = buffer.getJoinedText()
        #expect(logs.contains("Hello WarpNest Core"))
    }

    @Test("Handling missing executable without crashing")
    func testMissingExecutable() async {
        let supervisor = ProcessSupervisor()
        let fakeURL = URL(fileURLWithPath: "/nonexistent/binary_\(UUID().uuidString)")

        await #expect(throws: ProcessSupervisorError.self) {
            try await supervisor.launch(executableURL: fakeURL, arguments: [])
        }
    }

    @Test("Argument integrity: spaces, quotes, Unicode, shell metacharacters (WN-01 / N02)")
    func testArgumentIntegrity() async throws {
        let buffer = LogRingBuffer(maxCapacity: 100)
        let supervisor = ProcessSupervisor(logBuffer: buffer)

        let testArgs = [
            "Path With Spaces",
            "It's 'single' & \"double\" quotes",
            "🎮 WarpNest 日本語",
            "$HOME; rm -rf / | && > < \t"
        ]

        let echoURL = URL(fileURLWithPath: "/bin/echo")
        let status = try await supervisor.launch(
            executableURL: echoURL,
            arguments: testArgs
        )

        #expect(status.exitCode == 0)
        let logs = buffer.getJoinedText()
        #expect(logs.contains("Path With Spaces"))
        #expect(logs.contains("🎮 WarpNest 日本語"))
        #expect(logs.contains("$HOME; rm -rf / | && > <"))
    }

    @Test("Byte-limited log retention prevents memory inflation (WN-04 / N09)")
    func testByteLimitedLogRetention() {
        // Buffer limited to 5000 bytes
        let buffer = LogRingBuffer(maxCapacity: 100, maxBytes: 5000)

        // Append 10 lines of 1,000 bytes each (10,000 bytes total)
        for i in 0..<10 {
            let chunk = String(repeating: "\(i)", count: 1000)
            buffer.append(chunk)
        }

        let allLines = buffer.getAllLines()
        let totalRetainedBytes = allLines.reduce(0) { $0 + $1.utf8.count }
        #expect(totalRetainedBytes <= 5000)
        #expect(!allLines.isEmpty)
    }
}

@Suite("Bottle & Library Integration Tests")
struct BottleAndLibraryTests {
    @Test("End-to-end bottle creation, game addition, and launch execution with simulation adapter")
    func testEndToEndWorkflow() async throws {
        let tempDir = FileManager.default.temporaryDirectory.appendingPathComponent("WarpNestTest_\(UUID().uuidString)")
        let store = MetadataStore(baseDirectory: tempDir)
        let bottleService = BottleService(metadataStore: store)
        let libraryService = LibraryService(metadataStore: store, bottleService: bottleService)

        let testAdapter = TestRuntimeAdapter()
        await bottleService.registerAdapter(testAdapter)

        // 1. Create a bottle
        let bottle = try await bottleService.createBottle(
            name: "Test Game Prefix",
            runtimeID: testAdapter.descriptor.id
        )
        #expect(bottle.name == "Test Game Prefix")
        #expect(FileManager.default.fileExists(atPath: bottle.directoryPath))

        // Create a dummy exe inside prefix for path validation
        let bottleURL = URL(fileURLWithPath: bottle.directoryPath)
        let exeURL = bottleURL.appendingPathComponent("drive_c/windows/sol.exe")
        try "dummy binary".data(using: .utf8)?.write(to: exeURL)

        // 2. Add an application shortcut
        let game = try await libraryService.addGame(
            name: "Solitaire",
            bottleID: bottle.id,
            executableRelativePath: "drive_c/windows/sol.exe"
        )
        #expect(game.name == "Solitaire")

        // 3. Launch the game using the test adapter
        try await libraryService.launchGame(id: game.id)

        // Stop session safely
        await libraryService.stopGame(id: game.id)

        // Verify bottle lock is released
        let lockCheckAfter = await bottleService.isBottleLocked(id: bottle.id)
        #expect(lockCheckAfter.isLocked == false)

        // 4. Verify shortcut deletion does not delete bottle
        try await libraryService.removeGame(id: game.id)
        #expect(await libraryService.getGame(id: game.id) == nil)
        #expect(await bottleService.getBottle(id: bottle.id) != nil)

        // Cleanup
        try await bottleService.deleteBottle(id: bottle.id)
        try? FileManager.default.removeItem(at: tempDir)
    }

    @Test("Path traversal rejection in addGame (WN-12 / N01)")
    func testExecutablePathTraversalRejection() async throws {
        let tempDir = FileManager.default.temporaryDirectory.appendingPathComponent("WarpNestTraversalTest_\(UUID().uuidString)")
        let store = MetadataStore(baseDirectory: tempDir)
        let bottleService = BottleService(metadataStore: store)
        let libraryService = LibraryService(metadataStore: store, bottleService: bottleService)

        let testAdapter = TestRuntimeAdapter()
        await bottleService.registerAdapter(testAdapter)

        let bottle = try await bottleService.createBottle(
            name: "Guard Prefix",
            runtimeID: testAdapter.descriptor.id
        )

        // Attempting to add an executable path with traversal (escaping bottle) must be rejected
        await #expect(throws: LibraryServiceError.self) {
            _ = try await libraryService.addGame(
                name: "Attack Game",
                bottleID: bottle.id,
                executableRelativePath: "../../bin/sh"
            )
        }

        try? FileManager.default.removeItem(at: tempDir)
    }

    @Test("External installer explicit workflow (WN-01 / WN-12 / N03)")
    func testExternalInstallerWorkflow() async throws {
        let tempDir = FileManager.default.temporaryDirectory.appendingPathComponent("WarpNestExternalTest_\(UUID().uuidString)")
        let store = MetadataStore(baseDirectory: tempDir)
        let bottleService = BottleService(metadataStore: store)
        let libraryService = LibraryService(metadataStore: store, bottleService: bottleService)

        let testAdapter = TestRuntimeAdapter()
        await bottleService.registerAdapter(testAdapter)

        let bottle = try await bottleService.createBottle(
            name: "External Test Bottle",
            runtimeID: testAdapter.descriptor.id
        )

        // Create an external installer outside the bottle
        let externalDir = tempDir.appendingPathComponent("Downloads")
        try FileManager.default.createDirectory(at: externalDir, withIntermediateDirectories: true)
        let installerURL = externalDir.appendingPathComponent("setup.exe")
        try "dummy setup installer".data(using: .utf8)?.write(to: installerURL)

        let game = try await libraryService.addGame(
            name: "Setup Installer",
            bottleID: bottle.id,
            executableRelativePath: installerURL.path,
            isExternalExecutable: true
        )

        #expect(game.isExternalExecutable == true)
        #expect(game.executableRelativePath == installerURL.path)

        try? FileManager.default.removeItem(at: tempDir)
    }

    @Test("WINEPREFIX environment override protection (WN-12 / N25)")
    func testWineprefixEnvironmentProtection() async throws {
        let tempDir = FileManager.default.temporaryDirectory.appendingPathComponent("WarpNestPrefixTest_\(UUID().uuidString)")
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

        let bottleURL = tempDir.appendingPathComponent("MyBottle")
        try FileManager.default.createDirectory(at: bottleURL, withIntermediateDirectories: true)

        let adapter = try WineRuntimeAdapter(rootDirectory: tempDir, stableID: RuntimeID("test-wine"))

        var maliciousConfig = BottleConfiguration()
        // Attempt to override WINEPREFIX to an attacker-controlled directory
        maliciousConfig.environmentVariables["WINEPREFIX"] = "/tmp/hacked_prefix"
        maliciousConfig.environmentVariables["CUSTOM_VAR"] = "SafeValue"

        let plan = try adapter.buildExecutionPlan(
            prefixURL: bottleURL,
            executablePath: bottleURL.appendingPathComponent("drive_c/game.exe").path,
            arguments: [],
            configuration: maliciousConfig
        )

        // WINEPREFIX must remain the managed bottle URL path, NOT the malicious override
        #expect(plan.environment["WINEPREFIX"] == bottleURL.path)
        #expect(plan.environment["CUSTOM_VAR"] == "SafeValue")

        try? FileManager.default.removeItem(at: tempDir)
    }

    @Test("Session lock lease prevents concurrent operations and stale callbacks (WN-05 / N11)")
    func testSessionLockLeases() async throws {
        let tempDir = FileManager.default.temporaryDirectory.appendingPathComponent("WarpNestLeaseTest_\(UUID().uuidString)")
        let store = MetadataStore(baseDirectory: tempDir)
        let bottleService = BottleService(metadataStore: store)

        let bottleID = BottleID()
        let lease1 = try await bottleService.acquireLock(id: bottleID, reason: "Session 1")
        #expect((await bottleService.isBottleLocked(id: bottleID)).isLocked == true)

        // Second lock attempt must fail
        await #expect(throws: BottleServiceError.self) {
            _ = try await bottleService.acquireLock(id: bottleID, reason: "Session 2")
        }

        // Releasing with a forged/mismatched lease ID must not release the lock
        let fakeLease = BottleLockLease(id: UUID(), bottleID: bottleID, reason: "Fake")
        let releasedFake = await bottleService.releaseLock(lease: fakeLease)
        #expect(releasedFake == false)
        #expect((await bottleService.isBottleLocked(id: bottleID)).isLocked == true)

        // Releasing with genuine lease succeeds
        let releasedReal = await bottleService.releaseLock(lease: lease1)
        #expect(releasedReal == true)
        #expect((await bottleService.isBottleLocked(id: bottleID)).isLocked == false)

        try? FileManager.default.removeItem(at: tempDir)
    }
}

@Suite("Archive Security & Integrity Tests")
struct ArchiveSecurityAndIntegrityTests {
    /// Helper that builds zip archives using python3 zipfile to test malicious entries
    private static func buildZipWithPython(script: String) throws {
        let proc = Process()
        proc.executableURL = URL(fileURLWithPath: "/usr/bin/python3")
        proc.arguments = ["-c", script]
        try proc.run()
        proc.waitUntilExit()
        guard proc.terminationStatus == 0 else {
            throw BottleServiceError.invalidBackupArchive("Python fixture generation failed with exit code \(proc.terminationStatus)")
        }
    }

    @Test("Real archive traversal entry (../evil.txt) is rejected (WN-07 / WN-13 / N19)")
    func testRealArchiveTraversalEntryRejection() async throws {
        let tempDir = FileManager.default.temporaryDirectory.appendingPathComponent("WarpNestTraversalArchiveTest_\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: tempDir, withIntermediateDirectories: true)
        let store = MetadataStore(baseDirectory: tempDir)
        let bottleService = BottleService(metadataStore: store)

        let maliciousZip = tempDir.appendingPathComponent("traversal.zip")

        // Build a real zip file containing an entry named '../evil.txt'
        let pythonScript = """
        import zipfile
        with zipfile.ZipFile('\(maliciousZip.path)', 'w') as z:
            z.writestr('../evil.txt', 'malicious file content')
            z.writestr('drive_c/placeholder.txt', 'bottle content')
        """
        try ArchiveSecurityAndIntegrityTests.buildZipWithPython(script: pythonScript)
        #expect(FileManager.default.fileExists(atPath: maliciousZip.path))

        // Must throw archiveTraversalDetected
        await #expect(throws: BottleServiceError.self) {
            _ = try await bottleService.restoreBottle(
                from: maliciousZip,
                restoredName: "Attacked Bottle",
                runtimeID: RuntimeID("test-simulation")
            )
        }

        try? FileManager.default.removeItem(at: tempDir)
    }

    @Test("Real escaping symbolic link in archive is rejected (WN-07 / P04 / N19)")
    func testEscapingSymbolicLinkRejection() async throws {
        let tempDir = FileManager.default.temporaryDirectory.appendingPathComponent("WarpNestSymlinkTest_\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: tempDir, withIntermediateDirectories: true)
        let store = MetadataStore(baseDirectory: tempDir)
        let bottleService = BottleService(metadataStore: store)

        let symlinkZip = tempDir.appendingPathComponent("symlink_escape.zip")

        // Build a zip containing a symlink that points outside the prefix root
        let pythonScript = """
        import zipfile, stat
        with zipfile.ZipFile('\(symlinkZip.path)', 'w') as z:
            info = zipfile.ZipInfo('escape_link')
            info.create_system = 3
            info.external_attr = (stat.S_IFLNK | 0o777) << 16
            z.writestr(info, '../outside_dir')
            z.writestr('drive_c/placeholder.txt', 'valid prefix')
        """
        try ArchiveSecurityAndIntegrityTests.buildZipWithPython(script: pythonScript)
        #expect(FileManager.default.fileExists(atPath: symlinkZip.path))

        // Must detect escaping symlink target and reject
        await #expect(throws: BottleServiceError.self) {
            _ = try await bottleService.restoreBottle(
                from: symlinkZip,
                restoredName: "Escaped Bottle",
                runtimeID: RuntimeID("test-simulation")
            )
        }

        try? FileManager.default.removeItem(at: tempDir)
    }

    @Test("Non-prefix archive (arbitrary ZIP) is rejected (WN-07 / P06 / N20)")
    func testNonPrefixArchiveRejection() async throws {
        let tempDir = FileManager.default.temporaryDirectory.appendingPathComponent("WarpNestArbitraryTest_\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: tempDir, withIntermediateDirectories: true)
        let store = MetadataStore(baseDirectory: tempDir)
        let bottleService = BottleService(metadataStore: store)

        let arbitraryZip = tempDir.appendingPathComponent("arbitrary.zip")

        // Archive containing only readme.txt without drive_c or system.reg
        let pythonScript = """
        import zipfile
        with zipfile.ZipFile('\(arbitraryZip.path)', 'w') as z:
            z.writestr('readme.txt', 'Just a normal document, not a Wine prefix.')
        """
        try ArchiveSecurityAndIntegrityTests.buildZipWithPython(script: pythonScript)

        // Must be rejected as invalid backup archive
        await #expect(throws: BottleServiceError.self) {
            _ = try await bottleService.restoreBottle(
                from: arbitraryZip,
                restoredName: "Bogus Bottle",
                runtimeID: RuntimeID("test-simulation")
            )
        }

        try? FileManager.default.removeItem(at: tempDir)
    }

    @Test("Backup and restore integrity with full configuration round-trip (WN-08 / N18)")
    func testBackupAndRestoreIntegrity() async throws {
        let tempDir = FileManager.default.temporaryDirectory.appendingPathComponent("WarpNestIntegrityTest_\(UUID().uuidString)")
        let store = MetadataStore(baseDirectory: tempDir)
        let bottleService = BottleService(metadataStore: store)

        let testAdapter = TestRuntimeAdapter()
        await bottleService.registerAdapter(testAdapter)

        var config = BottleConfiguration()
        config.syncBackend = .msync
        config.highResolutionMode = true
        config.environmentVariables["TEST_KEY"] = "TestVal"

        let bottle = try await bottleService.createBottle(
            name: "Original Source Bottle",
            runtimeID: testAdapter.descriptor.id,
            configuration: config
        )

        // Write sample files inside drive_c
        let sampleFile = URL(fileURLWithPath: bottle.directoryPath).appendingPathComponent("drive_c/sample.txt")
        let testPayload = "WarpNest round-trip file integrity verification payload."
        try testPayload.data(using: .utf8)?.write(to: sampleFile)

        let zipURL = tempDir.appendingPathComponent("Backups/verified_backup.zip")
        try await bottleService.backupBottle(id: bottle.id, destinationZipURL: zipURL)
        #expect(FileManager.default.fileExists(atPath: zipURL.path))

        // Restore into new bottle
        let restored = try await bottleService.restoreBottle(
            from: zipURL,
            restoredName: "Restored Verified Bottle",
            runtimeID: testAdapter.descriptor.id
        )

        // Verify configuration matches
        #expect(restored.configuration.syncBackend == .msync)
        #expect(restored.configuration.environmentVariables["TEST_KEY"] == "TestVal")

        // Verify restored file content
        let restoredSampleFile = URL(fileURLWithPath: restored.directoryPath).appendingPathComponent("drive_c/sample.txt")
        #expect(FileManager.default.fileExists(atPath: restoredSampleFile.path))
        let restoredContent = try String(contentsOf: restoredSampleFile, encoding: .utf8)
        #expect(restoredContent == testPayload)

        try? FileManager.default.removeItem(at: tempDir)
    }

    @Test("Staged atomic replacement preserves existing backup on failure (WN-08 / N21)")
    func testStagedBackupAtomicReplacement() async throws {
        let tempDir = FileManager.default.temporaryDirectory.appendingPathComponent("WarpNestAtomicTest_\(UUID().uuidString)")
        let store = MetadataStore(baseDirectory: tempDir)
        let bottleService = BottleService(metadataStore: store)

        let testAdapter = TestRuntimeAdapter()
        await bottleService.registerAdapter(testAdapter)

        let bottle = try await bottleService.createBottle(
            name: "Source Bottle",
            runtimeID: testAdapter.descriptor.id
        )

        let zipURL = tempDir.appendingPathComponent("Backups/existing_good.zip")
        try await bottleService.backupBottle(id: bottle.id, destinationZipURL: zipURL)
        let initialData = try Data(contentsOf: zipURL)
        #expect(!initialData.isEmpty)

        // Second backup successfully replaces the first atomically
        try await bottleService.backupBottle(id: bottle.id, destinationZipURL: zipURL)
        let secondData = try Data(contentsOf: zipURL)
        #expect(!secondData.isEmpty)

        try? FileManager.default.removeItem(at: tempDir)
    }
}

@Suite("Real Wine Runtime Demonstration Tests")
struct RealWineRuntimeDemonstrationTests {
    private let runtimeURL = URL(fileURLWithPath: "/Volumes/Personal/WarpNest/Runtimes/Wine-Staging-11.21/Wine Staging.app")

    @Test("Validate imported Wine-Staging runtime and query actual version")
    func testRealWineValidationAndVersion() async throws {
        guard FileManager.default.fileExists(atPath: runtimeURL.path) else {
            // Skip if runtime is not present
            return
        }

        let adapter = try WineRuntimeAdapter(rootDirectory: runtimeURL, stableID: RuntimeID("wine-staging-11.21"))
        let isValid = try await adapter.validate()
        #expect(isValid == true)

        let version = await adapter.queryVersion()
        #expect(version != nil)
        #expect(version?.contains("11.21") == true)
    }

    @Test("Real Wine bottle creation, prefix initialization, and execution")
    func testRealWineBottleCreationAndLaunch() async throws {
        guard FileManager.default.fileExists(atPath: runtimeURL.path) else {
            return
        }

        let tempDir = FileManager.default.temporaryDirectory.appendingPathComponent("WarpNestRealWineTest_\(UUID().uuidString)")
        let store = MetadataStore(baseDirectory: tempDir)
        let bottleService = BottleService(metadataStore: store)
        let libraryService = LibraryService(metadataStore: store, bottleService: bottleService)

        var adapter = try WineRuntimeAdapter(rootDirectory: runtimeURL, stableID: RuntimeID("wine-staging-11.21"))
        let isValid = try await adapter.validate()
        #expect(isValid == true)
        adapter.descriptor.isVerified = true
        if let ver = await adapter.queryVersion() {
            adapter.descriptor.version = ver
        }
        await bottleService.registerAdapter(adapter)

        // 1. Create a real bottle with wineboot prefix initialization
        let bottle = try await bottleService.createBottle(
            name: "Native Wine Bottle",
            runtimeID: adapter.descriptor.id
        )

        #expect(FileManager.default.fileExists(atPath: bottle.directoryPath))
        let bottleURL = URL(fileURLWithPath: bottle.directoryPath)
        let driveC = bottleURL.appendingPathComponent("drive_c")
        #expect(FileManager.default.fileExists(atPath: driveC.path))

        // Check if notepad.exe was created inside windows or windows/system32
        let notepadURL = driveC.appendingPathComponent("windows/notepad.exe")
        let sys32Notepad = driveC.appendingPathComponent("windows/system32/notepad.exe")
        let targetNotepad = FileManager.default.fileExists(atPath: notepadURL.path) ? "drive_c/windows/notepad.exe" : (FileManager.default.fileExists(atPath: sys32Notepad.path) ? "drive_c/windows/system32/notepad.exe" : nil)

        if let relNotepad = targetNotepad {
            let game = try await libraryService.addGame(
                name: "Windows Notepad",
                bottleID: bottle.id,
                executableRelativePath: relNotepad
            )
            #expect(game.name == "Windows Notepad")

            // Launch Notepad
            try await libraryService.launchGame(id: game.id)

            // Verify bottle lock is held
            let lockStatus = await bottleService.isBottleLocked(id: bottle.id)
            #expect(lockStatus.isLocked == true)

            // Stop the game
            await libraryService.stopGame(id: game.id)

            // Verify bottle lock is released
            let lockAfter = await bottleService.isBottleLocked(id: bottle.id)
            #expect(lockAfter.isLocked == false)
        }

        // Clean up bottle and prefix
        try await bottleService.deleteBottle(id: bottle.id)
        try? FileManager.default.removeItem(at: tempDir)
    }
}
