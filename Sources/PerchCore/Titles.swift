import Foundation

/// What the Claude desktop app knows about one of its sessions.
public struct DesktopSession: Equatable {
    /// The app's own id for the session ("local_…"), used to open it.
    public let localID: String
    public let title: String?

    /// The link that makes the Claude app show this session, or nil if the id looks wrong.
    public var openURL: URL? {
        let allowed = CharacterSet(charactersIn: "abcdefghijklmnopqrstuvwxyzABCDEFGHIJKLMNOPQRSTUVWXYZ0123456789_-")
        guard localID.hasPrefix("local_"), localID.count < 80,
              localID.unicodeScalars.allSatisfy(allowed.contains) else { return nil }
        return URL(string: "claude://code/continue?session=\(localID)")
    }
}

/// Reads the Claude desktop app's session records (read-only) to learn each conversation's
/// name and the id needed to open it. Only re-reads files that changed. Call from one queue.
public final class DesktopSessionIndex {
    private var seen: [String: Date] = [:]
    private var byCLI: [String: DesktopSession] = [:]

    public init() {}

    public func refresh(root: URL) {
        let keys: [URLResourceKey] = [.contentModificationDateKey]
        guard let walker = FileManager.default.enumerator(at: root, includingPropertiesForKeys: keys,
                                                          options: [.skipsHiddenFiles]) else { return }
        for case let url as URL in walker {
            guard url.pathExtension == "json", url.lastPathComponent.hasPrefix("local_"),
                  let modified = (try? url.resourceValues(forKeys: Set(keys)))?.contentModificationDate
            else { continue }
            if seen[url.path] == modified { continue }
            seen[url.path] = modified
            guard let data = try? Data(contentsOf: url),
                  let obj = (try? JSONSerialization.jsonObject(with: data)) as? [String: Any],
                  let local = obj["sessionId"] as? String,
                  let cli = obj["cliSessionId"] as? String, !cli.isEmpty else { continue }
            let title = (obj["title"] as? String).flatMap { $0.isEmpty ? nil : $0 }
            byCLI[cli] = DesktopSession(localID: local, title: title)
        }
    }

    /// Looks a session up by the id Claude Code's hooks report.
    public func session(for cliSessionID: String) -> DesktopSession? {
        byCLI[cliSessionID]
    }
}

/// Finds a conversation's name in its transcript file, for sessions the desktop app doesn't know
/// (ones started in a terminal).
public enum TranscriptTitle {
    public static func read(path: String, tailBytes: UInt64 = 400_000) -> String? {
        guard let handle = FileHandle(forReadingAtPath: path) else { return nil }
        defer { try? handle.close() }
        guard let size = try? handle.seekToEnd() else { return nil }
        try? handle.seek(toOffset: size > tailBytes ? size - tailBytes : 0)
        guard let data = try? handle.readToEnd() else { return nil }

        let titleNeedle = Data("\"custom-title\"".utf8)
        let promptNeedle = Data("\"last-prompt\"".utf8)
        var lastPrompt: String?
        for line in data.split(separator: 0x0A).reversed() {
            if line.range(of: titleNeedle) != nil,
               let obj = (try? JSONSerialization.jsonObject(with: line)) as? [String: Any],
               let title = obj["customTitle"] as? String, !title.isEmpty {
                return title
            }
            if lastPrompt == nil, line.range(of: promptNeedle) != nil,
               let obj = (try? JSONSerialization.jsonObject(with: line)) as? [String: Any],
               let prompt = obj["lastPrompt"] as? String, !prompt.isEmpty {
                lastPrompt = prompt
            }
        }
        guard let prompt = lastPrompt else { return nil }
        let oneLine = prompt.split(whereSeparator: \.isNewline).joined(separator: " ")
        return oneLine.count <= 60 ? oneLine : String(oneLine.prefix(60)) + "…"
    }
}
