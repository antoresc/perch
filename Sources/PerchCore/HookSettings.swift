import Foundation

/// Adds and removes Perch's entries in Claude Code's settings.json without disturbing anyone else's.
public enum HookSettings {
    /// Any hook command containing this text is ours.
    public static let marker = "perch-hook"

    /// How long Claude Code lets the helper wait for the user's click, in seconds (12 hours, plus
    /// a margin over the helper's own limit). A question left unanswered stays answerable in Perch
    /// that long; answering in Claude itself ends the wait at once.
    public static let permissionTimeout = HookClient.defaultReplyTimeout + 10

    /// How long Claude Code lets the helper hold the end of a turn, in seconds.
    public static let stopTimeout = HookClient.stopReplyTimeout + 10

    struct Spec {
        let event: String
        let matchesTools: Bool
        let timeout: Int?
    }

    static let specs: [Spec] = [
        Spec(event: "SessionStart", matchesTools: false, timeout: nil),
        Spec(event: "UserPromptSubmit", matchesTools: false, timeout: nil),
        Spec(event: "PreToolUse", matchesTools: true, timeout: nil),
        Spec(event: "PostToolUse", matchesTools: true, timeout: nil),
        Spec(event: "PermissionRequest", matchesTools: true, timeout: permissionTimeout),
        Spec(event: "Notification", matchesTools: false, timeout: nil),
        Spec(event: "Stop", matchesTools: false, timeout: stopTimeout),
        Spec(event: "SessionEnd", matchesTools: false, timeout: nil),
        Spec(event: "PreCompact", matchesTools: false, timeout: nil),
    ]

    public static var eventNames: [String] { specs.map(\.event) }

    public static func install(into root: [String: Any], command: String) -> [String: Any] {
        var root = remove(from: root)
        var hooks = root["hooks"] as? [String: Any] ?? [:]
        for spec in specs {
            var groups = hooks[spec.event] as? [Any] ?? []
            var hook: [String: Any] = ["type": "command", "command": command]
            if let t = spec.timeout { hook["timeout"] = t }
            var group: [String: Any] = ["hooks": [hook]]
            if spec.matchesTools { group["matcher"] = "*" }
            groups.append(group)
            hooks[spec.event] = groups
        }
        root["hooks"] = hooks
        return root
    }

    public static func remove(from root: [String: Any]) -> [String: Any] {
        var root = root
        guard var hooks = root["hooks"] as? [String: Any] else { return root }
        for (event, value) in hooks {
            guard let groups = value as? [Any] else { continue }
            var kept: [Any] = []
            for g in groups {
                guard var group = g as? [String: Any], let inner = group["hooks"] as? [Any] else {
                    kept.append(g)
                    continue
                }
                let others = inner.filter { !isOurs($0) }
                if others.count == inner.count {
                    kept.append(g)
                } else if !others.isEmpty {
                    group["hooks"] = others
                    kept.append(group)
                }
            }
            if kept.isEmpty { hooks.removeValue(forKey: event) } else { hooks[event] = kept }
        }
        if hooks.isEmpty { root.removeValue(forKey: "hooks") } else { root["hooks"] = hooks }
        return root
    }

    /// True when every event Perch needs has one of our entries.
    public static func isInstalled(in root: [String: Any]) -> Bool {
        guard let hooks = root["hooks"] as? [String: Any] else { return false }
        for spec in specs {
            guard let groups = hooks[spec.event] as? [Any] else { return false }
            let found = groups.contains { g in
                ((g as? [String: Any])?["hooks"] as? [Any] ?? []).contains(where: isOurs)
            }
            if !found { return false }
        }
        return true
    }

    /// True when our hooks are installed but were written by an older Perch with a different
    /// waiting time, so "Install" should be run again.
    public static func isOutdated(in root: [String: Any]) -> Bool {
        guard isInstalled(in: root), let hooks = root["hooks"] as? [String: Any] else { return false }
        for spec in specs {
            for g in hooks[spec.event] as? [Any] ?? [] {
                for hook in (g as? [String: Any])?["hooks"] as? [Any] ?? [] where isOurs(hook) {
                    if ((hook as? [String: Any])?["timeout"] as? Int) != spec.timeout { return true }
                }
            }
        }
        return false
    }

    private static func isOurs(_ hook: Any) -> Bool {
        ((hook as? [String: Any])?["command"] as? String)?.contains(marker) ?? false
    }

    // MARK: File access

    public enum FileError: Error, CustomStringConvertible {
        case notAnObject
        public var description: String { "settings.json is not a JSON object; left untouched." }
    }

    /// Reads settings.json. A missing file is an empty object; a broken one throws so we never overwrite it.
    public static func read(_ url: URL) throws -> [String: Any] {
        guard FileManager.default.fileExists(atPath: url.path) else { return [:] }
        let data = try Data(contentsOf: url)
        if data.isEmpty { return [:] }
        guard let obj = try JSONSerialization.jsonObject(with: data) as? [String: Any] else {
            throw FileError.notAnObject
        }
        return obj
    }

    public static func write(_ root: [String: Any], to url: URL) throws {
        let data = try JSONSerialization.data(withJSONObject: root,
                                              options: [.prettyPrinted, .sortedKeys, .withoutEscapingSlashes])
        try FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
        try data.write(to: url, options: .atomic)
    }
}
