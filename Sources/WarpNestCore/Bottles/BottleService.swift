import Foundation

/// Errors that can occur during bottle lifecycle operations.
public enum BottleServiceError: Error, LocalizedError, Sendable {
    case bottleNotFound(BottleID)
    case duplicateBottleName(String)
    case runtimeNotFound(RuntimeID)
    case runtimeUnverified(RuntimeID)
    case bottleBusy(BottleID, String)
    case invalidBackupArchive(String)
    case archiveTraversalDetected(String)
    case configurationMismatch(String)
    case directoryNotEmpty(String)
    case subprocessTimedOut(String)

    public var errorDescription: String? {
        switch self {
        case .bottleNotFound(let id):
            return "Bottle with ID '\(id)' was not found."
        case .duplicateBottleName(let name):
            return "A bottle with name '\(name)' already exists."
        case .runtimeNotFound(let id):
            return "Compatibility runtime '\(id)' was not found or is unregistered."
        case .runtimeUnverified(let id):
            return "Compatibility runtime '\(id)' has not passed executable validation on this Mac."
        case .bottleBusy(let id, let reason):
            return "Bottle '\(id)' cannot perform this operation: \(reason)"
        case .invalidBackupArchive(let reason):
            return "Backup archive is invalid: \(reason)"
        case .archiveTraversalDetected(let path):
            return "Malicious archive entry rejected (path traversal attempt): \(path)"
        case .configurationMismatch(let msg):
            return "Configuration error: \(msg)"
        case .directoryNotEmpty(let path):
            return "Directory at path is not empty: \(path)"
        case .subprocessTimedOut(let details):
            return "Subprocess timed out: \(details)"
        }
    }
}

/// Token representing an acquired lock lease on a bottle.
public struct BottleLockLease: Sendable, Equatable {
    public let id: UUID
    public let bottleID: BottleID
    public let reason: String

    public init(id: UUID = UUID(), bottleID: BottleID, reason: String) {
        self.id = id
        self.bottleID = bottleID
        self.reason = reason
    }
}

/// Thread-safe accumulator for subprocess output draining (WN-02).
private final class SubprocessOutputAccumulator: @unchecked Sendable {
    private let lock = NSLock()
    private var data = Data()

    func append(_ chunk: Data) {
        lock.lock()
        data.append(chunk)
        lock.unlock()
    }

    func extractString() -> String {
        lock.lock()
        defer { lock.unlock() }
        return String(data: data, encoding: .utf8) ?? ""
    }
}

/// Actor managing bottle directories, serialization of per-bottle operations, and safe backup/restore.
public actor BottleService {
    private let metadataStore: MetadataStore
    private var bottles: [BottleID: Bottle] = [:]
    private var activeLocks: [BottleID: BottleLockLease] = [:]
    private var runtimeAdapters: [RuntimeID: any RuntimeAdapter] = [:]

    public init(metadataStore: MetadataStore) {
        self.metadataStore = metadataStore
    }

    public func registerAdapter(_ adapter: any RuntimeAdapter) {
        runtimeAdapters[adapter.descriptor.id] = adapter
    }

    public func unregisterAdapter(id: RuntimeID) {
        runtimeAdapters.removeValue(forKey: id)
    }

    public func getAdapter(for id: RuntimeID) -> (any RuntimeAdapter)? {
        runtimeAdapters[id]
    }

    public func getAllRegisteredAdapters() -> [any RuntimeAdapter] {
        Array(runtimeAdapters.values)
    }

    /// Acquires an exclusive lock lease on a bottle with a unique owner token (WN-05).
    public func acquireLock(id: BottleID, reason: String) throws -> BottleLockLease {
        if let existing = activeLocks[id] {
            throw BottleServiceError.bottleBusy(id, existing.reason)
        }
        let lease = BottleLockLease(bottleID: id, reason: reason)
        activeLocks[id] = lease
        return lease
    }

    /// Releases a lock only if the supplied lease matches the current active owner token (WN-05).
    public func releaseLock(lease: BottleLockLease) -> Bool {
        if let current = activeLocks[lease.bottleID], current.id == lease.id {
            activeLocks.removeValue(forKey: lease.bottleID)
            return true
        }
        return false
    }

    public func lockBottle(id: BottleID, reason: String) throws {
        _ = try acquireLock(id: id, reason: reason)
    }

    public func unlockBottle(id: BottleID, leaseID: UUID? = nil) {
        if let leaseID = leaseID {
            if activeLocks[id]?.id == leaseID {
                activeLocks.removeValue(forKey: id)
            }
        } else {
            activeLocks.removeValue(forKey: id)
        }
    }

    public func isBottleLocked(id: BottleID) -> (isLocked: Bool, reason: String?) {
        if let r = activeLocks[id] {
            return (true, r.reason)
        }
        return (false, nil)
    }

    public func loadBottles() async throws -> [Bottle] {
        let fileURL = metadataStore.baseDirectory.appendingPathComponent("bottles.json")
        let rawContent = try? String(contentsOf: fileURL, encoding: .utf8)
        let loaded = try await metadataStore.load([Bottle].self, from: "bottles.json", fallback: [])
        for b in loaded {
            bottles[b.id] = b
        }
        // If raw file stored the legacy simulation runtime ID, re-persist with canonical simulation ID
        if let rawContent = rawContent, rawContent.contains(RuntimeID.legacySimulation.rawValue) {
            try? await persistBottles()
        }
        return loaded
    }

    private func persistBottles() async throws {
        let list = Array(bottles.values).sorted { $0.createdAt < $1.createdAt }
        try await metadataStore.save(list, to: "bottles.json")
    }

    /// Searches a bottle's Windows drive_c hierarchy for a named executable (e.g. "Steam.exe").
    /// Returns the relative path inside the bottle prefix (e.g. "drive_c/Program Files (x86)/Steam/steam.exe").
    public func locateInstalledExecutable(named name: String, in bottleID: BottleID) -> String? {
        guard let bottle = bottles[bottleID] else { return nil }
        let bottleURL = URL(fileURLWithPath: bottle.directoryPath)
        let driveC = bottleURL.appendingPathComponent("drive_c", isDirectory: true)

        let targetLower = name.lowercased()

        // 1. Standard known locations first for instant resolution
        let wellKnownCandidates = [
            "drive_c/Program Files (x86)/Steam/Steam.exe",
            "drive_c/Program Files (x86)/Steam/steam.exe",
            "drive_c/Program Files/Steam/Steam.exe",
            "drive_c/Program Files/Steam/steam.exe"
        ]
        for rel in wellKnownCandidates where URL(fileURLWithPath: rel).lastPathComponent.lowercased() == targetLower {
            let fullURL = bottleURL.appendingPathComponent(rel)
            if FileManager.default.fileExists(atPath: fullURL.path) {
                return rel
            }
        }

        // 2. Recursive search within drive_c
        guard FileManager.default.fileExists(atPath: driveC.path) else { return nil }
        let resolvedBottle = bottleURL.resolvingSymlinksInPath().path
        let bottlePrefix = resolvedBottle.hasSuffix("/") ? resolvedBottle : resolvedBottle + "/"

        if let enumerator = FileManager.default.enumerator(
            at: driveC,
            includingPropertiesForKeys: [.isRegularFileKey],
            options: [.skipsHiddenFiles]
        ) {
            for case let fileURL as URL in enumerator {
                if fileURL.lastPathComponent.lowercased() == targetLower {
                    let resolvedFile = fileURL.resolvingSymlinksInPath().path
                    if resolvedFile.hasPrefix(bottlePrefix) {
                        return String(resolvedFile.dropFirst(bottlePrefix.count))
                    }
                }
            }
        }
        return nil
    }

    /// Creates a new bottle prefix and runs initialization via the assigned runtime adapter.
    public func createBottle(
        name: String,
        runtimeID: RuntimeID,
        configuration: BottleConfiguration = BottleConfiguration(),
        logBuffer: LogRingBuffer = LogRingBuffer()
    ) async throws -> Bottle {
        let trimmedName = name.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !bottles.values.contains(where: { $0.name.caseInsensitiveCompare(trimmedName) == .orderedSame }) else {
            throw BottleServiceError.duplicateBottleName(trimmedName)
        }

        guard let adapter = runtimeAdapters[runtimeID] else {
            throw BottleServiceError.runtimeNotFound(runtimeID)
        }

        guard adapter.descriptor.isVerified else {
            throw BottleServiceError.runtimeUnverified(runtimeID)
        }

        let newID = BottleID()
        let safeFolderName = "bottle_" + newID.rawValue.uuidString
        let bottleURL = metadataStore.baseDirectory
            .appendingPathComponent("Bottles", isDirectory: true)
            .appendingPathComponent(safeFolderName, isDirectory: true)

        let bottle = Bottle(
            id: newID,
            name: trimmedName,
            runtimeID: runtimeID,
            directoryPath: bottleURL.path,
            configuration: configuration,
            createdAt: Date()
        )

        bottles[newID] = bottle
        try lockBottle(id: newID, reason: "Initializing Wine prefix")
        defer { unlockBottle(id: newID) }

        do {
            try await adapter.initializePrefix(at: bottleURL, configuration: configuration, logBuffer: logBuffer)
            // Save bottle metadata config file directly inside bottle directory
            let configURL = bottleURL.appendingPathComponent("warpnest_bottle.json")
            let enc = JSONEncoder()
            enc.outputFormatting = [.prettyPrinted]
            let configData = try enc.encode(bottle)
            try configData.write(to: configURL, options: .atomic)

            try await persistBottles()
            return bottle
        } catch {
            bottles.removeValue(forKey: newID)
            try? FileManager.default.removeItem(at: bottleURL)
            throw error
        }
    }

    /// Subprocess execution with continuous pipe draining to prevent pipe backpressure deadlocks (WN-02)
    /// and strict deadline enforcement (P2).
    func executeSubprocess(
        executableURL: URL,
        arguments: [String],
        currentDirectoryURL: URL? = nil,
        timeoutSeconds: TimeInterval = 120
    ) async throws -> (exitCode: Int32, stdoutString: String, stderrString: String) {
        let p = Process()
        p.executableURL = executableURL
        p.arguments = arguments
        if let cwd = currentDirectoryURL {
            p.currentDirectoryURL = cwd
        }

        let outPipe = Pipe()
        let errPipe = Pipe()
        p.standardOutput = outPipe
        p.standardError = errPipe

        let outAccumulator = SubprocessOutputAccumulator()
        let errAccumulator = SubprocessOutputAccumulator()

        outPipe.fileHandleForReading.readabilityHandler = { handle in
            let chunk = handle.availableData
            guard !chunk.isEmpty else { return }
            outAccumulator.append(chunk)
        }

        errPipe.fileHandleForReading.readabilityHandler = { handle in
            let chunk = handle.availableData
            guard !chunk.isEmpty else { return }
            errAccumulator.append(chunk)
        }

        do {
            try p.run()
        } catch {
            outPipe.fileHandleForReading.readabilityHandler = nil
            errPipe.fileHandleForReading.readabilityHandler = nil
            throw error
        }

        final class SubprocessTimeoutState: @unchecked Sendable {
            private let lock = NSLock()
            private var timedOut = false
            func setTimedOut() {
                lock.lock()
                timedOut = true
                lock.unlock()
            }
            func isTimedOut() -> Bool {
                lock.lock()
                defer { lock.unlock() }
                return timedOut
            }
        }

        let timeoutState = SubprocessTimeoutState()
        let timeoutTask = Task {
            let ns = UInt64(max(timeoutSeconds, 0.1) * 1_000_000_000)
            try? await Task.sleep(nanoseconds: ns)
            if p.isRunning {
                timeoutState.setTimedOut()
                p.terminate()
                try? await Task.sleep(nanoseconds: 500_000_000)
                if p.isRunning {
                    kill(p.processIdentifier, SIGKILL)
                }
            }
        }

        let exitStatus: Int32 = await withCheckedContinuation { continuation in
            p.terminationHandler = { proc in
                continuation.resume(returning: proc.terminationStatus)
            }
        }
        timeoutTask.cancel()

        outPipe.fileHandleForReading.readabilityHandler = nil
        errPipe.fileHandleForReading.readabilityHandler = nil

        // Strictly non-blocking drain of any remaining bytes in pipe buffers
        func drainNonBlocking(handle: FileHandle) -> Data {
            let fd = handle.fileDescriptor
            let flags = fcntl(fd, F_GETFL)
            if flags >= 0 {
                _ = fcntl(fd, F_SETFL, flags | O_NONBLOCK)
            }
            var accumulated = Data()
            var buf = [UInt8](repeating: 0, count: 4096)
            while true {
                let bytesRead = read(fd, &buf, buf.count)
                if bytesRead > 0 {
                    accumulated.append(buf, count: bytesRead)
                } else {
                    break
                }
            }
            try? handle.close()
            return accumulated
        }

        let remOut = drainNonBlocking(handle: outPipe.fileHandleForReading)
        let remErr = drainNonBlocking(handle: errPipe.fileHandleForReading)
        if !remOut.isEmpty { outAccumulator.append(remOut) }
        if !remErr.isEmpty { errAccumulator.append(remErr) }

        if timeoutState.isTimedOut() {
            throw BottleServiceError.subprocessTimedOut("\(executableURL.lastPathComponent) exceeded deadline of \(Int(timeoutSeconds))s")
        }

        return (exitStatus, outAccumulator.extractString(), errAccumulator.extractString())
    }

    /// Deletes a bottle only if it is completely idle and not running any games or active operations.
    public func deleteBottle(id: BottleID) async throws {
        guard let bottle = bottles[id] else {
            throw BottleServiceError.bottleNotFound(id)
        }
        if let lock = activeLocks[id] {
            throw BottleServiceError.bottleBusy(id, lock.reason)
        }

        try lockBottle(id: id, reason: "Deleting bottle")
        defer { unlockBottle(id: id) }

        // Stop prefix services before wiping
        let url = URL(fileURLWithPath: bottle.directoryPath)
        if let adapter = runtimeAdapters[bottle.runtimeID] {
            try? await adapter.stopPrefix(at: url)
        }

        // WN-08: Propagate removal errors honestly; do not drop metadata if filesystem removal fails
        if FileManager.default.fileExists(atPath: url.path) {
            do {
                try FileManager.default.removeItem(at: url)
            } catch {
                throw BottleServiceError.directoryNotEmpty("Failed to remove bottle directory at \(url.path): \(error.localizedDescription)")
            }
        }
        bottles.removeValue(forKey: id)
        try await persistBottles()
    }

    public func getBottle(id: BottleID) -> Bottle? {
        bottles[id]
    }

    public func getAllBottles() -> [Bottle] {
        Array(bottles.values).sorted { $0.name < $1.name }
    }

    /// Backs up a stopped bottle into a zip archive with staged atomic replacement (WN-02, WN-08).
    public func backupBottle(id: BottleID, destinationZipURL: URL) async throws {
        guard let bottle = bottles[id] else {
            throw BottleServiceError.bottleNotFound(id)
        }
        if let lock = activeLocks[id] {
            throw BottleServiceError.bottleBusy(id, lock.reason)
        }

        try lockBottle(id: id, reason: "Exporting backup archive")
        defer { unlockBottle(id: id) }

        let sourceURL = URL(fileURLWithPath: bottle.directoryPath)
        guard FileManager.default.fileExists(atPath: sourceURL.path) else {
            throw BottleServiceError.bottleNotFound(id)
        }

        let parentDir = destinationZipURL.deletingLastPathComponent()
        try FileManager.default.createDirectory(at: parentDir, withIntermediateDirectories: true)

        // Stage backup to temporary file; only replace destination on success (WN-08 / N21)
        let stagingZipURL = parentDir.appendingPathComponent(".staging_\(UUID().uuidString).zip")
        defer {
            try? FileManager.default.removeItem(at: stagingZipURL)
        }

        // Include bottle configuration in archive for full round-trip preservation
        let bottleMetaURL = sourceURL.appendingPathComponent("warpnest_bottle.json")
        if let data = try? JSONEncoder().encode(bottle) {
            try? data.write(to: bottleMetaURL)
        }

        // Non-blocking zip execution with concurrent pipe draining (WN-02)
        let result = try await executeSubprocess(
            executableURL: URL(fileURLWithPath: "/usr/bin/zip"),
            arguments: ["-r", "-y", stagingZipURL.path, "."],
            currentDirectoryURL: sourceURL
        )

        guard result.exitCode == 0 else {
            throw BottleServiceError.invalidBackupArchive("zip failed with code \(result.exitCode): \(result.stderrString)")
        }

        // Atomically replace destination archive so prior backup is never lost on failure
        if FileManager.default.fileExists(atPath: destinationZipURL.path) {
            _ = try FileManager.default.replaceItemAt(destinationZipURL, withItemAt: stagingZipURL)
        } else {
            try FileManager.default.moveItem(at: stagingZipURL, to: destinationZipURL)
        }
    }

    /// Restores a bottle from a zip archive with strict path traversal checking, escaping symlink validation,
    /// and prefix structure verification before registration (WN-02, WN-07, WN-08).
    public func restoreBottle(
        from zipURL: URL,
        restoredName: String,
        runtimeID: RuntimeID
    ) async throws -> Bottle {
        guard FileManager.default.fileExists(atPath: zipURL.path) else {
            throw BottleServiceError.invalidBackupArchive("Archive does not exist at \(zipURL.path)")
        }

        // 1. Inspect archive table of contents via non-blocking zipinfo (WN-02, WN-07)
        let listResult = try await executeSubprocess(
            executableURL: URL(fileURLWithPath: "/usr/bin/zipinfo"),
            arguments: ["-1", zipURL.path]
        )

        guard listResult.exitCode == 0 else {
            throw BottleServiceError.invalidBackupArchive("Unable to read archive table of contents: \(listResult.stderrString)")
        }

        let fileEntries = listResult.stdoutString.components(separatedBy: .newlines)
        for entry in fileEntries where !entry.isEmpty {
            if entry.hasPrefix("/") || entry.contains("../") || entry.contains("..\\") {
                throw BottleServiceError.archiveTraversalDetected(entry)
            }
        }

        let newID = BottleID()
        let targetURL = metadataStore.baseDirectory
            .appendingPathComponent("Bottles", isDirectory: true)
            .appendingPathComponent("bottle_" + newID.rawValue.uuidString, isDirectory: true)

        let stagingURL = targetURL.appendingPathExtension("staging")
        try FileManager.default.createDirectory(at: stagingURL, withIntermediateDirectories: true)
        defer {
            try? FileManager.default.removeItem(at: stagingURL)
        }

        // 2. Extract into staging directory using non-blocking unzip (WN-02)
        let extractResult = try await executeSubprocess(
            executableURL: URL(fileURLWithPath: "/usr/bin/unzip"),
            arguments: ["-q", zipURL.path, "-d", stagingURL.path]
        )

        guard extractResult.exitCode == 0 else {
            throw BottleServiceError.invalidBackupArchive("Extraction failed with exit code \(extractResult.exitCode): \(extractResult.stderrString)")
        }

        // 3. Inspect extracted links for link target traversal escapes (WN-07 / P04)
        try Self.validateRestoredSymbolicLinks(in: stagingURL)

        // 4. Validate prefix structure before registration (WN-07 / P06)
        let hasDriveC = FileManager.default.fileExists(atPath: stagingURL.appendingPathComponent("drive_c").path)
        let hasSystemReg = FileManager.default.fileExists(atPath: stagingURL.appendingPathComponent("system.reg").path)
        let hasConfigMeta = FileManager.default.fileExists(atPath: stagingURL.appendingPathComponent("warpnest_bottle.json").path)

        guard hasDriveC || hasSystemReg || hasConfigMeta else {
            throw BottleServiceError.invalidBackupArchive("Archive does not contain a recognized Wine prefix structure (missing drive_c, system.reg, or bottle metadata)")
        }

        // 5. Recover bottle configuration if included in archive, otherwise use defaults
        var recoveredConfig = BottleConfiguration()
        let archiveConfigURL = stagingURL.appendingPathComponent("warpnest_bottle.json")
        if let configData = try? Data(contentsOf: archiveConfigURL),
           let savedBottle = try? JSONDecoder().decode(Bottle.self, from: configData) {
            recoveredConfig = savedBottle.configuration
        }

        // 6. Promote staging directory to published bottle path atomically
        try FileManager.default.createDirectory(at: targetURL.deletingLastPathComponent(), withIntermediateDirectories: true)
        try FileManager.default.moveItem(at: stagingURL, to: targetURL)

        let restoredBottle = Bottle(
            id: newID,
            name: restoredName,
            runtimeID: runtimeID,
            directoryPath: targetURL.path,
            configuration: recoveredConfig,
            createdAt: Date()
        )

        bottles[newID] = restoredBottle
        try await persistBottles()
        return restoredBottle
    }

    /// Inspects every extracted link, including links inside macOS package directories.
    static func validateRestoredSymbolicLinks(in directoryURL: URL) throws {
        let canonicalStaging = directoryURL.resolvingSymlinksInPath()
        var enumerationError: Error?
        guard let enumerator = FileManager.default.enumerator(
            at: canonicalStaging,
            includingPropertiesForKeys: [.isSymbolicLinkKey],
            options: [],
            errorHandler: { _, error in
                enumerationError = error
                return false
            }
        ) else {
            throw BottleServiceError.invalidBackupArchive("Cannot inspect extracted archive")
        }

        while let fileURL = enumerator.nextObject() as? URL {
            let res = try fileURL.resourceValues(forKeys: [.isSymbolicLinkKey])
            if res.isSymbolicLink == true {
                let resolvedTarget = fileURL.resolvingSymlinksInPath()
                let targetPath = resolvedTarget.path
                let stagingPath = canonicalStaging.path.hasSuffix("/") ? canonicalStaging.path : canonicalStaging.path + "/"

                // Only direct drive-letter mappings in the prefix's root dosdevices directory
                // may target the host filesystem. Nested names must not inherit this exception.
                let name = Array(fileURL.lastPathComponent.utf8)
                let isDriveName = (name.count == 2 || name.count == 3)
                    && ((97...122).contains(name[0]) || (65...90).contains(name[0]))
                    && name.dropFirst().allSatisfy { $0 == 58 }
                let isDosdevicesLink = isDriveName
                    && fileURL.deletingLastPathComponent().resolvingSymlinksInPath().path
                        == canonicalStaging.appendingPathComponent("dosdevices").resolvingSymlinksInPath().path
                if targetPath != canonicalStaging.path && !targetPath.hasPrefix(stagingPath) && !isDosdevicesLink {
                    throw BottleServiceError.archiveTraversalDetected("Symlink at '\(fileURL.lastPathComponent)' targets outside restore root: \(targetPath)")
                }
            }
        }
        if let enumerationError { throw enumerationError }
    }

}
