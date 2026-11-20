import Foundation

/// Represents a game discovered inside a bottle's Steam installation.
public struct DiscoveredSteamGame: Identifiable, Sendable, Equatable {
    public let id: UUID
    public let appID: String
    public let name: String
    public let installDir: String
    public let relativeExecutablePath: String?
    public let bottleID: BottleID

    public init(
        id: UUID = UUID(),
        appID: String,
        name: String,
        installDir: String,
        relativeExecutablePath: String?,
        bottleID: BottleID
    ) {
        self.id = id
        self.appID = appID
        self.name = name
        self.installDir = installDir
        self.relativeExecutablePath = relativeExecutablePath
        self.bottleID = bottleID
    }
}

/// Service that discovers installed Steam games from `appmanifest_*.acf` files in bottle prefixes.
public struct SteamAppDiscoveryService: Sendable {
    public init() {}

    /// Parses Valve KeyValues ACF file content into key-value string pairs.
    public func parseACFManifest(_ content: String) -> [String: String] {
        var result: [String: String] = [:]
        let lines = content.components(separatedBy: .newlines)

        let pattern = #"^\s*"([^"]+)"\s*"([^"]*)""#
        guard let regex = try? NSRegularExpression(pattern: pattern) else { return result }

        for line in lines {
            let trimmed = line.trimmingCharacters(in: .whitespaces)
            let range = NSRange(location: 0, length: trimmed.utf16.count)
            if let match = regex.firstMatch(in: trimmed, range: range), match.numberOfRanges == 3 {
                if let keyRange = Range(match.range(at: 1), in: trimmed),
                   let valRange = Range(match.range(at: 2), in: trimmed) {
                    let key = String(trimmed[keyRange]).lowercased()
                    let val = String(trimmed[valRange])
                    result[key] = val
                }
            }
        }
        return result
    }

    /// Searches standard steamapps directory locations inside a bottle prefix.
    public func findSteamappsDirectories(in bottleURL: URL) -> [URL] {
        let candidates = [
            "drive_c/Program Files (x86)/Steam/steamapps",
            "drive_c/Program Files/Steam/steamapps",
            "drive_c/Steam/steamapps"
        ]
        var found: [URL] = []
        for rel in candidates {
            let url = bottleURL.appendingPathComponent(rel, isDirectory: true)
            if FileManager.default.fileExists(atPath: url.path) {
                found.append(url)
            }
        }
        return found
    }

    /// Discovers all installed Steam games in the specified bottle.
    public func discoverGames(in bottle: Bottle) -> [DiscoveredSteamGame] {
        let bottleURL = URL(fileURLWithPath: bottle.directoryPath)
        let steamappsDirs = findSteamappsDirectories(in: bottleURL)
        var discovered: [DiscoveredSteamGame] = []

        let fileManager = FileManager.default

        for steamapps in steamappsDirs {
            guard let contents = try? fileManager.contentsOfDirectory(at: steamapps, includingPropertiesForKeys: nil) else {
                continue
            }

            for file in contents where file.lastPathComponent.hasPrefix("appmanifest_") && file.pathExtension.lowercased() == "acf" {
                guard let text = try? String(contentsOf: file, encoding: .utf8) else { continue }
                let parsed = parseACFManifest(text)

                guard let appID = parsed["appid"], let name = parsed["name"], !name.isEmpty else {
                    continue
                }
                let installDir = parsed["installdir"] ?? name

                // Locate executable inside common/<installdir>
                let commonDir = steamapps.appendingPathComponent("common", isDirectory: true).appendingPathComponent(installDir, isDirectory: true)
                let relativeExe = findPrimaryExecutable(in: commonDir, bottleURL: bottleURL)

                let item = DiscoveredSteamGame(
                    appID: appID,
                    name: name,
                    installDir: installDir,
                    relativeExecutablePath: relativeExe,
                    bottleID: bottle.id
                )
                discovered.append(item)
            }
        }

        return discovered.sorted { $0.name.localizedCaseInsensitiveCompare($1.name) == .orderedAscending }
    }

    /// Locates the primary executable in a game's install folder, returning its relative path inside the bottle.
    private func findPrimaryExecutable(in gameDir: URL, bottleURL: URL) -> String? {
        let fileManager = FileManager.default
        guard fileManager.fileExists(atPath: gameDir.path) else { return nil }

        let resolvedBottle = bottleURL.resolvingSymlinksInPath().path
        let bottlePrefix = resolvedBottle.hasSuffix("/") ? resolvedBottle : resolvedBottle + "/"

        // Check top level of game dir first for .exe files
        if let contents = try? fileManager.contentsOfDirectory(at: gameDir, includingPropertiesForKeys: nil) {
            let exes = contents.filter { $0.pathExtension.lowercased() == "exe" }
            if let primary = exes.first(where: {
                let name = $0.lastPathComponent.lowercased()
                return !name.contains("unins") && !name.contains("setup") && !name.contains("crash") && !name.contains("update")
            }) ?? exes.first {
                let resolved = primary.resolvingSymlinksInPath().path
                if resolved.hasPrefix(bottlePrefix) {
                    return String(resolved.dropFirst(bottlePrefix.count))
                }
            }
        }

        // Search recursively if not found in root
        if let enumerator = fileManager.enumerator(at: gameDir, includingPropertiesForKeys: [.isRegularFileKey], options: [.skipsHiddenFiles]) {
            for case let url as URL in enumerator {
                if url.pathExtension.lowercased() == "exe" {
                    let name = url.lastPathComponent.lowercased()
                    if !name.contains("unins") && !name.contains("setup") && !name.contains("crash") && !name.contains("update") {
                        let resolved = url.resolvingSymlinksInPath().path
                        if resolved.hasPrefix(bottlePrefix) {
                            return String(resolved.dropFirst(bottlePrefix.count))
                        }
                    }
                }
            }
        }

        return nil
    }
}
