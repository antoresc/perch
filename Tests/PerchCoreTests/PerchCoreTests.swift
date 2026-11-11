import XCTest
@testable import PerchCore

final class HookEventTests: XCTestCase {
    func testParsesToolEvent() throws {
        let json = #"{"hook_event_name":"PreToolUse","session_id":"s1","cwd":"/Users/x/Dev/portal","tool_name":"Bash","tool_input":{"command":"npm test","description":"Run tests"}}"#
        let e = try XCTUnwrap(HookEvent(json: Data(json.utf8)))
        XCTAssertEqual(e.kind, .preToolUse)
        XCTAssertEqual(e.sessionID, "s1")
        XCTAssertEqual(e.toolName, "Bash")
        XCTAssertEqual(e.toolSummary, "npm test")
    }

    func testRejectsUnknownOrBroken() {
        XCTAssertNil(HookEvent(json: Data(#"{"hook_event_name":"Mystery","session_id":"s"}"#.utf8)))
        XCTAssertNil(HookEvent(json: Data(#"{"hook_event_name":"Stop"}"#.utf8)))
        XCTAssertNil(HookEvent(json: Data("not json".utf8)))
    }

    func testSummaryFallsBackToJSONAndClips() {
        XCTAssertEqual(HookEvent.summarize(input: ["b": 2, "a": 1]), #"{"a":1,"b":2}"#)
        let long = String(repeating: "x", count: 2000)
        let clipped = HookEvent.summarize(input: ["command": long])
        XCTAssertEqual(clipped.count, 1501)
        XCTAssertTrue(clipped.hasSuffix("…"))
    }

    func testPermissionReplies() throws {
        let allow = try XCTUnwrap(JSONSerialization.jsonObject(with: PermissionReply.allow()) as? [String: Any])
        let out = try XCTUnwrap(allow["hookSpecificOutput"] as? [String: Any])
        XCTAssertEqual(out["hookEventName"] as? String, "PermissionRequest")
        XCTAssertEqual((out["decision"] as? [String: Any])?["behavior"] as? String, "allow")
        let deny = try XCTUnwrap(JSONSerialization.jsonObject(with: PermissionReply.deny()) as? [String: Any])
        let d = (deny["hookSpecificOutput"] as? [String: Any])?["decision"] as? [String: Any]
        XCTAssertEqual(d?["behavior"] as? String, "deny")
        XCTAssertEqual(d?["message"] as? String, "Denied from Perch")
    }
}

final class SessionBoardTests: XCTestCase {
    private func ev(_ k: HookEvent.Kind, _ s: String = "s1", tool: String? = nil, summary: String? = nil,
                    note: String? = nil) -> HookEvent {
        HookEvent(kind: k, sessionID: s, cwd: "/Users/x/Dev/portal", toolName: tool, toolSummary: summary,
                  notificationType: note)
    }

    func testLifecycle() {
        var b = SessionBoard()
        XCTAssertEqual(b.apply(ev(.sessionStart)), [])
        XCTAssertEqual(b.sessions.first?.projectName, "portal")
        XCTAssertEqual(b.sessions.first?.status, .idle)

        _ = b.apply(ev(.userPromptSubmit))
        XCTAssertEqual(b.sessions[0].status, .working)

        _ = b.apply(ev(.preToolUse, tool: "Bash", summary: "ls"))
        XCTAssertEqual(b.sessions[0].status, .runningTool("Bash"))
        XCTAssertEqual(b.sessions[0].detail, "ls")

        XCTAssertEqual(b.apply(ev(.permissionRequest, tool: "Bash", summary: "ls")), [.attention])
        XCTAssertEqual(b.sessions[0].status, .needsApproval)

        b.approvalResolved(sessionID: "s1")
        XCTAssertEqual(b.sessions[0].status, .working)

        let post = b.apply(ev(.postToolUse, tool: "Bash", summary: "ls"))
        XCTAssertEqual(post, [.clearApprovals(session: "s1", tool: "Bash", summary: "ls")])

        let stop = b.apply(ev(.stop))
        XCTAssertTrue(stop.contains(.attention))
        XCTAssertEqual(b.sessions[0].status, .finished)

        XCTAssertEqual(b.apply(ev(.sessionEnd)), [.clearApprovals(session: "s1", tool: nil, summary: nil)])
        XCTAssertTrue(b.sessions.isEmpty)
    }

    func testEventForUnknownSessionCreatesIt() {
        var b = SessionBoard()
        _ = b.apply(ev(.preToolUse, "new", tool: "Read", summary: "/a"))
        XCTAssertEqual(b.sessions.map(\.id), ["new"])
    }

    func testPermissionPromptNotificationOnlyWhenNotAlreadyHeld() {
        var b = SessionBoard()
        XCTAssertEqual(b.apply(ev(.notification, note: "permission_prompt")), [.attention])
        XCTAssertEqual(b.sessions[0].status, .needsYou)

        _ = b.apply(ev(.permissionRequest, "s2", tool: "Bash", summary: "x"))
        XCTAssertEqual(b.apply(ev(.notification, "s2", note: "permission_prompt")), [])
        XCTAssertEqual(b.sessions[1].status, .needsApproval)
    }

    func testQuestionToolMeansWaitingForUser() {
        var b = SessionBoard()
        XCTAssertEqual(b.apply(ev(.preToolUse, tool: "AskUserQuestion")), [.attention])
        XCTAssertEqual(b.sessions[0].status, .needsYou)
        _ = b.apply(ev(.postToolUse, tool: "AskUserQuestion"))
        XCTAssertEqual(b.sessions[0].status, .working)
    }

    func testRemoveAndAcknowledge() {
        var b = SessionBoard()
        _ = b.apply(ev(.stop, "a"))
        _ = b.apply(ev(.userPromptSubmit, "b"))
        b.acknowledge(sessionID: "a")
        b.acknowledge(sessionID: "b")
        XCTAssertEqual(b.sessions.map(\.status), [.idle, .working])
        b.remove(sessionID: "a")
        XCTAssertEqual(b.sessions.map(\.id), ["b"])
        // A removed session that does something again comes back.
        _ = b.apply(ev(.userPromptSubmit, "a"))
        XCTAssertEqual(b.sessions.map(\.id), ["b", "a"])
    }

    func testSubagentStopDoesNotMarkIdle() {
        var b = SessionBoard()
        _ = b.apply(ev(.userPromptSubmit))
        XCTAssertEqual(b.apply(ev(.subagentStop)), [])
        XCTAssertEqual(b.sessions[0].status, .working)
    }

    func testPruneDropsSilentSessions() {
        var b = SessionBoard()
        let start = Date(timeIntervalSince1970: 1_000_000)
        _ = b.apply(ev(.sessionStart, "old"), now: start)
        _ = b.apply(ev(.sessionStart, "fresh"), now: start.addingTimeInterval(4 * 3600 - 60))
        b.prune(now: start.addingTimeInterval(4 * 3600))
        XCTAssertEqual(b.sessions.map(\.id), ["fresh"])
    }
}

final class HookSettingsTests: XCTestCase {
    private let existing: [String: Any] = [
        "enabledPlugins": ["a": true],
        "hooks": [
            "PostToolUse": [["hooks": [["type": "command", "command": "node impeccable.js"]]]],
            "SessionStart": [["hooks": [["type": "command", "command": "run-hook.cmd session-start"]]]],
        ],
    ]

    private func commands(_ root: [String: Any], _ event: String) -> [String] {
        let groups = (root["hooks"] as? [String: Any])?[event] as? [[String: Any]] ?? []
        return groups.flatMap { ($0["hooks"] as? [[String: Any]] ?? []).compactMap { $0["command"] as? String } }
    }

    func testInstallKeepsExistingHooks() {
        let out = HookSettings.install(into: existing, command: "/h/perch-hook")
        XCTAssertEqual(commands(out, "PostToolUse"), ["node impeccable.js", "/h/perch-hook"])
        XCTAssertEqual(commands(out, "SessionStart"), ["run-hook.cmd session-start", "/h/perch-hook"])
        XCTAssertEqual(commands(out, "Stop"), ["/h/perch-hook"])
        XCTAssertNotNil(out["enabledPlugins"])
        XCTAssertTrue(HookSettings.isInstalled(in: out))
        XCTAssertFalse(HookSettings.isInstalled(in: existing))
    }

    func testInstallTwiceDoesNotDuplicate() {
        let once = HookSettings.install(into: existing, command: "/h/perch-hook")
        let twice = HookSettings.install(into: once, command: "/h/perch-hook")
        XCTAssertEqual(commands(twice, "PostToolUse"), ["node impeccable.js", "/h/perch-hook"])
        XCTAssertEqual(commands(twice, "Stop"), ["/h/perch-hook"])
    }

    func testRemoveRestoresOriginal() {
        let installed = HookSettings.install(into: existing, command: "/h/perch-hook")
        let removed = HookSettings.remove(from: installed)
        XCTAssertEqual(removed as NSDictionary, existing as NSDictionary)
    }

    func testRemoveFromEmptyAndInstallIntoEmpty() {
        XCTAssertTrue(HookSettings.remove(from: [:]).isEmpty)
        let out = HookSettings.install(into: [:], command: "/h/perch-hook")
        XCTAssertTrue(HookSettings.isInstalled(in: out))
        XCTAssertTrue(HookSettings.remove(from: out).isEmpty)
    }

    func testPermissionHookGetsLongTimeoutAndMatcher() {
        let out = HookSettings.install(into: [:], command: "/h/perch-hook")
        let group = ((out["hooks"] as? [String: Any])?["PermissionRequest"] as? [[String: Any]])?.first
        XCTAssertEqual(group?["matcher"] as? String, "*")
        XCTAssertEqual((group?["hooks"] as? [[String: Any]])?.first?["timeout"] as? Int, 310)
    }

    func testBrokenSettingsFileIsNotOverwritten() throws {
        let dir = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: dir) }
        let file = dir.appendingPathComponent("settings.json")
        try Data("{ not json".utf8).write(to: file)
        XCTAssertThrowsError(try HookSettings.read(file))
        XCTAssertTrue(try HookSettings.read(dir.appendingPathComponent("missing.json")).isEmpty)
    }

    func testWriteThenReadRoundTrips() throws {
        let dir = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: dir) }
        let file = dir.appendingPathComponent("settings.json")
        let installed = HookSettings.install(into: existing, command: "/h/perch-hook")
        try HookSettings.write(installed, to: file)
        XCTAssertEqual(try HookSettings.read(file) as NSDictionary, installed as NSDictionary)
    }
}

final class UsageTests: XCTestCase {
    private func line(_ ts: String, id: String, session: String = "s1", input: Int, output: Int,
                      create: Int = 0, read: Int = 0) -> String {
        #"{"type":"assistant","timestamp":"\#(ts)","sessionId":"\#(session)","requestId":"r-\#(id)","message":{"id":"\#(id)","usage":{"input_tokens":\#(input),"output_tokens":\#(output),"cache_creation_input_tokens":\#(create),"cache_read_input_tokens":\#(read)}}}"#
    }

    private var utc: Calendar {
        var c = Calendar(identifier: .gregorian)
        c.timeZone = TimeZone(identifier: "UTC")!
        return c
    }

    func testParseLine() throws {
        let e = try XCTUnwrap(UsageParser.parse(line: Data(line("2026-11-11T10:00:00.500Z", id: "m1", input: 10, output: 20, create: 5, read: 100).utf8)))
        XCTAssertEqual(e.tokens, TokenCount(input: 10, output: 20, cacheCreation: 5, cacheRead: 100))
        XCTAssertEqual(e.tokens.fresh, 35)
        XCTAssertEqual(e.sessionID, "s1")
        XCTAssertNil(UsageParser.parse(line: Data(#"{"type":"user","timestamp":"2026-11-11T10:00:00Z"}"#.utf8)))
    }

    func testScannerWindowsDedupeAndAppend() throws {
        let dir = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        let project = dir.appendingPathComponent("proj")
        try FileManager.default.createDirectory(at: project, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: dir) }
        let file = project.appendingPathComponent("s1.jsonl")

        let now = ISO8601DateFormatter().date(from: "2026-11-11T12:00:00Z")!
        var text = [
            line("2026-11-10T20:00:00Z", id: "yesterday", input: 1000, output: 0),
            line("2026-11-11T01:00:00Z", id: "morning", input: 100, output: 0),
            line("2026-11-11T11:00:00Z", id: "recent", input: 10, output: 1),
            // Same reply written again with its final output count: must replace, not add.
            line("2026-11-11T11:00:00Z", id: "recent", input: 10, output: 5),
            #"{"type":"user","timestamp":"2026-11-11T11:00:01Z"}"#,
        ].joined(separator: "\n") + "\n"
        // A half-written trailing line must be ignored until it is complete.
        let partial = line("2026-11-11T11:30:00Z", id: "late", session: "s2", input: 7, output: 0)
        try Data((text + partial.prefix(40)).utf8).write(to: file)

        let scanner = UsageScanner()
        scanner.refresh(root: dir, modifiedSince: .distantPast)
        var s = scanner.summary(now: now, calendar: utc)
        XCTAssertEqual(s.last5h.fresh, 15)
        XCTAssertEqual(s.today.fresh, 115)
        XCTAssertEqual(s.perSession["s1"]?.fresh, 1115)
        XCTAssertNil(s.perSession["s2"])

        text += partial + "\n"
        try Data(text.utf8).write(to: file)
        scanner.refresh(root: dir, modifiedSince: .distantFuture)
        s = scanner.summary(now: now, calendar: utc)
        XCTAssertEqual(s.last5h.fresh, 22)
        XCTAssertEqual(s.perSession["s2"]?.fresh, 7)
        XCTAssertEqual(s.perSession["s1"]?.fresh, 1115)
    }

    func testOldFilesAreSkipped() throws {
        let dir = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: dir) }
        try Data((line("2026-11-11T11:00:00Z", id: "a", input: 5, output: 0) + "\n").utf8)
            .write(to: dir.appendingPathComponent("a.jsonl"))
        let scanner = UsageScanner()
        scanner.refresh(root: dir, modifiedSince: .distantFuture)
        XCTAssertEqual(scanner.summary().perSession.count, 0)
    }

    func testTokenFormat() {
        XCTAssertEqual(TokenFormat.short(950), "950")
        XCTAssertEqual(TokenFormat.short(18_200), "18k")
        XCTAssertEqual(TokenFormat.short(1_234_000), "1.2M")
    }
}

final class SocketTests: XCTestCase {
    private func tempSocket() -> String {
        "/tmp/perch-test-\(UUID().uuidString.prefix(8)).sock"
    }

    func testEventReachesServerWithoutReply() throws {
        let path = tempSocket()
        let got = expectation(description: "event")
        var received: Data?
        let server = SocketServer(path: path) { message, fd in
            received = message
            close(fd)
            got.fulfill()
        }
        try server.start()
        defer { server.stop() }

        let input = Data("{\n  \"hook_event_name\": \"Stop\",\n  \"session_id\": \"s1\"\n}".utf8)
        XCTAssertNil(HookClient.send(input: input, socketPath: path, waitForReply: false))
        wait(for: [got], timeout: 3)
        XCTAssertEqual(HookEvent(json: try XCTUnwrap(received))?.kind, .stop)
    }

    func testPermissionRoundTrip() throws {
        let path = tempSocket()
        let server = SocketServer(path: path) { _, fd in
            DispatchQueue.global().asyncAfter(deadline: .now() + 0.1) {
                UnixSocket.writeAll(fd, PermissionReply.allow())
                close(fd)
            }
        }
        try server.start()
        defer { server.stop() }

        let input = Data(#"{"hook_event_name":"PermissionRequest","session_id":"s1","tool_name":"Bash","tool_input":{"command":"ls"}}"#.utf8)
        XCTAssertTrue(HookClient.isPermissionRequest(input))
        let reply = HookClient.send(input: input, socketPath: path, waitForReply: true, replyTimeout: 5)
        XCTAssertEqual(reply, PermissionReply.allow())
    }

    func testClosingWithoutReplyMeansSayNothing() throws {
        let path = tempSocket()
        let server = SocketServer(path: path) { _, fd in close(fd) }
        try server.start()
        defer { server.stop() }
        let input = Data(#"{"hook_event_name":"PermissionRequest","session_id":"s1"}"#.utf8)
        XCTAssertNil(HookClient.send(input: input, socketPath: path, waitForReply: true, replyTimeout: 5))
    }

    func testNoServerReturnsImmediately() {
        let start = Date()
        XCTAssertNil(HookClient.send(input: Data("{}".utf8), socketPath: tempSocket(), waitForReply: true))
        XCTAssertLessThan(Date().timeIntervalSince(start), 1)
    }
}

final class TitleTests: XCTestCase {
    private func tempDir() throws -> URL {
        let dir = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        return dir
    }

    func testTranscriptTitlePrefersLatestCustomTitle() throws {
        let dir = try tempDir()
        defer { try? FileManager.default.removeItem(at: dir) }
        let file = dir.appendingPathComponent("t.jsonl")
        let lines = [
            #"{"type":"custom-title","customTitle":"Old name","sessionId":"s"}"#,
            #"{"type":"last-prompt","lastPrompt":"fix the login page","sessionId":"s"}"#,
            #"{"type":"custom-title","customTitle":"Login page fix","sessionId":"s"}"#,
            #"{"type":"user","message":{"content":"hello"}}"#,
        ]
        try Data((lines.joined(separator: "\n") + "\n").utf8).write(to: file)
        XCTAssertEqual(TranscriptTitle.read(path: file.path), "Login page fix")
    }

    func testTranscriptTitleFallsBackToLastPromptThenNil() throws {
        let dir = try tempDir()
        defer { try? FileManager.default.removeItem(at: dir) }
        let file = dir.appendingPathComponent("t.jsonl")
        let long = String(repeating: "word ", count: 30)
        try Data((#"{"type":"last-prompt","lastPrompt":"\#(long)"}"# + "\n").utf8).write(to: file)
        let title = try XCTUnwrap(TranscriptTitle.read(path: file.path))
        XCTAssertEqual(title.count, 61)
        XCTAssertTrue(title.hasSuffix("…"))

        try Data(#"{"type":"user"}"#.utf8).write(to: file)
        XCTAssertNil(TranscriptTitle.read(path: file.path))
        XCTAssertNil(TranscriptTitle.read(path: dir.appendingPathComponent("missing").path))
    }

    func testDesktopSessionIndex() throws {
        let dir = try tempDir()
        defer { try? FileManager.default.removeItem(at: dir) }
        let nested = dir.appendingPathComponent("a/b")
        try FileManager.default.createDirectory(at: nested, withIntermediateDirectories: true)
        try Data(#"{"sessionId":"local_abc-123","cliSessionId":"cli-1","title":"Portal redesign"}"#.utf8)
            .write(to: nested.appendingPathComponent("local_abc-123.json"))
        try Data(#"{"sessionId":"local_def","cliSessionId":"cli-2","title":""}"#.utf8)
            .write(to: nested.appendingPathComponent("local_def.json"))
        try Data(#"{"sessionId":"x","cliSessionId":"cli-3"}"#.utf8)
            .write(to: nested.appendingPathComponent("other.json"))

        let index = DesktopSessionIndex()
        index.refresh(root: dir)
        XCTAssertEqual(index.session(for: "cli-1"), DesktopSession(localID: "local_abc-123", title: "Portal redesign"))
        XCTAssertEqual(index.session(for: "cli-1")?.openURL?.absoluteString,
                       "claude://code/continue?session=local_abc-123")
        XCTAssertNil(index.session(for: "cli-2")?.title)
        XCTAssertNil(index.session(for: "cli-3"))
    }

    func testOpenURLRejectsOddIDs() {
        XCTAssertNil(DesktopSession(localID: "local_a&b=c", title: nil).openURL)
        XCTAssertNil(DesktopSession(localID: "remote_abc", title: nil).openURL)
    }
}

final class QuestionTests: XCTestCase {
    private let json = #"{"hook_event_name":"PermissionRequest","session_id":"s1","tool_name":"AskUserQuestion","tool_input":{"questions":[{"question":"Which colour?","header":"Colour","multiSelect":false,"options":[{"label":"Red","description":"Warm"},{"label":"Blue","description":"Cool"}]},{"question":"Which sizes?","header":"Size","multiSelect":true,"options":[{"label":"S","description":""},{"label":"M","description":""}]}]}}"#

    func testParsesQuestions() throws {
        let e = try XCTUnwrap(HookEvent(json: Data(json.utf8)))
        XCTAssertEqual(e.questions.count, 2)
        XCTAssertEqual(e.questions[0].text, "Which colour?")
        XCTAssertEqual(e.questions[0].options.map(\.label), ["Red", "Blue"])
        XCTAssertEqual(e.questions[0].options[0].detail, "Warm")
        XCTAssertFalse(e.questions[0].multiSelect)
        XCTAssertTrue(e.questions[1].multiSelect)
    }

    func testOtherToolsHaveNoQuestions() throws {
        let e = try XCTUnwrap(HookEvent(json: Data(#"{"hook_event_name":"PermissionRequest","session_id":"s1","tool_name":"Bash","tool_input":{"command":"ls","questions":[{"question":"x"}]}}"#.utf8)))
        XCTAssertTrue(e.questions.isEmpty)
        XCTAssertNotNil(e.toolInputJSON)
    }

    func testAnswerReplyKeepsQuestionsAndAddsAnswers() throws {
        let e = try XCTUnwrap(HookEvent(json: Data(json.utf8)))
        let reply = try XCTUnwrap(PermissionReply.answer(toolInputJSON: try XCTUnwrap(e.toolInputJSON),
                                                         answers: ["Which colour?": "Blue", "Which sizes?": "S, M"]))
        let obj = try XCTUnwrap(JSONSerialization.jsonObject(with: reply) as? [String: Any])
        let decision = try XCTUnwrap((obj["hookSpecificOutput"] as? [String: Any])?["decision"] as? [String: Any])
        XCTAssertEqual(decision["behavior"] as? String, "allow")
        let updated = try XCTUnwrap(decision["updatedInput"] as? [String: Any])
        XCTAssertEqual((updated["questions"] as? [Any])?.count, 2)
        XCTAssertEqual(updated["answers"] as? [String: String], ["Which colour?": "Blue", "Which sizes?": "S, M"])
    }

    func testQuestionAnnouncedOnlyOnce() {
        var b = SessionBoard()
        let pre = HookEvent(kind: .preToolUse, sessionID: "s", toolName: "AskUserQuestion")
        let req = HookEvent(kind: .permissionRequest, sessionID: "s", toolName: "AskUserQuestion")
        XCTAssertEqual(b.apply(pre), [.attention])
        XCTAssertEqual(b.apply(req), [])
        XCTAssertEqual(b.sessions[0].status, .needsApproval)
    }
}
