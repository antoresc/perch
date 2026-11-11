import Foundation

public enum SessionStatus: Equatable {
    case idle
    case working
    case runningTool(String)
    /// Perch is holding a permission request and can answer it.
    case needsApproval
    /// Claude is asking for something Perch cannot answer; go to the session.
    case needsYou
    case compacting
    /// Claude finished its turn and is waiting for the next message.
    case finished

    public var needsAttention: Bool { self == .needsApproval || self == .needsYou }
    public var isBusy: Bool {
        switch self {
        case .working, .runningTool, .compacting: return true
        default: return false
        }
    }
}

public struct Session: Identifiable, Equatable {
    public let id: String
    public var cwd: String
    public var transcriptPath: String?
    public var status: SessionStatus
    public var detail: String?
    public var updatedAt: Date

    public var projectName: String {
        let name = (cwd as NSString).lastPathComponent
        return name.isEmpty ? "Claude" : name
    }
}

/// The list of live sessions. A pure state machine: events in, state and side-effect requests out.
public struct SessionBoard: Equatable {
    public enum Effect: Equatable {
        /// Claude wants the user: play the sound.
        case attention
        /// Pending approvals for this session are no longer needed. A nil tool means all of them.
        case clearApprovals(session: String, tool: String?, summary: String?)
    }

    /// Tools that mean "Claude is waiting for the user's answer".
    static let questionTools: Set<String> = ["AskUserQuestion", "ExitPlanMode"]

    public private(set) var sessions: [Session] = []

    public init() {}

    public mutating func apply(_ e: HookEvent, now: Date = Date()) -> [Effect] {
        if e.kind == .sessionEnd {
            sessions.removeAll { $0.id == e.sessionID }
            return [.clearApprovals(session: e.sessionID, tool: nil, summary: nil)]
        }

        let i: Int
        if let found = sessions.firstIndex(where: { $0.id == e.sessionID }) {
            i = found
        } else {
            sessions.append(Session(id: e.sessionID, cwd: e.cwd ?? "", transcriptPath: e.transcriptPath,
                                    status: .idle, detail: nil, updatedAt: now))
            i = sessions.count - 1
        }
        if let cwd = e.cwd, !cwd.isEmpty { sessions[i].cwd = cwd }
        if let t = e.transcriptPath { sessions[i].transcriptPath = t }
        sessions[i].updatedAt = now

        var effects: [Effect] = []
        switch e.kind {
        case .sessionStart:
            sessions[i].status = .idle
            sessions[i].detail = nil
        case .userPromptSubmit:
            sessions[i].status = .working
            sessions[i].detail = nil
            effects.append(.clearApprovals(session: e.sessionID, tool: nil, summary: nil))
        case .preToolUse:
            if let tool = e.toolName, SessionBoard.questionTools.contains(tool) {
                // Claude is asking the user something; only they can answer, in the session.
                sessions[i].status = .needsYou
                sessions[i].detail = nil
                effects.append(.attention)
            } else {
                sessions[i].status = .runningTool(e.toolName ?? "tool")
                sessions[i].detail = e.toolSummary
            }
        case .postToolUse:
            sessions[i].status = .working
            sessions[i].detail = nil
            effects.append(.clearApprovals(session: e.sessionID, tool: e.toolName, summary: e.toolSummary))
        case .permissionRequest:
            // A question is announced once already, by its PreToolUse event.
            if sessions[i].status != .needsYou { effects.append(.attention) }
            sessions[i].status = .needsApproval
            sessions[i].detail = e.questions.isEmpty ? e.toolSummary : nil
        case .notification:
            if e.notificationType == "permission_prompt" {
                if sessions[i].status != .needsApproval {
                    sessions[i].status = .needsYou
                    effects.append(.attention)
                }
            }
        case .stop:
            sessions[i].status = .finished
            sessions[i].detail = nil
            effects.append(.attention)
            effects.append(.clearApprovals(session: e.sessionID, tool: nil, summary: nil))
        case .subagentStop:
            break
        case .preCompact:
            sessions[i].status = .compacting
        case .sessionEnd:
            break
        }
        return effects
    }

    /// Call after the user answered an approval in Perch: Claude carries on.
    public mutating func approvalResolved(sessionID: String) {
        guard let i = sessions.firstIndex(where: { $0.id == sessionID }) else { return }
        if sessions[i].status == .needsApproval { sessions[i].status = .working }
    }

    /// Call after the user chose "Later" in Perch: Claude's own prompt takes over.
    public mutating func approvalDeferred(sessionID: String) {
        guard let i = sessions.firstIndex(where: { $0.id == sessionID }) else { return }
        if sessions[i].status == .needsApproval { sessions[i].status = .needsYou }
    }

    /// The user removed this session from the list. It comes back if it does anything again.
    public mutating func remove(sessionID: String) {
        sessions.removeAll { $0.id == sessionID }
    }

    /// The user has looked at a finished session: stop highlighting it.
    public mutating func acknowledge(sessionID: String) {
        guard let i = sessions.firstIndex(where: { $0.id == sessionID }) else { return }
        if sessions[i].status == .finished { sessions[i].status = .idle }
    }

    /// Drops sessions that have been silent too long (a closed window never sends SessionEnd).
    public mutating func prune(now: Date = Date(), staleAfter: TimeInterval = 3 * 3600) {
        sessions.removeAll { now.timeIntervalSince($0.updatedAt) > staleAfter }
    }
}
