import Foundation

public struct TokenCount: Equatable {
    public var input = 0
    public var output = 0
    public var cacheCreation = 0
    public var cacheRead = 0

    public init(input: Int = 0, output: Int = 0, cacheCreation: Int = 0, cacheRead: Int = 0) {
        self.input = input
        self.output = output
        self.cacheCreation = cacheCreation
        self.cacheRead = cacheRead
    }

    /// Tokens actually processed fresh: everything except cheap re-reads of cached context.
    public var fresh: Int { input + output + cacheCreation }

    public static func += (l: inout TokenCount, r: TokenCount) {
        l.input += r.input
        l.output += r.output
        l.cacheCreation += r.cacheCreation
        l.cacheRead += r.cacheRead
    }
}

public struct UsageEntry: Equatable {
    public let date: Date
    public let sessionID: String
    /// Identifies one model reply; the same reply can appear on several transcript lines.
    public let key: String?
    public let tokens: TokenCount
}

public struct UsageSummary: Equatable {
    public var last5h = TokenCount()
    public var today = TokenCount()
    public var perSession: [String: TokenCount] = [:]
    public init() {}
}

public enum UsageParser {
    private static let needle = Data("\"usage\"".utf8)

    private static let withFraction: ISO8601DateFormatter = {
        let f = ISO8601DateFormatter()
        f.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        return f
    }()
    private static let plain = ISO8601DateFormatter()

    /// Reads one transcript line. Lines without token usage return nil.
    public static func parse(line: Data) -> UsageEntry? {
        guard line.range(of: needle) != nil,
              let obj = (try? JSONSerialization.jsonObject(with: line)) as? [String: Any],
              let msg = obj["message"] as? [String: Any],
              let usage = msg["usage"] as? [String: Any],
              let ts = obj["timestamp"] as? String,
              let date = withFraction.date(from: ts) ?? plain.date(from: ts)
        else { return nil }

        func n(_ k: String) -> Int { (usage[k] as? NSNumber)?.intValue ?? 0 }
        let tokens = TokenCount(input: n("input_tokens"), output: n("output_tokens"),
                                cacheCreation: n("cache_creation_input_tokens"),
                                cacheRead: n("cache_read_input_tokens"))
        var key: String?
        if let mid = msg["id"] as? String {
            key = mid + ":" + (obj["requestId"] as? String ?? "")
        }
        return UsageEntry(date: date, sessionID: obj["sessionId"] as? String ?? "", key: key, tokens: tokens)
    }
}

/// Adds up token usage from Claude Code's transcript files. Read-only, and it only reads
/// what was appended since the last pass. Not thread-safe: call from one queue.
public final class UsageScanner {
    private var offsets: [String: UInt64] = [:]
    private var keyed: [String: UsageEntry] = [:]
    private var unkeyed: [UsageEntry] = []

    public init() {}

    /// Scans every .jsonl under `root` changed since `modifiedSince`, plus any file already being followed.
    public func refresh(root: URL, modifiedSince: Date) {
        let keys: [URLResourceKey] = [.contentModificationDateKey, .fileSizeKey]
        guard let walker = FileManager.default.enumerator(at: root, includingPropertiesForKeys: keys,
                                                          options: [.skipsHiddenFiles]) else { return }
        for case let url as URL in walker where url.pathExtension == "jsonl" {
            guard let v = try? url.resourceValues(forKeys: Set(keys)),
                  let modified = v.contentModificationDate,
                  let size = v.fileSize else { continue }
            let path = url.path
            if offsets[path] == nil && modified < modifiedSince { continue }
            var offset = offsets[path] ?? 0
            if UInt64(size) < offset { offset = 0 }
            if UInt64(size) == offset { continue }
            ingest(url, from: offset)
        }
    }

    private func ingest(_ url: URL, from offset: UInt64) {
        offsets[url.path] = offset
        guard let handle = try? FileHandle(forReadingFrom: url) else { return }
        defer { try? handle.close() }
        do { try handle.seek(toOffset: offset) } catch { return }
        guard let data = try? handle.readToEnd(), !data.isEmpty,
              let lastNewline = data.lastIndex(of: 0x0A) else { return }
        // Only whole lines; a half-written last line is picked up next time.
        let complete = data[data.startIndex...lastNewline]
        for line in complete.split(separator: 0x0A) {
            guard let entry = UsageParser.parse(line: line) else { continue }
            if let key = entry.key { keyed[key] = entry } else { unkeyed.append(entry) }
        }
        offsets[url.path] = offset + UInt64(complete.count)
    }

    public func summary(now: Date = Date(), calendar: Calendar = .current) -> UsageSummary {
        var s = UsageSummary()
        let fiveHoursAgo = now.addingTimeInterval(-5 * 3600)
        let midnight = calendar.startOfDay(for: now)
        func add(_ e: UsageEntry) {
            if e.date >= fiveHoursAgo && e.date <= now { s.last5h += e.tokens }
            if e.date >= midnight && e.date <= now { s.today += e.tokens }
            if !e.sessionID.isEmpty { s.perSession[e.sessionID, default: TokenCount()] += e.tokens }
        }
        keyed.values.forEach(add)
        unkeyed.forEach(add)
        return s
    }
}

public enum TokenFormat {
    /// 950 → "950", 18 200 → "18k", 1 234 000 → "1.2M"
    public static func short(_ n: Int) -> String {
        if n < 1_000 { return "\(n)" }
        if n < 1_000_000 { return "\(Int((Double(n) / 1_000).rounded()))k" }
        return String(format: "%.1fM", Double(n) / 1_000_000)
    }
}
