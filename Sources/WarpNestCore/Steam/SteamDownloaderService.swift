import Foundation
import CryptoKit

/// Errors that can occur during Steam installer download and verification.
public enum SteamDownloadError: LocalizedError, Sendable, Equatable {
    case invalidSourceURL(String)
    case networkError(String)
    case downloadCancelled
    case checksumMismatch(expected: String, actual: String)
    case fileSystemError(String)

    public var errorDescription: String? {
        switch self {
        case .invalidSourceURL(let url):
            return "Invalid Steam installer source URL: \(url)"
        case .networkError(let details):
            return "Failed to download Steam installer: \(details)"
        case .downloadCancelled:
            return "Steam installer download was cancelled."
        case .checksumMismatch(let expected, let actual):
            return "Installer integrity check failed. Expected SHA-256 \(expected), but got \(actual)."
        case .fileSystemError(let details):
            return "Filesystem error while saving Steam installer: \(details)"
        }
    }
}

/// Progress callback reporting downloaded bytes, total expected bytes, and normalized fraction (0.0 - 1.0).
public typealias DownloadProgressHandler = @Sendable (Int64, Int64, Double) -> Void

/// Service responsible for securely retrieving the official SteamSetup.exe installer and validating its cryptographic integrity.
public struct SteamDownloaderService: Sendable {
    /// Official Fastly CDN endpoint for the Steam Windows setup installer.
    public static let officialEndpoint = URL(string: "https://cdn.fastly.steamstatic.com/client/installer/SteamSetup.exe")!

    /// Official SHA-256 checksum for the verified SteamSetup.exe distribution (verified Nov 2026).
    public static let verifiedSHA256 = "7d3654531c32d941b8cae81c4137fc542172bfa9635f169cb392f245a0a12bcb"

    public init() {}

    /// Calculates the lowercase hexadecimal SHA-256 hash of a file on disk.
    public func computeSHA256(for fileURL: URL) throws -> String {
        let handle = try FileHandle(forReadingFrom: fileURL)
        defer { try? handle.close() }

        var hasher = SHA256()
        while true {
            let chunk = handle.readData(ofLength: 65536)
            if chunk.isEmpty { break }
            hasher.update(data: chunk)
        }
        let digest = hasher.finalize()
        return digest.map { String(format: "%02x", $0) }.joined()
    }

    /// Validates an existing file against the expected SHA-256 checksum.
    public func verifyChecksum(fileURL: URL, expectedHash: String = SteamDownloaderService.verifiedSHA256) -> Bool {
        guard let actual = try? computeSHA256(for: fileURL) else { return false }
        return actual.lowercased() == expectedHash.lowercased()
    }

    /// Downloads the Steam installer to the destination URL with progress updates and SHA-256 verification.
    /// If an already-verified file exists at destinationURL, skips network download and returns the verified URL.
    public func downloadSteamInstaller(
        from sourceURL: URL = SteamDownloaderService.officialEndpoint,
        to destinationURL: URL,
        expectedHash: String = SteamDownloaderService.verifiedSHA256,
        onProgress: DownloadProgressHandler? = nil
    ) async throws -> URL {
        let fileManager = FileManager.default

        // 1. Check if destination already contains a verified installer
        if fileManager.fileExists(atPath: destinationURL.path) {
            if verifyChecksum(fileURL: destinationURL, expectedHash: expectedHash) {
                onProgress?(1, 1, 1.0)
                return destinationURL
            }
        }

        // 2. Prepare destination parent directory
        let parentDir = destinationURL.deletingLastPathComponent()
        try fileManager.createDirectory(at: parentDir, withIntermediateDirectories: true)

        let tempDestURL = parentDir.appendingPathComponent("SteamSetup_\(UUID().uuidString).tmp")
        defer {
            try? fileManager.removeItem(at: tempDestURL)
        }

        // 3. Perform streaming download via URLSession
        let (bytes, response) = try await URLSession.shared.bytes(from: sourceURL)
        guard let httpResponse = response as? HTTPURLResponse, (200...299).contains(httpResponse.statusCode) else {
            let status = (response as? HTTPURLResponse)?.statusCode ?? -1
            throw SteamDownloadError.networkError("Server responded with HTTP \(status)")
        }

        let expectedLength = response.expectedContentLength
        fileManager.createFile(atPath: tempDestURL.path, contents: nil)
        let writeHandle = try FileHandle(forWritingTo: tempDestURL)
        defer { try? writeHandle.close() }

        var receivedBytes: Int64 = 0
        var buffer = Data()
        buffer.reserveCapacity(65536)

        for try await byte in bytes {
            try Task.checkCancellation()
            buffer.append(byte)
            receivedBytes += 1

            if buffer.count >= 65536 {
                try writeHandle.write(contentsOf: buffer)
                buffer.removeAll(keepingCapacity: true)

                let fraction = expectedLength > 0 ? Double(receivedBytes) / Double(expectedLength) : 0.0
                onProgress?(receivedBytes, expectedLength, min(max(fraction, 0.0), 1.0))
            }
        }

        if !buffer.isEmpty {
            try writeHandle.write(contentsOf: buffer)
        }
        try writeHandle.synchronize()

        onProgress?(receivedBytes, expectedLength, 1.0)

        // 4. Verify SHA-256 integrity
        let actualHash = try computeSHA256(for: tempDestURL)
        guard actualHash.lowercased() == expectedHash.lowercased() else {
            throw SteamDownloadError.checksumMismatch(expected: expectedHash, actual: actualHash)
        }

        // 5. Atomic replacement to final destination
        if fileManager.fileExists(atPath: destinationURL.path) {
            try fileManager.removeItem(at: destinationURL)
        }
        try fileManager.moveItem(at: tempDestURL, to: destinationURL)

        return destinationURL
    }
}
