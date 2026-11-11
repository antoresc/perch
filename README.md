# Perch

A small Mac app that shows your Claude Code sessions at the notch, so you can see which one is working, which one is waiting for you, and answer it without switching windows.

Perch is an independent project. It is not made by, endorsed by, or affiliated with Anthropic.

## What it does

- **Session status.** A pill at the notch with one dot per session: blue is working, orange needs you, green has finished and is waiting for you, grey is idle. Hover to see each conversation's name, state and current tool.
- **Pops open when Claude is waiting.** When a turn finishes or Claude asks something, the panel opens for a few seconds with that conversation at the top. Clicking anywhere else closes it at once.
- **Answer questions.** When Claude asks a multiple-choice question, the panel shows it with its choices; clicking one answers it. "Answer in Claude" hands it back to Claude's own dialog.
- **Open questions stay visible.** A question Perch cannot answer itself, such as the one a session leaves at the end of its turn, or one left longer than twelve hours, is still shown in the panel with its choices until it is answered. Clicking it opens that conversation.
- **Approve or deny.** When Claude asks permission, the panel shows the tool and the full command or file (scrollable), with Allow, Deny and Decide in Claude. The last one hands the request back to Claude's own prompt and takes you to that conversation.
- **Click to open.** Clicking a row brings the Claude desktop app forward on that conversation.
- **Remove a row.** The × on a row takes that conversation off the list. It comes back only if that conversation does something again.
- **Sound.** Plays a system sound when a turn finishes or Claude needs you. Choose or mute it from the menu.
- **Usage.** Tokens per session, for the last 5 hours and for today, added up from the session files already on your Mac. "Tokens" excludes cached re-reads; the menu shows those separately.
- **Tuck away menu bar icons.** A thin ‹ divider in the menu bar. Hold ⌘ and drag icons to its left, then choose "Hide Icons Left of the ‹ Divider" (or Option-click the bird).

The menu is behind the bird icon in the menu bar, and also behind the ⋯ button inside the panel, for when the menu bar is too full to show the bird.

## Privacy and security

Perch is built so that you can check these claims yourself. The whole app is about 2,000 lines of Swift with no dependencies.

- **No network code.** No telemetry, no crash reporting, no auto-update, no sign-in. Search the source for `URLSession` or `import Network`: there is none.
- **No credentials.** It never reads your Claude login, the Keychain, or any token.
- **Nothing is approved for you.** Perch only answers a permission request or a question when you click a button. If Perch is not running, or you ignore it, Claude behaves exactly as if Perch were not installed.
- **Local only.** The hook helper talks to the app over a Unix socket in your own Library folder, readable only by your user account.
- **Your settings are preserved.** Installing adds Perch's hook entries next to any you already have, after saving a copy of the file. Removing takes out only Perch's entries. A settings file that is not valid JSON is left untouched.

What Perch does not protect against: any other program already running as your user can send Perch fake events, which could show a misleading row or card. It cannot use that to approve anything in Claude, because an answer only ever goes back to the program that asked.

### Files it touches

| Path | Why |
| --- | --- |
| `~/.claude/settings.json` | Adds its hook entries next to existing ones. Only when you choose Install. Keys are written in alphabetical order. |
| `~/.claude/settings.json.before-perch` | Copy of your settings from before the first install. |
| `~/.claude/hooks/perch-hook` | The helper Claude Code runs on each event. |
| `~/.claude/projects/` | Read-only, for token counts and conversation names. |
| `~/Library/Application Support/Claude/claude-code-sessions/` | Read-only, for conversation names and the ids used to open them. |
| `~/Library/Application Support/Perch/perch.sock` | Local socket between the helper and the app. |
| `~/Library/Application Support/Perch/sessions.json` | Which sessions are open (id, folder, transcript path), so a restart keeps the list. |

## Install

There is no downloadable app, on purpose. A prebuilt app would have to be signed with a paid Apple developer certificate for macOS to open it without warnings, and asking you to bypass those warnings would defeat the point. You build it from this source, which takes about a minute.

Requirements: a Mac with macOS 14 or later, and Xcode 15 or later.

```bash
git clone https://github.com/antoresc/perch.git
```

```bash
cd perch && ./build.sh
```

`build.sh` compiles the app, signs it locally and installs it to `/Applications/Perch.app`. Build products go to `~/Library/Caches/PerchBuild`.

Then:

1. Open Perch from Applications.
2. Choose **Install Claude Hooks** from the bird menu, or from the ⋯ button in the notch panel. From a terminal, the same thing is `/Applications/Perch.app/Contents/MacOS/Perch --install-hooks`.
3. Start a new Claude Code session. Sessions that were already open may need a restart.

## Limits

- **Opening a conversation and showing its name** rely on how the Claude desktop app currently stores its sessions and on its `claude://` link. These are not documented and may change. Sessions started in a terminal get a name but cannot be opened by clicking.
- **Approvals are rare in auto mode.** If your sessions approve most things by themselves, you will mostly see questions and "finished" pop-ups.
- **Waiting time.** A question or permission request stays answerable in Perch for up to twelve hours. In a terminal session, Claude Code may hold its own prompt back while Perch is waiting; use "Answer in Claude" or "Decide in Claude" to release it. If you installed the hooks with an earlier version, choose **Update Claude Hooks** from the menu to get the longer waiting time.
- **Typed answers.** A question's "Other" free-text answer has to be given in Claude.
- **Staying put between desktops.** To stop the pill sliding sideways when you swipe between desktops, Perch places its window in its own layer using window-server calls that Apple does not document. They are looked up when the app starts; if a future macOS removes them, the pill goes back to sliding with the desktop and nothing else changes.
- **Menu bar space.** If the bird icon does not appear, your menu bar is full and macOS has hidden it. Use the ⋯ button in the panel.
- No "always allow", and no percentage of your plan limit (that would need your login).

## How it works

Claude Code runs `perch-hook` on each event: prompt sent, tool started, permission needed, turn finished. The helper passes the event to the app over the local socket and exits. For a permission request or a question it waits up to twelve hours for your click, so a question you leave for later is still answerable from the notch; whichever of Perch and Claude's own prompt is answered first wins.

- `Sources/PerchCore` holds event parsing, session state, the settings merge, usage sums and the socket code. It is covered by tests.
- `Sources/perch-hook` is the helper.
- `Sources/Perch` is the notch panel and menu bar app.

## Tests

```bash
swift test --scratch-path ~/Library/Caches/PerchBuild
```

## Uninstall

Choose **Remove Claude Hooks** from the menu (or run the app binary with `--remove-hooks`), quit Perch, and delete `/Applications/Perch.app`. You can then delete `~/.claude/hooks/perch-hook` and `~/Library/Application Support/Perch`.

## Debugging

Start the app with `PERCH_LOG=/path/to/file` to log each event (type, session id and tool name only), and `PERCH_SNAPSHOT=/path/to/file.png` to save a picture of the panel after each change.

## Licence

MIT. See [LICENSE](LICENSE).
