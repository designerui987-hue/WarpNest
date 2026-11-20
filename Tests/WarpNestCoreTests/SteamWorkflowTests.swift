import XCTest
import CryptoKit
@testable import WarpNestCore

final class SteamWorkflowTests: XCTestCase {
    var tempDir: URL!

    override func setUp() async throws {
        try await super.setUp()
        tempDir = FileManager.default.temporaryDirectory.appendingPathComponent("SteamWorkflowTests_\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: tempDir, withIntermediateDirectories: true)
    }

    override func tearDown() async throws {
        if let tempDir = tempDir {
            try? FileManager.default.removeItem(at: tempDir)
        }
        try await super.tearDown()
    }

    // MARK: - Downloader & Checksum Tests

    func testComputeSHA256AndVerifyChecksum() throws {
        let service = SteamDownloaderService()
        let sampleData = "SteamSetup-Test-Verification-Data-2026".data(using: .utf8)!
        let sampleFile = tempDir.appendingPathComponent("test_installer.bin")
        try sampleData.write(to: sampleFile)

        // Compute expected hash via CryptoKit directly
        let expectedDigest = SHA256.hash(data: sampleData).map { String(format: "%02x", $0) }.joined()

        let computed = try service.computeSHA256(for: sampleFile)
        XCTAssertEqual(computed, expectedDigest)

        XCTAssertTrue(service.verifyChecksum(fileURL: sampleFile, expectedHash: expectedDigest))
        XCTAssertFalse(service.verifyChecksum(fileURL: sampleFile, expectedHash: "0000000000000000000000000000000000000000000000000000000000000000"))
    }

    final class ProgressBox: @unchecked Sendable {
        var called = false
    }

    func testDownloadSkipsWhenVerifiedCacheHit() async throws {
        let service = SteamDownloaderService()
        let sampleData = "Official-Steam-Verified-Bytes".data(using: .utf8)!
        let destURL = tempDir.appendingPathComponent("SteamSetup.exe")
        try sampleData.write(to: destURL)

        let expectedHash = SHA256.hash(data: sampleData).map { String(format: "%02x", $0) }.joined()

        let progressBox = ProgressBox()
        // Point source URL to invalid endpoint to ensure network is NOT touched on cache hit
        let invalidURL = URL(string: "https://127.0.0.1:9/invalid.exe")!

        let resultURL = try await service.downloadSteamInstaller(
            from: invalidURL,
            to: destURL,
            expectedHash: expectedHash,
            onProgress: { _, _, fraction in
                if fraction >= 1.0 { progressBox.called = true }
            }
        )

        XCTAssertEqual(resultURL.path, destURL.path)
        XCTAssertTrue(progressBox.called)
    }

    // MARK: - ACF Manifest Parsing & Discovery Tests

    func testParseACFManifest() {
        let sampleACF = """
        "AppState"
        {
            "appid"        "440"
            "Universe"        "1"
            "name"        "Team Fortress 2"
            "installdir"        "Team Fortress 2"
            "StateFlags"        "4"
            "LastUpdated"        "1672531199"
        }
        """

        let discovery = SteamAppDiscoveryService()
        let parsed = discovery.parseACFManifest(sampleACF)

        XCTAssertEqual(parsed["appid"], "440")
        XCTAssertEqual(parsed["name"], "Team Fortress 2")
        XCTAssertEqual(parsed["installdir"], "Team Fortress 2")
        XCTAssertEqual(parsed["stateflags"], "4")
    }

    func testDiscoverGamesInBottlePrefix() async throws {
        let bottleURL = tempDir.appendingPathComponent("SteamBottle")
        let steamapps = bottleURL.appendingPathComponent("drive_c/Program Files (x86)/Steam/steamapps", isDirectory: true)
        let gameDir = steamapps.appendingPathComponent("common/Half-Life 2", isDirectory: true)
        try FileManager.default.createDirectory(at: gameDir, withIntermediateDirectories: true)

        // Write appmanifest_220.acf
        let manifest = """
        "AppState"
        {
            "appid"        "220"
            "name"        "Half-Life 2"
            "installdir"        "Half-Life 2"
        }
        """
        try manifest.write(to: steamapps.appendingPathComponent("appmanifest_220.acf"), atomically: true, encoding: .utf8)

        // Create hl2.exe
        let exeURL = gameDir.appendingPathComponent("hl2.exe")
        try "MZ-MOCK-HL2".write(to: exeURL, atomically: true, encoding: .utf8)

        let bottle = Bottle(
            id: BottleID(),
            name: "Steam",
            runtimeID: .simulation,
            directoryPath: bottleURL.path,
            configuration: BottleConfiguration(win64: true)
        )

        let discovery = SteamAppDiscoveryService()
        let discovered = discovery.discoverGames(in: bottle)

        XCTAssertEqual(discovered.count, 1)
        let game = try XCTUnwrap(discovered.first)
        XCTAssertEqual(game.appID, "220")
        XCTAssertEqual(game.name, "Half-Life 2")
        XCTAssertEqual(game.installDir, "Half-Life 2")
        XCTAssertEqual(game.relativeExecutablePath, "drive_c/Program Files (x86)/Steam/steamapps/common/Half-Life 2/hl2.exe")
    }

    // MARK: - End-to-End Discovery to Library Shortcut Handoff

    func testDiscoveredGameToLibraryShortcut() async throws {
        let store = MetadataStore(baseDirectory: tempDir)
        let bottleService = BottleService(metadataStore: store)
        let libraryService = LibraryService(metadataStore: store, bottleService: bottleService)

        let bottleURL = tempDir.appendingPathComponent("TestBottle")
        let driveC = bottleURL.appendingPathComponent("drive_c/Program Files (x86)/Steam/steamapps/common/Portal", isDirectory: true)
        try FileManager.default.createDirectory(at: driveC, withIntermediateDirectories: true)

        let portalExe = driveC.appendingPathComponent("portal.exe")
        try "MZ-PORTAL".write(to: portalExe, atomically: true, encoding: .utf8)

        let bottle = Bottle(
            id: BottleID(),
            name: "Steam Test",
            runtimeID: .simulation,
            directoryPath: bottleURL.path,
            configuration: BottleConfiguration(win64: true)
        )
        try await store.save([bottle], to: "bottles.json")
        _ = try await bottleService.loadBottles()

        let discovered = DiscoveredSteamGame(
            appID: "400",
            name: "Portal",
            installDir: "Portal",
            relativeExecutablePath: "drive_c/Program Files (x86)/Steam/steamapps/common/Portal/portal.exe",
            bottleID: bottle.id
        )

        let added = try await libraryService.addGame(
            name: discovered.name,
            bottleID: discovered.bottleID,
            executableRelativePath: try XCTUnwrap(discovered.relativeExecutablePath),
            isInstaller: false
        )

        XCTAssertEqual(added.name, "Portal")
        XCTAssertFalse(added.isInstaller)
        XCTAssertEqual(added.executableRelativePath, "drive_c/Program Files (x86)/Steam/steamapps/common/Portal/portal.exe")

        let allGames = try await libraryService.loadGames()
        XCTAssertEqual(allGames.count, 1)
        XCTAssertEqual(allGames.first?.name, "Portal")
        XCTAssertEqual(allGames.first?.isInstaller, false)
    }
}
