import SwiftUI
import WarpNestCore

private func fetchCatalogInstaller(_ title: CatalogTitle, in root: URL, progress: @escaping @Sendable (Double) -> Void) async throws -> URL {
    let folder = root.appendingPathComponent("Downloads", isDirectory: true)
    let destination = folder.appendingPathComponent(title.installerName)
    let files = FileManager.default
    let verifier = SteamDownloaderService()
    if verifier.verifyChecksum(fileURL: destination, expectedHash: title.checksum) { return destination }
    let (temporary, response) = try await URLSession.shared.download(from: title.downloadURL, delegate: CatalogProgress(report: progress))
    defer { try? files.removeItem(at: temporary) }
    guard let http = response as? HTTPURLResponse, (200...299).contains(http.statusCode) else {
        throw URLError(.badServerResponse)
    }
    let hash = try verifier.computeSHA256(for: temporary)
    guard hash == title.checksum else { throw SteamDownloadError.checksumMismatch(expected: title.checksum, actual: hash) }
    try Task.checkCancellation()
    try files.createDirectory(at: folder, withIntermediateDirectories: true)
    if files.fileExists(atPath: destination.path) {
        _ = try files.replaceItemAt(destination, withItemAt: temporary)
    } else {
        try files.moveItem(at: temporary, to: destination)
    }
    return destination
}

struct CatalogTransfer: Sendable {
    let id = UUID()
    var status: String
    var target: BottleID?
    var progress: Double?
    var canRetry = false
}

extension AppViewModel {
    var realRuntimes: [RuntimeDescriptor] { registeredRuntimes.filter { $0.isVerified && !$0.isSimulation } }
    var realBottles: [Bottle] {
        let ids = Set(realRuntimes.map(\.id))
        return bottles.filter { ids.contains($0.runtimeID) }
    }

    func catalogEntry(_ title: CatalogTitle) -> GameItem? {
        let allowed = Set(realBottles.map(\.id))
        return games.first {
            let file = URL(fileURLWithPath: $0.executableRelativePath).lastPathComponent.lowercased()
            return allowed.contains($0.bottleID) && [title.executableName.lowercased(), title.installerName.lowercased()].contains(file)
        }
    }

    func downloadCatalog(_ title: CatalogTitle, target: BottleID?) {
        guard title != .steam, transferTasks[title] == nil else { return }
        guard let runtime = realRuntimes.first else {
            selectedTab = .settings
            showError("Add a Wine runtime before downloading this installer.")
            return
        }
        let transfer = CatalogTransfer(status: "Downloading installer…", target: target)
        transfers[title] = transfer
        transferTasks[title] = Task {
            defer { transferTasks[title] = nil }
            do {
                let root = await metadataStore.baseDirectory
                let file = try await fetchCatalogInstaller(title, in: root) { [weak self] fraction in
                    Task { @MainActor [weak self] in
                        guard let self, self.transfers[title]?.id == transfer.id, self.transfers[title]?.status == "Downloading installer…" else { return }
                        self.transfers[title]?.progress = fraction
                    }
                }
                try Task.checkCancellation()
                transfers[title]?.status = "Preparing library entry…"
                let bottle: Bottle
                if let target {
                    guard let existing = realBottles.first(where: { $0.id == target }) else {
                        throw BottleServiceError.bottleNotFound(target)
                    }
                    bottle = existing
                } else if let existing = realBottles.first(where: { $0.name == title.rawValue }) {
                    bottle = existing
                } else {
                    bottle = try await bottleService.createBottle(name: title.rawValue, runtimeID: runtime.id, configuration: BottleConfiguration())
                    await reloadData()
                }
                try Task.checkCancellation()
                if !games.contains(where: { $0.bottleID == bottle.id && $0.executableRelativePath == file.path }) {
                    _ = try await libraryService.addGame(name: title.rawValue + " Setup", bottleID: bottle.id,
                        executableRelativePath: file.path, isExternalExecutable: true, isInstaller: true)
                    await reloadData()
                }
                transfers[title]?.status = "Ready for setup in Library"
            } catch {
                transfers[title]?.status = Task.isCancelled ? "Cancelled" : error.localizedDescription
                transfers[title]?.canRetry = true
            }
        }
    }
}

private final class CatalogProgress: NSObject, URLSessionDownloadDelegate {
    let report: @Sendable (Double) -> Void
    init(report: @escaping @Sendable (Double) -> Void) { self.report = report }
    func urlSession(_ session: URLSession, downloadTask: URLSessionDownloadTask, didFinishDownloadingTo location: URL) {}
    func urlSession(_ session: URLSession, downloadTask: URLSessionDownloadTask, didWriteData bytesWritten: Int64,
                    totalBytesWritten: Int64, totalBytesExpectedToWrite total: Int64) {
        guard total > 0 else { return }
        let percent = Int(Double(totalBytesWritten) * 100 / Double(total))
        let prior = Int(Double(totalBytesWritten - bytesWritten) * 100 / Double(total))
        if percent != prior { report(Double(min(100, percent)) / 100) }
    }
}
