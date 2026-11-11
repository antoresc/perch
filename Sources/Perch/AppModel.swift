import AppKit
import Combine
import PerchCore

/// A permission request Perch is holding open until the user answers.
struct PendingApproval: Identifiable, Equatable {
    let id = UUID()
    let sessionID: String
    let project: String
    let tool: String
    let summary: String
    let fd: Int32
    /// Non-empty when this is Claude asking a question rather than asking permission.
    var questions: [Question] = []
    var toolInputJSON: Data?

    var isQuestion: Bool { !questions.isEmpty && toolInputJSON != nil }
}

/// A question that is still open in a session but that Perch cannot answer itself: an
/// end-of-turn question, or one whose waiting time ran out. Shown so it can be read again.
struct OpenQuestion: Identifiable {
    let session: Session
    let title: String
    var id: String { session.id }
    var questions: [Question] { session.openQuestions }
}

struct NotchMetrics: Equatable {
    var hasNotch = false
    var notchWidth: CGFloat = 0
    var barHeight: CGFloat = 24
}

enum ApprovalDecision {
    case allow, deny, later
}

/// All app state. Only ever touched on the main thread.
final class AppModel: ObservableObject {
    static let sounds = ["Glass", "Ping", "Pop", "Tink", "Hero", "Submarine", "Funk", "Purr", "Bottle"]

    @Published private(set) var board = SessionBoard()
    @Published private(set) var approvals: [PendingApproval] = []
    @Published private(set) var usage = UsageSummary()
    /// Conversation names, by session id.
    @Published private(set) var titles: [String: String] = [:]
    /// Links that open a session in the Claude app, by session id.
    @Published private(set) var links: [String: URL] = [:]
    /// True for a few seconds after Claude starts waiting for the user, to pop the panel open.
    @Published private(set) var peeking = false
    @Published var hovering = false
    @Published var metrics = NotchMetrics()
    /// Empty string means no sound.
    @Published var soundName: String { didSet { defaults.set(soundName, forKey: "soundName") } }
    @Published var showPanel: Bool { didSet { defaults.set(showPanel, forKey: "showPanel") } }

    /// Opens the Perch menu at the mouse. Set by the app delegate.
    var openMenu: (() -> Void)?

    /// Set when the user clicks elsewhere to close the panel while something is still waiting.
    /// The panel then stays closed until they hover it or something new arrives.
    @Published private(set) var suppressed = false

    var expanded: Bool { hovering || (!suppressed && (peeking || !approvals.isEmpty)) }

    /// Sessions that need the user first, then finished ones, then the rest.
    var sessions: [Session] {
        func rank(_ s: SessionStatus) -> Int {
            if s.needsAttention { return 0 }
            if s == .finished { return 1 }
            return s.isBusy ? 2 : 3
        }
        return board.sessions.enumerated()
            .sorted { (rank($0.element.status), $0.offset) < (rank($1.element.status), $1.offset) }
            .map(\.element)
    }

    private let defaults = UserDefaults.standard
    private var watchers: [UUID: DispatchSourceRead] = [:]
    private let scanner = UsageScanner()
    private let desktopIndex = DesktopSessionIndex()
    private var peekWork: DispatchWorkItem?
    private let usageQueue = DispatchQueue(label: "perch.usage", qos: .utility)
    private var timer: Timer?
    private var sound: NSSound?

    init() {
        soundName = defaults.object(forKey: "soundName") as? String ?? "Glass"
        showPanel = defaults.object(forKey: "showPanel") as? Bool ?? true
    }

    func start() {
        restoreSessions()
        refreshUsage()
        timer = Timer.scheduledTimer(withTimeInterval: 60, repeats: true) { [weak self] _ in
            guard let self else { return }
            var b = self.board
            b.prune()
            if b != self.board { self.board = b }
            self.refreshUsage()
        }
    }

    // MARK: Events from the hook helper

    /// Called on a background thread by the socket server.
    func receive(_ message: Data, fd: Int32) {
        DispatchQueue.main.async { self.handle(message, fd: fd) }
    }

    private func handle(_ message: Data, fd: Int32) {
        guard let event = HookEvent(json: message) else {
            close(fd)
            return
        }
        Log.write("event \(event.kind.rawValue) session=\(event.sessionID) tool=\(event.toolName ?? "-")")
        for effect in board.apply(event) {
            switch effect {
            case .attention:
                playSound()
                peek()
            case let .clearApprovals(session, tool, summary):
                let stale = approvals.filter {
                    $0.sessionID == session && (tool == nil || ($0.tool == tool && $0.summary == (summary ?? "")))
                }
                stale.forEach { discard($0.id) }
            }
        }

        if event.kind == .permissionRequest {
            let session = board.sessions.first { $0.id == event.sessionID }
            let name = session.map { title(for: $0) } ?? "Claude"
            let pending = PendingApproval(sessionID: event.sessionID, project: name,
                                          tool: event.toolName ?? "a tool",
                                          summary: event.toolSummary ?? "", fd: fd,
                                          questions: event.endOfTurnAsk ? [] : event.questions,
                                          toolInputJSON: event.toolInputJSON)
            approvals.append(pending)
            if suppressed { suppressed = false }
            watch(pending)
        } else {
            close(fd)
        }

        if event.kind == .stop || event.kind == .sessionStart || event.kind == .userPromptSubmit { refreshUsage() }
        saveSessions()
        Log.write("state " + board.sessions.map { "\($0.projectName)=\($0.status)" }.joined(separator: ", ")
            + " approvals=\(approvals.count)")
    }

    /// Open questions with no answerable card, most urgent session first.
    var openQuestions: [OpenQuestion] {
        sessions
            .filter { s in
                s.status == .needsYou && !s.openQuestions.isEmpty && !approvals.contains { $0.sessionID == s.id }
            }
            .map { OpenQuestion(session: $0, title: title(for: $0)) }
    }

    // MARK: Remembering sessions across restarts

    private var sessionsFile: URL { PerchPaths.supportDir.appendingPathComponent("sessions.json") }

    /// Saves which sessions are open (id, folder, transcript path only) so a restart of Perch
    /// doesn't empty the list until each session next does something.
    private func saveSessions() {
        let list = board.sessions.map { ["id": $0.id, "cwd": $0.cwd, "transcript": $0.transcriptPath ?? ""] }
        guard let data = try? JSONSerialization.data(withJSONObject: list) else { return }
        try? data.write(to: sessionsFile, options: .atomic)
    }

    private func restoreSessions() {
        guard let data = try? Data(contentsOf: sessionsFile),
              let list = (try? JSONSerialization.jsonObject(with: data)) as? [[String: String]] else { return }
        for item in list {
            guard let id = item["id"], !id.isEmpty else { continue }
            let transcript = item["transcript"].flatMap { $0.isEmpty ? nil : $0 }
            _ = board.apply(HookEvent(kind: .sessionStart, sessionID: id, cwd: item["cwd"], transcriptPath: transcript))
        }
    }

    // MARK: Approvals

    func answer(_ id: UUID, _ decision: ApprovalDecision) {
        guard let pending = approvals.first(where: { $0.id == id }) else { return }
        switch decision {
        case .allow:
            UnixSocket.writeAll(pending.fd, PermissionReply.allow())
            board.approvalResolved(sessionID: pending.sessionID)
        case .deny:
            UnixSocket.writeAll(pending.fd, PermissionReply.deny())
            board.approvalResolved(sessionID: pending.sessionID)
        case .later:
            board.approvalDeferred(sessionID: pending.sessionID)
        }
        Log.write("answer \(decision) tool=\(pending.tool)")
        discard(id)
        // "Answer in Claude" should take you there.
        if decision == .later, let session = board.sessions.first(where: { $0.id == pending.sessionID }) {
            open(session)
        }
    }

    /// Sends the chosen answers back to Claude. `answers` maps each question's text to the label(s) picked.
    func answerQuestion(_ id: UUID, answers: [String: String]) {
        guard let pending = approvals.first(where: { $0.id == id }), let input = pending.toolInputJSON,
              let reply = PermissionReply.answer(toolInputJSON: input, answers: answers) else { return }
        UnixSocket.writeAll(pending.fd, reply)
        board.approvalResolved(sessionID: pending.sessionID)
        Log.write("answered question (\(answers.count) answer(s))")
        discard(id)
    }

    /// Closes the connection without a reply, which tells Claude to carry on as normal.
    private func discard(_ id: UUID) {
        guard let i = approvals.firstIndex(where: { $0.id == id }) else { return }
        let pending = approvals.remove(at: i)
        if let source = watchers.removeValue(forKey: id) {
            source.cancel() // the cancel handler closes the connection
        } else {
            close(pending.fd)
        }
    }

    /// The helper stopped waiting, so Perch can no longer answer this one. Say so on the row
    /// instead of leaving it looking answerable.
    private func expire(_ id: UUID) {
        if let pending = approvals.first(where: { $0.id == id }) {
            board.approvalDeferred(sessionID: pending.sessionID)
        }
        discard(id)
    }

    /// Notices when the helper goes away (answered in Claude itself, or timed out) so the card disappears.
    private func watch(_ pending: PendingApproval) {
        let fd = pending.fd
        let id = pending.id
        let source = DispatchSource.makeReadSource(fileDescriptor: fd, queue: .main)
        source.setEventHandler { [weak self] in
            var byte: UInt8 = 0
            let n = recv(fd, &byte, 1, MSG_PEEK | MSG_DONTWAIT)
            if n == 0 || (n < 0 && errno != EAGAIN && errno != EWOULDBLOCK && errno != EINTR) {
                Log.write("helper went away")
                self?.expire(id)
            } else if n > 0 {
                var junk = [UInt8](repeating: 0, count: 256)
                _ = recv(fd, &junk, junk.count, MSG_DONTWAIT)
            }
        }
        source.setCancelHandler { close(fd) }
        watchers[id] = source
        source.resume()
    }

    // MARK: Popping open and jumping to a session

    /// Opens the panel for a few seconds so the user sees which session wants them.
    func peek(seconds: TimeInterval = 3.5) {
        peekWork?.cancel()
        if suppressed { suppressed = false }
        if !peeking { peeking = true }
        let work = DispatchWorkItem { [weak self] in
            guard let self, self.peeking else { return }
            self.peeking = false
        }
        peekWork = work
        DispatchQueue.main.asyncAfter(deadline: .now() + seconds, execute: work)
    }

    /// Closes the panel now: the user clicked somewhere else. Anything still waiting stays
    /// reachable by hovering the notch, and the pill keeps its orange mark.
    func dismissPanel() {
        guard expanded else { return }
        peekWork?.cancel()
        if peeking { peeking = false }
        if hovering { hovering = false }
        if !approvals.isEmpty, !suppressed { suppressed = true }
    }

    func title(for session: Session) -> String {
        titles[session.id] ?? session.projectName
    }

    func canOpen(_ session: Session) -> Bool { links[session.id] != nil }

    /// Brings the Claude app forward on this conversation.
    func open(_ session: Session) {
        guard let url = links[session.id] else { return }
        Log.write("open \(session.id)")
        NSWorkspace.shared.open(url)
        board.acknowledge(sessionID: session.id)
        peekWork?.cancel()
        if peeking { peeking = false }
        if hovering { hovering = false }
    }

    /// Takes a session off the list. Any approval it had waiting goes back to Claude's own prompt.
    func remove(_ session: Session) {
        approvals.filter { $0.sessionID == session.id }.forEach { discard($0.id) }
        board.remove(sessionID: session.id)
        saveSessions()
        Log.write("removed \(session.id)")
    }

    // MARK: Sound

    func playSound() {
        guard !soundName.isEmpty else { return }
        sound?.stop()
        sound = NSSound(named: NSSound.Name(soundName))
        sound?.play()
    }

    // MARK: Usage

    func refreshUsage() {
        let scanner = self.scanner
        let index = self.desktopIndex
        let current = board.sessions.map { (id: $0.id, transcript: $0.transcriptPath) }
        usageQueue.async { [weak self] in
            index.refresh(root: PerchPaths.desktopSessionsDir)
            var titles: [String: String] = [:]
            var links: [String: URL] = [:]
            for s in current {
                let desktop = index.session(for: s.id)
                if let url = desktop?.openURL { links[s.id] = url }
                if let t = desktop?.title ?? s.transcript.flatMap({ TranscriptTitle.read(path: $0) }) {
                    titles[s.id] = t
                }
            }
            let now = Date()
            let since = min(Calendar.current.startOfDay(for: now), now.addingTimeInterval(-5 * 3600))
            scanner.refresh(root: PerchPaths.projectsDir, modifiedSince: since)
            let summary = scanner.summary(now: now)
            DispatchQueue.main.async {
                guard let self else { return }
                if self.usage != summary { self.usage = summary }
                if self.titles != titles { self.titles = titles }
                if self.links != links { self.links = links }
            }
        }
    }

    func tokens(for session: Session) -> Int? {
        usage.perSession[session.id]?.fresh
    }
}

/// Writes a line per event to the file named by PERCH_LOG. Off unless that variable is set.
enum Log {
    private static let path = ProcessInfo.processInfo.environment["PERCH_LOG"]

    static func write(_ line: String) {
        guard let path, let data = (line + "\n").data(using: .utf8) else { return }
        if let handle = FileHandle(forWritingAtPath: path) {
            handle.seekToEndOfFile()
            handle.write(data)
            try? handle.close()
        } else {
            FileManager.default.createFile(atPath: path, contents: data)
        }
    }
}
