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
}

@Suite("Bottle & Library Integration Tests")
struct BottleAndLibraryTests {
    @Test("End-to-end bottle creation, game addition, and launch execution")
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

        // 2. Add an application shortcut
        let game = try await libraryService.addGame(
            name: "Solitaire",
            bottleID: bottle.id,
            executableRelativePath: "drive_c/windows/sol.exe"
        )
        #expect(game.name == "Solitaire")

        // 3. Launch the game using the test adapter
        try await libraryService.launchGame(id: game.id)

        // Check buffer logs
        let buffer = await libraryService.getLogBuffer(for: game.id)
        var logsFound = false
        for _ in 0..<20 {
            try await Task.sleep(nanoseconds: 50_000_000)
            if buffer.getJoinedText().contains("Simulated Execution") {
                logsFound = true
                break
            }
        }
        #expect(logsFound == true)

        // 4. Verify shortcut deletion does not delete bottle
        try await libraryService.removeGame(id: game.id)
        #expect(await libraryService.getGame(id: game.id) == nil)
        #expect(await bottleService.getBottle(id: bottle.id) != nil)

        // Cleanup
        try await bottleService.deleteBottle(id: bottle.id)
        try? FileManager.default.removeItem(at: tempDir)
    }

    @Test("Backup and restore bottle integrity")
    func testBackupAndRestore() async throws {
        let tempDir = FileManager.default.temporaryDirectory.appendingPathComponent("WarpNestBackupTest_\(UUID().uuidString)")
        let store = MetadataStore(baseDirectory: tempDir)
        let bottleService = BottleService(metadataStore: store)

        let testAdapter = TestRuntimeAdapter()
        await bottleService.registerAdapter(testAdapter)

        let bottle = try await bottleService.createBottle(
            name: "Archive Target Bottle",
            runtimeID: testAdapter.descriptor.id
        )

        let zipURL = tempDir.appendingPathComponent("Backups/archive.zip")
        try await bottleService.backupBottle(id: bottle.id, destinationZipURL: zipURL)
        #expect(FileManager.default.fileExists(atPath: zipURL.path))

        let restored = try await bottleService.restoreBottle(
            from: zipURL,
            restoredName: "Restored Target Bottle",
            runtimeID: testAdapter.descriptor.id
        )
        #expect(restored.name == "Restored Target Bottle")
        #expect(FileManager.default.fileExists(atPath: restored.directoryPath))

        try? FileManager.default.removeItem(at: tempDir)
    }
}
