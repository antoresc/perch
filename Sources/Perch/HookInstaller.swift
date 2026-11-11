import Foundation
import PerchCore

/// Puts the hook helper where Claude Code can run it and registers it in settings.json.
enum HookInstaller {
    enum InstallError: Error, CustomStringConvertible {
        case helperMissing
        var description: String { "The hook helper is missing from the app bundle. Rebuild Perch." }
    }

    static var bundledHelper: URL? {
        Bundle.main.executableURL?.deletingLastPathComponent().appendingPathComponent("perch-hook")
    }

    static var command: String {
        let path = PerchPaths.hookBinary.path
        return path.contains(" ") ? "\"\(path)\"" : path
    }

    static func isInstalled() -> Bool {
        guard FileManager.default.isExecutableFile(atPath: PerchPaths.hookBinary.path),
              let root = try? HookSettings.read(PerchPaths.settingsFile) else { return false }
        return HookSettings.isInstalled(in: root)
    }

    static func install() throws {
        try copyHelper()
        let fm = FileManager.default
        let root = try HookSettings.read(PerchPaths.settingsFile)
        // Keep the very first pre-Perch copy; never overwrite it with a later one.
        if fm.fileExists(atPath: PerchPaths.settingsFile.path), !fm.fileExists(atPath: PerchPaths.settingsBackup.path) {
            try fm.copyItem(at: PerchPaths.settingsFile, to: PerchPaths.settingsBackup)
        }
        try HookSettings.write(HookSettings.install(into: root, command: command), to: PerchPaths.settingsFile)
    }

    /// Removes our entries from settings.json. The helper file stays: sessions that are already
    /// running still call it until they restart, and without the app it does nothing.
    static func remove() throws {
        let root = try HookSettings.read(PerchPaths.settingsFile)
        try HookSettings.write(HookSettings.remove(from: root), to: PerchPaths.settingsFile)
    }

    /// After a rebuild, replace the installed helper if it differs from the bundled one.
    static func refreshHelperIfNeeded() {
        guard isInstalled(), let src = bundledHelper,
              let a = try? Data(contentsOf: src),
              let b = try? Data(contentsOf: PerchPaths.hookBinary), a != b else { return }
        try? copyHelper()
    }

    private static func copyHelper() throws {
        let fm = FileManager.default
        guard let src = bundledHelper, fm.fileExists(atPath: src.path) else { throw InstallError.helperMissing }
        let dst = PerchPaths.hookBinary
        try fm.createDirectory(at: dst.deletingLastPathComponent(), withIntermediateDirectories: true)
        // Copy to a temp name and rename, so a hook that is running right now never sees a half-written file.
        let tmp = dst.deletingLastPathComponent().appendingPathComponent(".perch-hook.tmp")
        try? fm.removeItem(at: tmp)
        try fm.copyItem(at: src, to: tmp)
        try fm.setAttributes([.posixPermissions: 0o755], ofItemAtPath: tmp.path)
        _ = try fm.replaceItemAt(dst, withItemAt: tmp)
    }
}
