import Foundation

/// A question Claude is asking the user, with its answer choices.
public struct Question: Equatable {
    public struct Option: Equatable {
        public let label: String
        public let detail: String
    }

    public let text: String
    public let multiSelect: Bool
    public let options: [Option]

    static func parse(_ input: [String: Any]) -> [Question] {
        guard let raw = input["questions"] as? [[String: Any]] else { return [] }
        return raw.compactMap { q in
            guard let text = q["question"] as? String, !text.isEmpty else { return nil }
            let options = (q["options"] as? [[String: Any]] ?? []).compactMap { o -> Option? in
                guard let label = o["label"] as? String, !label.isEmpty else { return nil }
                return Option(label: label, detail: o["description"] as? String ?? "")
            }
            return Question(text: text, multiSelect: q["multiSelect"] as? Bool ?? false, options: options)
        }
    }
}

/// One Claude Code hook event, reduced to the fields Perch shows.
public struct HookEvent: Equatable {
    public enum Kind: String {
        case sessionStart = "SessionStart"
        case userPromptSubmit = "UserPromptSubmit"
        case preToolUse = "PreToolUse"
        case postToolUse = "PostToolUse"
        case permissionRequest = "PermissionRequest"
        case notification = "Notification"
        case stop = "Stop"
        case subagentStop = "SubagentStop"
        case sessionEnd = "SessionEnd"
        case preCompact = "PreCompact"
    }

    public let kind: Kind
    public let sessionID: String
    public let cwd: String?
    public let transcriptPath: String?
    public let toolName: String?
    public let toolSummary: String?
    public let notificationType: String?
    /// Set when the tool is Claude asking the user a question.
    public let questions: [Question]
    /// The tool's input exactly as received, needed to send an answer back.
    public let toolInputJSON: Data?

    public static let questionTool = "AskUserQuestion"

    public init(kind: Kind, sessionID: String, cwd: String? = nil, transcriptPath: String? = nil,
                toolName: String? = nil, toolSummary: String? = nil, notificationType: String? = nil,
                questions: [Question] = [], toolInputJSON: Data? = nil) {
        self.questions = questions
        self.toolInputJSON = toolInputJSON
        self.kind = kind
        self.sessionID = sessionID
        self.cwd = cwd
        self.transcriptPath = transcriptPath
        self.toolName = toolName
        self.toolSummary = toolSummary
        self.notificationType = notificationType
    }

    /// Parses the JSON Claude Code passes to a hook on stdin. Unknown events return nil.
    public init?(json data: Data) {
        guard let obj = (try? JSONSerialization.jsonObject(with: data)) as? [String: Any],
              let name = obj["hook_event_name"] as? String,
              let kind = Kind(rawValue: name),
              let sid = obj["session_id"] as? String, !sid.isEmpty
        else { return nil }
        self.kind = kind
        self.sessionID = sid
        self.cwd = obj["cwd"] as? String
        self.transcriptPath = obj["transcript_path"] as? String
        self.toolName = obj["tool_name"] as? String
        if let input = obj["tool_input"] as? [String: Any] {
            self.toolSummary = HookEvent.summarize(input: input)
            self.toolInputJSON = try? JSONSerialization.data(withJSONObject: input, options: [.sortedKeys])
            self.questions = toolName == HookEvent.questionTool ? Question.parse(input) : []
        } else {
            self.toolSummary = nil
            self.toolInputJSON = nil
            self.questions = []
        }
        self.notificationType = obj["notification_type"] as? String
    }

    /// The one line worth showing for a tool call: the command, file or URL it acts on.
    public static func summarize(input: [String: Any]) -> String {
        for key in ["command", "file_path", "notebook_path", "url", "pattern", "query", "description", "prompt"] {
            if let s = input[key] as? String, !s.isEmpty { return clip(s) }
        }
        if !input.isEmpty,
           let d = try? JSONSerialization.data(withJSONObject: input, options: [.sortedKeys]),
           let s = String(data: d, encoding: .utf8) {
            return clip(s)
        }
        return ""
    }

    static func clip(_ s: String, limit: Int = 1500) -> String {
        s.count <= limit ? s : String(s.prefix(limit)) + "…"
    }
}

/// The exact JSON a PermissionRequest hook prints to answer for the user.
public enum PermissionReply {
    public static func allow() -> Data {
        encode(["behavior": "allow"])
    }

    /// Answers a question on the user's behalf: the original input plus an `answers` map
    /// from each question's text to the chosen label(s).
    public static func answer(toolInputJSON: Data, answers: [String: String]) -> Data? {
        guard var input = (try? JSONSerialization.jsonObject(with: toolInputJSON)) as? [String: Any] else { return nil }
        input["answers"] = answers
        return encode(["behavior": "allow", "updatedInput": input])
    }

    public static func deny(message: String = "Denied from Perch") -> Data {
        encode(["behavior": "deny", "message": message])
    }

    private static func encode(_ decision: [String: Any]) -> Data {
        let out: [String: Any] = [
            "hookSpecificOutput": [
                "hookEventName": "PermissionRequest",
                "decision": decision,
            ]
        ]
        return (try? JSONSerialization.data(withJSONObject: out, options: [.sortedKeys])) ?? Data()
    }
}
