import Foundation
import PerchCore

// Claude Code runs this on every hook event with the event JSON on stdin.
// It hands the event to Perch.app over a local socket and exits. For a permission request,
// and for the end of a turn that left a question, it waits for the user's click in Perch.
// If Perch is not running it does nothing, so Claude behaves exactly as if it were not installed.

let input = FileHandle.standardInput.readDataToEndOfFile()
guard !input.isEmpty else { exit(0) }

let wait = HookClient.replyWait(for: input)
if let reply = HookClient.send(input: input, socketPath: PerchPaths.socketPath, waitForReply: wait != nil,
                               replyTimeout: wait ?? 0) {
    FileHandle.standardOutput.write(reply)
}
exit(0)
