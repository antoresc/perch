import Foundation

/// Every location Perch reads or writes. Nothing outside these paths is touched.
public enum PerchPaths {
    public static var home: URL { FileManager.default.homeDirectoryForCurrentUser }

    public static var supportDir: URL {
        home.appendingPathComponent("Library/Application Support/Perch", isDirectory: true)
    }

    /// Local socket the hook helper uses to reach the app. `PERCH_SOCKET` overrides it for tests.
    public static var socketPath: String {
        ProcessInfo.processInfo.environment["PERCH_SOCKET"]
            ?? supportDir.appendingPathComponent("perch.sock").path
    }

    public static var claudeDir: URL { home.appendingPathComponent(".claude", isDirectory: true) }
    public static var settingsFile: URL { claudeDir.appendingPathComponent("settings.json") }
    public static var settingsBackup: URL { claudeDir.appendingPathComponent("settings.json.before-perch") }
    public static var hookBinary: URL { claudeDir.appendingPathComponent("hooks/perch-hook") }
    public static var projectsDir: URL { claudeDir.appendingPathComponent("projects", isDirectory: true) }
    /// The Claude desktop app's own session records. Read-only: conversation names and ids.
    public static var desktopSessionsDir: URL {
        home.appendingPathComponent("Library/Application Support/Claude/claude-code-sessions", isDirectory: true)
    }
}
