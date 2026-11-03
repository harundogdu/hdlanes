# hdlanes architecture

hdlanes is a native macOS app (SwiftUI + AppKit, SwiftPM, macOS 14+) for running many coding agents —
Claude Code and OpenAI Codex CLI — side by side, each in its own terminal, git worktree and **account**.
Everything runs locally.

## Principles

1. **The agents are the user's own installed CLIs in a real PTY** (SwiftTerm). hdlanes never drives
   them headless, never bundles them, never reads their tokens. It observes (hooks, status line,
   rollout files, OSC 7501, terminal title) and types into the terminal like a user.
2. **Accounts are a property of a session, not a global switch.** Many Claude and Codex accounts run at
   the same time. Isolation is per config dir:
   - Claude: `CLAUDE_CONFIG_DIR=<dir>`. Claude Code keys its macOS Keychain entry by
     `"Claude Code-credentials-" + sha256(<exact dir string>)[0..8]`, so the dir string must never change
     (no trailing slash, absolute, NFC). Setting `CLAUDE_CONFIG_DIR` even to `~/.claude` changes the key →
     the system default account is launched **without** `CLAUDE_CONFIG_DIR`.
   - Codex: `CODEX_HOME=<dir>` (must exist). `auth.json`, sessions, sqlite are under it. System default
     account is launched without `CODEX_HOME`.
   - Verified on this machine with claude 2.1.317 / codex 0.166.0: an empty dir → logged out; default → logged in.
3. **Never lose user data.** state.json is written atomically. A file that doesn't decode is copied aside
   before hdlanes starts fresh; a file that can't be read (or backed up) is left untouched and saving is
   blocked until the user fixes it. Removing a worktree/account dir asks first and says what will be lost;
   commits only reachable from a detached HEAD go to a rescue branch first.
4. **No hardcoded UI text in views.** All strings go through `L` (`App/L10n.swift` + per-area
   `L10n+<Area>.swift`), English + Turkish side by side: `static var x: String { pick("en", "tr") }`.
5. **Small files, protocol-first where a seam is useful.** Pure logic lives in `HDCore` with tests.

## Targets

| Target | Kind | Notes |
|---|---|---|
| `HDCore` | library | Models, StateStore, HDPaths, HookProtocol/JSONValue, runtime value types, env builder, reducers, parsers. Swift 6 mode. No AppKit/SwiftUI. |
| `HDHook` (`hdlanes-hook`) | executable | Called by Claude Code hooks and the status line. Forwards JSON to the app socket. |
| `HDLanes` (`hdlanes`) | executable app | SwiftUI + AppKit + SwiftTerm. **Swift 5 language mode.** |
| `HDCoreTests` | Swift Testing | `swift test` |

**Gotcha:** `SwiftTerm.Color` collides with `SwiftUI.Color`. A file that imports SwiftUI must not import
SwiftTerm (keep terminal code in AppKit-only files), or qualify `SwiftUI.Color`.

## On-disk layout (`~/.hdlanes`, override with `$HDLANES_HOME`)

```
state.json                         AppState (accounts, projects, sessions, tasks, usage, settings)
state.backup-<ts>.json             state.json that failed to decode, preserved
accounts/claude/<uuid>/            CLAUDE_CONFIG_DIR of a managed Claude account (0700)
accounts/codex/<uuid>/             CODEX_HOME of a managed Codex account (0700)
plugin/claude/                     generated plugin: .claude-plugin/plugin.json + hooks/hooks.json
run/hd.sock                        hook socket (run/ is 0700)
run/sessions/<uuid>/settings.json  per-session --settings (statusLine → hdlanes-hook statusline)
run/cli/                           empty cwd of account CLI calls and the login terminal
```

Worktrees default to `<repo parent>/<repo name>-worktrees/<slug>` (per-project override `worktreeRoot`).

## Launching an agent (runtime area)

A session terminal runs the user's login shell so PATH, nvm, aliases work, then the agent, then stays a
shell after the agent exits:

```
/bin/zsh -l -i -c '<agent command>; exec /bin/zsh -l -i'        # $SHELL if set
```

The agent command is prefixed with `env -u …` so credential variables exported by the user's shell
init can't override the account's login, then the account's dir variable (managed accounts only):

```
env -u ANTHROPIC_API_KEY -u ANTHROPIC_AUTH_TOKEN -u CLAUDE_CODE_OAUTH_TOKEN -u CLAUDECODE \
    -u CLAUDE_CODE_ENTRYPOINT -u CLAUDE_CODE_DISABLE_TERMINAL_TITLE -u CLAUDE_CONFIG_DIR -u CODEX_HOME \
    [-u CLAUDE_CODE_USE_BEDROCK -u CLAUDE_CODE_USE_VERTEX -u CLAUDE_CODE_USE_FOUNDRY -u ANTHROPIC_BASE_URL \
     CLAUDE_CONFIG_DIR='<dir>'] \
  claude --plugin-dir '<~/.hdlanes/plugin/claude>' --settings '<run/sessions/<id>/settings.json>' \
         --session-id <uuid> -n '<title>' ['<initial prompt>']
resume:  claude … --resume <uuid>
codex:   env -u OPENAI_API_KEY -u CODEX_API_KEY -u CODEX_ACCESS_TOKEN -u CODEX_HOME [CODEX_HOME='<dir>'] codex ['<prompt>']
resume:  codex resume <thread-id>
```

The bracketed part is for managed accounts only. **Provider switches** (`CLAUDE_CODE_USE_BEDROCK`,
`CLAUDE_CODE_USE_VERTEX`, `CLAUDE_CODE_USE_FOUNDRY`, `ANTHROPIC_BASE_URL`) beat a claude.ai login, so a
`.zshrc` export would silently reroute a managed account to Bedrock/Vertex/a proxy: they are unset for
managed accounts. The system default account keeps them on purpose: it is "the user's own `claude`",
and someone whose plain `claude` runs on Bedrock from `.zshrc` gets the same inside hdlanes.
`EnvBuilder.claudeStripVariables` / `claudeProviderSwitchVariables` / `codexStripVariables` are the one
source of these lists; `AccountCLI` (status checks, key login) builds its `env -u` line from them.

The PTY's own environment is an allowlist built from the app's environment: `HOME USER LOGNAME SHELL
LANG LC_* TMPDIR PATH` + `TERM=xterm-256color COLORTERM=truecolor TERM_PROGRAM=hdlanes` + hdlanes vars
`HD_SOCKET HD_SESSION_ID HD_ACCOUNT_ID [HD_STATUSLINE_CHAIN]`. Anything `CLAUDE*`, `ANTHROPIC_*`,
`CODEX_*`, `OPENAI_*`, `TMUX*` from the app's own environment is dropped. A managed account's dir
variable (`CLAUDE_CONFIG_DIR` / `CODEX_HOME`) is then set on the PTY itself (session and login
terminals), so a `claude` / `codex` typed in the shell left after the agent runs as the same account.
Known leftover: shell init that exports these variables or credentials still wins in that shell.

Vendor CLI calls for an account (`auth status`, `login status`, `claude -p`, key login) and the login
terminal run with cwd `run/cli/` (empty, hdlanes-owned), never `$HOME`: Claude Code reads
`<cwd>/.claude/settings.json` as project settings, and from `$HOME` that is the system default account's
own file (an `apiKeyHelper` there made every managed account look logged in with an API key).

Shell quoting: single-quote every interpolated value (`'` → `'\''`).

## Claude Code observation (verified with claude 2.1.317)

**Plugin** (generated at launch into `plugin/claude/`): `.claude-plugin/plugin.json`
`{"name":"hdlanes","version":"1","description":"…"}` and `hooks/hooks.json`. Each hook is
`{"type":"command","command":"'<abs path to hdlanes-hook>' <EventName>","async":true}`; `PreToolUse`,
`PostToolUse`, `PostToolUseFailure`, `PermissionRequest` take `"matcher":"*"`.
`PermissionRequest` is **not** async (it blocks for the answer), `timeout` 600.
Use only `--plugin-dir` (not also `CLAUDE_CODE_PLUGIN_DIRS`, that double-loads).

Hook payloads observed (all have `session_id, transcript_path, cwd, hook_event_name`, most `prompt_id,
permission_mode`):

| Event | Extra fields |
|---|---|
| SessionStart | `source` (startup/resume/clear/compact) |
| UserPromptSubmit | `prompt` |
| PreToolUse | `tool_name, tool_input, tool_use_id`, and **`agent_id, agent_type` when inside a subagent** |
| PostToolUse | same + `tool_response, duration_ms` |
| SubagentStart | `agent_id, agent_type` (e.g. "Explore") |
| SubagentStop | `agent_id, agent_type, agent_transcript_path, last_assistant_message, background_tasks[]` |
| Stop | `last_assistant_message, background_tasks[], stop_hook_active` (entry `type`: `subagent`, `workflow`, `teammate`, `cloud session`, `shell`, `monitor`, `MCP task`, … read from the 2.1.317 binary) |
| SessionEnd | `reason` |
| Notification | `notification_type` (`permission_prompt`, `idle_prompt`, `agent_needs_input`, `elicitation_dialog`, …), `message` |
| PermissionRequest | `tool_name, tool_input, permission_suggestions`; `agent_id` inside a subagent (from the hook input schema, not yet observed live) |
| StopFailure | `error` (`rate_limit`, `authentication_failed`, `overloaded`, `billing_error`, …) |

The subagent's task text is the parent's `PreToolUse` with `tool_name == "Agent"` (older: "Task"):
`tool_input.description` (short) / `tool_input.prompt`. It arrives just **before** `SubagentStart`;
pair them FIFO.

**PermissionRequest answer** — hook prints to stdout and exits 0:
`{"hookSpecificOutput":{"hookEventName":"PermissionRequest","decision":{"behavior":"allow"}}}` or
`{"hookSpecificOutput":{"hookEventName":"PermissionRequest","decision":{"behavior":"deny","message":"…"}}}`.
No output → Claude shows its own TUI prompt. While the hook waits, Claude also shows the TUI prompt; if
the user answers there, the hook process is killed. So the sidebar card must clear on the next
`PostToolUse`/`PostToolUseFailure`/`UserPromptSubmit`/`Stop` for that session, or when the hook's socket
connection closes. Exception: a card a subagent asked for (`agent_id`), or one whose hook is still
connected, outlives the main agent's `Stop`/`UserPromptSubmit` (a background agent can still be
waiting); it clears on that agent's own `PostToolUse*`, its `SubagentStop`, `SessionStart`/`SessionEnd`
or a relaunch. Only the hook connection that created the current card can answer it.

After `Stop`, only agent-kind `background_tasks` (`subagent`, `workflow`, `teammate`, `cloud session`, or
an entry without a type) keep the session "working": shells and monitors never send `SubagentStop`.

**Status line**: `--settings` file `{"statusLine":{"type":"command","command":"'<hook>' statusline"}}`.
The hook receives JSON on stdin with `rate_limits.five_hour.used_percentage`, `rate_limits.five_hour.resets_at`
(epoch s), `rate_limits.seven_day.*`, `context_window.used_percentage`, `cost.total_cost_usd`,
`session_id`, `model.display_name`. It forwards it (event `StatusLine`) and, if `HD_STATUSLINE_CHAIN` is
set (the account's own `statusLine.command`), pipes the same JSON to that command and prints its output;
otherwise prints a short line (model · ctx %). Must return fast (<200 ms) and never fail loudly.

**OSC 7501** (claude ≥ 2.1.295): SwiftTerm calls `programStatusChanged(records:)` with
`state ∈ idle|working|done|blocked|error`, `kind ∈ permission|question|auth`. Use as a second, instant
source; hooks stay primary. `done` means the turn completed (Stop follows); `idle` during a turn means it
ended without completing (Esc), and no Stop comes, so that one ends the turn (status ready).

## Codex observation (verified with codex 0.166.0 rollout files)

Rollout files: `$CODEX_HOME/sessions/YYYY/MM/DD/rollout-<ts>-<thread-uuid>.jsonl` (system account:
`~/.codex`). One JSON object per line `{"timestamp","type","payload"}`. Find the session's file: the
**earliest** file created (birth time, not modification time) at or after launch − 5 s whose first line
`session_meta.payload.cwd` equals the session cwd and whose `session_meta.payload.timestamp` (thread
start) is not earlier; sub-agent threads and files claimed by other sessions are skipped. Another Codex
in the same folder and home keeps writing its older file, so modification time would pick it. Its
`payload.id` is the thread id (store it as `agentSessionID` for `codex resume`). Tail it.

| type / payload.type | Meaning |
|---|---|
| `event_msg` / `task_started` | working |
| `event_msg` / `task_complete` (`last_agent_message`) | done |
| `event_msg` / `user_message` (`message`) | prompt |
| `response_item` / `function_call` (`name`, `arguments` JSON string) | tool call → activity |
| `response_item` / `custom_tool_call` (`name`, `input`) | tool call → activity |
| `event_msg` / `patch_apply_end` (`changes`, `success`) | file edits → refresh diff |
| `event_msg` / `token_count` (`rate_limits`) | usage |

`rate_limits`: `{"primary":{"used_percent":100.0,"window_minutes":300,"resets_at":1793707612},
"secondary":{"used_percent":25.0,"window_minutes":10080,"resets_at":…},"plan_type":"plus",…}` — place
windows by `window_minutes` (≈300 → 5h, ≈10080 → week). Seed every Codex account's meter at launch from
its newest rollout file's last `token_count` (passive, no token use).
Needs-you for Codex: terminal title / OSC 7501 `blocked` (title containing "Action Required" or
"approval"). There are no Codex hooks in v0.1.

## Areas and ownership (v0.1 build-out)

| Area | Files | Contract |
|---|---|---|
| shell (done) | `App/*`, `HDCore/{Models,Paths,StateStore,HookProtocol,RuntimeTypes}.swift` | AppModel, SessionRuntime, TerminalRegistry, Theme, L |
| runtime | `Runtime/*`, `HDHook/*`, `HDCore/{EnvBuilder,ShellQuote,ClaudeEventReducer,CodexRollout,UsageParser}.swift` + tests | `Runtime/AppModel+Runtime.swift` signatures |
| git | `Git/*`, `Inspector/*`, `HDCore/{DiffModels,DiffParser,WorktreePlanner}.swift` + tests | `Git/AppModel+Git.swift` signatures, `InspectorView(sessionID:)` |
| workspace | `UI/*`, `HDCore/Categorizer.swift` + tests, `scripts/build-app.sh`, `Resources/*` | `UI/AppModel+Workspace.swift` signatures, `MainWindow`, `SettingsView`, `AppCommands` |

Cross-area calls go only through the signatures in those three `AppModel+*.swift` files. Do not edit
another area's files; if you need something from another area, call its contract method.

## UI guidelines (no "AI slop")

- Native macOS: `NavigationSplitView` sidebar (`.listStyle(.sidebar)`), system fonts, SF Symbols,
  `.regularMaterial` only where macOS uses it. No gradients, no glow, no emoji, no oversized rounded
  cards, no marketing copy, no "✨". Density like Xcode / Mail / Linear's macOS app.
- Text sizes: body 13, secondary 11, monospaced code 12. Secondary info in `.secondary`.
- One color per meaning: status colors (`Theme.color(for:)`), account dot color (`Theme.accountColor`),
  category color (`Theme.categoryColor`). Never more than these.
- Every list has an empty state with one sentence + one action. Every async action has a progress state
  and an error state (`model.show(error:title:)` or inline). No dead buttons: disable with a tooltip
  (`.help`) when unavailable.
- Keyboard first: ⌘N new session, ⌘T new task, ⌘1…⌘9 select session, ⌃⇥ next "needs you", ⌥⌘I inspector.
- Terminal area stays dark in both appearances (TerminalTheme).
