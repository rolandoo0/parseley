import AppKit

struct AppInfo {
    let name: String
    let icon: NSImage
}

/// Resolves bundle ids ("com.apple.Safari") to a display name and icon, cached because
/// rows ask for this on every render.
@MainActor
final class AppInfoCache {
    private var cache: [String: AppInfo?] = [:]

    func info(for bundleID: String?) -> AppInfo? {
        guard let bundleID else { return nil }
        if let cached = cache[bundleID] { return cached }

        var info: AppInfo?
        if let url = NSWorkspace.shared.urlForApplication(withBundleIdentifier: bundleID) {
            let name = FileManager.default.displayName(atPath: url.path)
                .replacingOccurrences(of: ".app", with: "")
            let icon = NSWorkspace.shared.icon(forFile: url.path)
            icon.size = NSSize(width: 32, height: 32)
            info = AppInfo(name: name, icon: icon)
        }
        cache[bundleID] = info
        return info
    }
}
