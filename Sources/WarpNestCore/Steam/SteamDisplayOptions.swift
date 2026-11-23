import Foundation

public enum SteamDisplayOptions {
    public static let softwareRendering = ["-cef-disable-gpu", "-cef-disable-gpu-compositing", "-cef-disable-d3d11"]

    public static func isClient(_ path: String) -> Bool {
        URL(fileURLWithPath: path).lastPathComponent.caseInsensitiveCompare("steam.exe") == .orderedSame
    }

    static func launchArguments(path: String, saved: [String]) -> [String] {
        guard isClient(path) else { return saved }
        let clientArguments = saved.filter { $0.caseInsensitiveCompare("/S") != .orderedSame }
        let previousPresets = [
            ["-cef-disable-gpu", "-cef-disable-gpu-compositing", "-no-cef-sandbox"],
            softwareRendering + ["-no-cef-sandbox"]
        ]
        return previousPresets.contains(clientArguments) ? softwareRendering : clientArguments
    }
}
