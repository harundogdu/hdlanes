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
accounts/claude/<uuid>/            CLAUDE_CONFIG_DIR of a managed Claude account (0700); skills, agents,
                                   commands, CLAUDE.md may be symlinks into ~/.claude (shared context)
accounts/codex/<uuid>/             CODEX_HOME of a managed Codex account (0700); AGENTS.md, skills, agents,
                                   prompts may be symlinks into ~/.codex
plugin/claude/                     generated plugin: .claude-plugin/plugin.json + hooks/hooks.json
themes/                            imported terminal themes (Ghostty files, .itermcolors)
run/hd.sock                        hook socket (run/ is 0700)
run/sessions/<uuid>/mcp.json       per-session --mcp-config of the session's MCP connections (0600, no secrets)
run/sessions/<uuid>/settings.json  per-session --settings (statusLine → hdlanes-hook statusline,
                                   autoMemoryDirectory for a managed account that shares context)
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
`HD_SOCKET HD_SESSION_ID HD_ACCOUNT_ID [HD_STATUSLINE_CHAIN] [HD_ACCOUNT_LABEL]`. Anything `CLAUDE*`, `ANTHROPIC_*`,
`CODEX_*`, `OPENAI_*`, `TMUX*` from the app's own environment is dropped. A managed account's dir
variable (`CLAUDE_CONFIG_DIR` / `CODEX_HOME`) is then set on the PTY itself (session and login
terminals), so a `claude` / `codex` typed in the shell left after the agent runs as the same account.
Known leftover: shell init that exports these variables or credentials still wins in that shell.

Vendor CLI calls for an account (`auth status`, `login status`, `claude -p`, key login) and the login
terminal run with cwd `run/cli/` (empty, hdlanes-owned), never `$HOME`: Claude Code reads
`<cwd>/.claude/settings.json` as project settings, and from `$HOME` that is the system default account's
own file (an `apiKeyHelper` there made every managed account look logged in with an API key).

Shell quoting: single-quote every interpolated value (`'` → `'\''`).

## Shared context (runtime area)

A managed account is a separate config dir, so on its own it sees none of the default account's
skills, agents, commands, global instructions or project memory. `HDCore/SharedContext.swift` (pure,
tested with temp dirs) and `Runtime/AppModel+SharedContext.swift` share them. Per account
`Account.sharesDefaultContext`; nil means on for dirs under `accounts/`, off for imported folders.

**Links.** Claude: `CLAUDE.md skills agents commands` from `~/.claude`; Codex: `AGENTS.md skills agents
prompts` from `~/.codex` (Codex reads `$CODEX_HOME/skills` and `agents/`). Each entry is one symlink
with an absolute target (`~/.claude/skills` holds relative symlinks that only resolve through the real
folder). Only in dirs hdlanes created (`isInsideAccountsDir`). An entry the account already has (a file,
a folder, a symlink elsewhere) is never replaced; a link of ours whose target vanished is removed; a
source created later is linked next time. Synced at app start, at account creation, on every launch of
a session on that account, and when the setting changes (off removes only our links). Never linked:
`settings.json`, `.claude.json`, `config.toml`, `auth.json`, plugins, history. Because the links are
whole folders, a skill installed from a managed account lands in the default account's folder.

**Memory** (Claude, verified with claude 2.1.318). Auto memory lives in
`<config>/projects/<key>/memory/`, where `<key>` is the repository's main working tree (a linked
worktree resolves to its main repository; symlinks resolved; the folder itself outside git) with every
character outside `[a-zA-Z0-9]` turned into `-`. Claude reads `autoMemoryDirectory` from policy, flag
(`--settings`), local, project (not honored there) and user settings, in that order, and uses the value as
the memory dir itself. So a managed account's session `--settings` gets
`"autoMemoryDirectory": "~/.claude/projects/<key>/memory"` (absolute), and both accounts read and write
the same `MEMORY.md`. Claude doesn't create a custom memory dir at startup, so hdlanes creates it
(`mkdir -p`) before the launch. Keys longer than 200 characters get a hash suffix in Claude Code that hdlanes
doesn't reproduce; those projects don't share memory. The settings file is written when there is a
hook or a memory dir, so memory sharing doesn't depend on the hook binary. Live check: `/context all` in
a managed-account session lists `<that dir>/MEMORY.md` under Memory files and the linked agents/skills
under User.

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
otherwise prints `HDCore/StatusLine`: account label (`HD_ACCOUNT_LABEL`, control characters stripped,
≤24 chars) · model · ctx % · 5h % · 7d %, percentages green / yellow (≥60) / red (≥85), with the reset
time once a window is ≥80 % used. Must return fast (<200 ms) and never fail loudly.

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

## Connections (runtime + workspace areas)

`HDCore/Connections.swift` (model, validation, environment and MCP config builders; tested),
`Runtime/ConnectionSecrets.swift`, `Runtime/AppModel+Connections.swift`, `UI/ConnectionsView.swift`
(Settings › Connections). `AppState.connections` holds metadata only: name, kind, variable, command and
arguments or URL and header, kubeconfig path, project scope (nil/empty = all projects), on/off.

- **Secrets** are Keychain generic passwords: service `hdlanes.connections.<first 4 bytes of
  sha256(hdlanes home path)>`, account = connection id. A test home (`HDLANES_HOME`) has its own
  service and never sees the real app's items. Secrets are never logged or written to state.json.
- **Kinds.** `token`: the secret as `<VARIABLE>`. `mcpCommand`: Claude starts `command args…`, with
  `env: {VAR: "${VAR}"}` when there is a secret. `mcpURL`: `{"type":"http","url",headers:{<header>:
  "<prefix>${VAR}"}}`. `kubeconfig`: `KUBECONFIG=<path>`; read-only is a property of the credentials in
  that file, which the UI says.
- **At launch** the applying connections' variables go into the PTY environment (after the
  `baseEnvironment` allowlist), never into the pasted command line (scrollback, shell history, `ps`).
  Claude sessions also get `--mcp-config run/sessions/<id>/mcp.json`, rewritten on every fresh launch
  (removed when empty). claude 2.1.318 loads `--mcp-config` files with variable expansion on (`expandVars:!0`
  for both files and inline JSON), so the file holds `${VAR}` references only. Codex sessions and plain
  shells get the variables but no MCP servers. A session restarted in its open terminal keeps the
  variables it started with; MCP changes apply on the next launch.
- **Reserved names** can't be used (validated on save and filtered again at launch): anything with the
  `CLAUDE`, `ANTHROPIC_`, `CODEX_`, `OPENAI_`, `TMUX`, `HD_`, `LC_` prefixes, the strip and provider-switch
  lists, the PTY allowlist (`PATH`, `HOME`, `SHELL`, …), terminal variables, `DYLD_*`/`LD_*`,
  `NODE_OPTIONS` and the proxy variables. `KUBECONFIG` only through the kubeconfig kind. Two connections
  may share a variable (or an MCP server name) only when no project gets both. A session restarted in
  its open shell reuses the MCP file it started with, so it never references a variable its terminal
  lacks. The MCP header prefix is stored as typed (`Bearer ` is only the default for a new URL server).

## Import (workspace area)

`HDCore/ImportScanner.swift` (pure, file-system reads only, every root a parameter, tested with temp
dirs), `UI/AppModel+Import.swift`, `UI/ImportSheet.swift`, `UI/L10n+Import.swift`. Opened from File ›
Import… (⇧⌘I, `AppModel.importPreset`), the welcome screen, a project's context menu (Sessions tab,
search prefilled with the project path) and the accounts list (Accounts tab).

**Account folders.** Sources, all optional:
- VS Code-family settings `~/Library/Application Support/{Code,Code - Insiders,Cursor,Windsurf,VSCodium}/User/settings.json`
  (JSONC: comments stripped outside strings): `{"name":"CLAUDE_CONFIG_DIR","value":"…"}` in either key
  order (`claudeCode.environmentVariables`) and `"CLAUDE_CONFIG_DIR": "…"` keys (terminal env); same for
  `CODEX_HOME`. Absolute values only, verbatim.
- Shell profiles `~/.zshrc ~/.zprofile ~/.zshenv ~/.bashrc ~/.bash_profile ~/.profile`: `VAR=<value>`
  anywhere in a non-comment line (exports, assignments, alias bodies), quoted or bare. A leading `~`,
  `$HOME`, `${HOME}` is expanded; any other `$` or a backquote skips the value. Only these two variables
  are extracted; nothing else from these files is kept or logged.
- `~/.claude*` / `~/.codex*` dirs (not `.claude`/`.codex`) that look like one: Claude has `.claude.json`,
  `projects/` or `settings.json`; Codex has `auth.json`, `config.toml` or `sessions/`. Stored as the plain
  path; merged into a shell/editor candidate naming the same folder (that string wins).
- A folder the user picks (provider from the markers above, else asked).

The string from a profile or editor setting is kept byte-exact (trailing slash too): it becomes the
account's `configDir`, and Claude's Keychain key hashes it. Dedupe by exact string. Excluded: missing
dirs, `~/.claude` / `~/.codex` (with or without trailing slash), anything under `~/.hdlanes/accounts`, and
dirs an account already uses (exact match; home and chosen folders also trailing-slash-insensitive). An
imported account is `isSystemDefault: false`, `authMethod: .existing`, label from the folder name
(`.claude-work` → "Claude work"); its health is checked like any other. Removing it only forgets it:
`removeAccount` trashes nothing outside `~/.hdlanes/accounts`, and the dialog says the folder stays.

**Sessions.** Claude: `<configDir>/projects/<encoded-cwd>/<session-uuid>.jsonl`, top level only
(`<uuid>/` subfolders hold subagents); `~/.claude` for the system account. Codex: rollout files as
above (`.zst` skipped, sub-agent threads skipped via `CodexRollout.isChildThread`), titles from
`<codexHome>/session_index.jsonl` (`{id, thread_name}`) when present. Newest first by file mtime, within
the chosen window, at most 400 per account. A file is never read whole when it is over 512 KB: only its
first and last 256 KB (median transcript 1.6 MB, largest seen 1.3 GB); partial lines at the cuts are
dropped. Claude fields:
- `cwd`, `entrypoint`, `gitBranch` from `"user"` records; the branch of the last non-sidechain user
  record wins. Entrypoints: `claude-desktop`, `claude-vscode`, `cli`; `sdk-*` (`claude -p`) is headless
  and hidden unless asked for. Codex: originator `Codex Desktop` / `codex_vscode` / `codex-tui`,
  `source: "exec"` is headless (Codex Desktop writes `source: "vscode"`, so the originator decides).
- First prompt: first `"user"` record with `isSidechain != true`, `isMeta != true` whose content (string,
  or the first `{type:"text"}` block) doesn't start with `<` (command/caveat/reminder wrappers) and isn't
  tool-result only.
- Title: the last `custom-title` in the tail chunk, else in the head, else the first prompt, else the
  `last-prompt` record; first line, 80 characters.

Importing a session: project = the one whose path contains the cwd (deepest; component boundaries), else
the one whose worktree folder contains it, else `addProjectReturningID(cwd)` (repository root, deduped);
shorter cwds are imported first so a repo's own sessions create its project. The `AgentSession` gets
`agentSessionID`, `branch`, `lastActivityAt` = file mtime (non-nil, so it is never treated as a first
launch), `createdAt` = first record time, a `Categorizer` category, no `initialPrompt`, no
`worktreePath`. It is not launched; the sidebar shows it as not running and Resume runs
`claude --resume <id>` / `codex resume <id>` in its cwd with the account's env. A session id already in
the sidebar is shown as added; one that was closed (archived) is brought back instead of duplicated.
Sessions whose cwd no longer exists are counted, not listed. Known limit: `repositoryRoot` of a linked
worktree is the worktree itself, so a session in a worktree outside any project's folder becomes its own
project.

## Tracking (tracking area)

`HDCore/{ActivityLog,PullRequest,PullRequestParsers,DaySummary,Paths+Tracking}.swift` (pure, tested),
`Tracking/*` (app side). The sidebar's **Takip / Tracking** row (`SidebarSelection.tracking`) opens it.

**Activity log.** `~/.hdlanes/activity.jsonl`, append-only, one `ActivityEvent` per line
(`{at, kind, sessionID?, projectID?, title, detail?, prURL?}`, ISO 8601 dates). Kinds: `sessionStarted`
(first launch only), `turnDone` (detail = the agent's last assistant message), `needsYou`, `error`,
`sessionClosed` (archive), `prOpened` (`createPullRequest`), `prMerged` (one of my PRs left the open list
and `gh pr view` / `az repos pr show` says merged/completed), `reviewStarted`, `taskMoved`. `detail` is
flattened and capped at 500 characters; no secrets go in. An event identical to the session's previous
one within 30 minutes is dropped (`ActivityDebouncer`). Readers take only the last 2 MB of a file; past
5 MB the file is moved to `activity-YYYY-MM.jsonl` (month of the rotation; appended to if it exists).
Writes come from one-line calls in other areas: `statusChanged` → `trackingStatusChanged`, `launch` →
`recordActivity(.sessionStarted)`, `archiveSession`, `setTaskStatus`, `createPullRequest`. A turn that
ends also stores `AgentSession.lastResult` / `lastResultAt`.

**Pull requests.** For each project, `git remote get-url origin` is parsed by `RemoteRepo.parse`
(GitHub https/ssh, Azure DevOps `dev.azure.com`, `{org}.visualstudio.com`, `ssh.dev.azure.com:v3`);
projects sharing a repository are read once. GitHub: `gh pr list --repo o/r --state open --json
<GitHubPRParser.jsonFields>` with `--author @me` and with `--search review-requested:@me`. Azure:
`az repos pr list --org https://dev.azure.com/{org} --project … --repository … --status active --detect
false -o json` with `--creator <me>` and `--reviewer <me>` (me = `az account show --query user.name`,
cached), and for at most 15 of my PRs (4 at a time) `az repos pr policy list --org … --id N`
(no `--project` flag there). Azure CI comes only from `Build`/`Status` policy evaluations: other policies
(merge strategy, reviewer minimums) report `rejected` on healthy PRs. Votes: 10/5 approved, 0 none,
-5 waiting for author, -10 rejected. `az` is found like `gh` (Homebrew paths, then a login shell); calls
time out after 30 s; a missing CLI, a missing login (`gh auth login`, `az login`, `AADSTS…`) and network
errors are shown inline per tool. Refresh: once at launch (sidebar row), on opening Tracking, every
3 minutes while it is visible, after `createPullRequest`, and by hand. A PR links to a session when the
session's project has the same repository and `session.branch == pr.sourceBranch`.

**What the lists leave out.** A PR whose `updatedAt` is more than `PullRequest.staleDays` (30) days ago
is stale; Azure lists carry no update time, so Azure PRs are never stale (only the vote rule trims them).
`isWaitingForMe` (`needsMe` and not stale) drives Today's *waiting*, the sidebar badge and the day
summary alike. PRs tab: *mine* hides stale PRs (`activeMine`); *review
requested* hides stale PRs and the ones I already voted on (`openReviewRequests`). Hidden PRs sit behind
a "N … · Show" line. Today tab: *waiting* leaves out stale PRs; *my open PRs* shows only PRs that moved
in the last 7 days and aren't already under waiting; the flow leaves out `turnDone` (listed under
*finished today*).

**Work items** (`HDCore/WorkItem.swift`, `Tracking/AppModel+WorkItems.swift`, `Tracking/WorkItemsTab.swift`).
Azure Boards items for every Azure DevOps (org, project) the projects' `origin` remotes point at, read
only while the **Work Items** tab is open (on opening, every 5 minutes, and when the people list changes).
Per project, `az boards query --org … --project … --detect false -o json --wiql …` (60 s timeout), three
WIQL queries: mine open (`[System.AssignedTo] = @Me`, state not Closed/Done/Removed); teammates' open items
changed in the last 30 days; state changed since yesterday (`Microsoft.VSTS.Common.StateChangeDate >=
@Today - 1`) for me and teammates. Teammates are `AppSettings.trackedPeople` (email / unique name or display
name, both match `[System.AssignedTo]`; verified live), edited in the tab's People… sheet, with suggestions
from Azure PR authors and seen assignees. Names become WIQL literals via `WorkItemQuery.literal` (`'` doubled;
control characters and brackets rejected). Mine is grouped by state (in-flight states first, not-started
last), five rows per group, and items unchanged for 30 days sit behind a Show line. "Changed by" is the
last changer, not necessarily who moved the state; old → new state needs the updates API (not read).
Rows open `https://dev.azure.com/{org}/{project}/_workitems/edit/{id}`. A failed read keeps the last lists.

**Read-only rule.** Tracking never comments, votes, approves, completes, pushes or edits a PR. The only
writes are local: the review worktree and session, the activity log and saved reports
(`~/.hdlanes/reports/YYYY-MM-DD.md`).

**Review sessions.** `git fetch origin <source> <target>`, then `git worktree add --detach
<worktree parent>/review-<n>-<slug> origin/<source>` (no branch is created), `copyFiles` copied, and an
`AgentSession` with `worktreePath`, `branch = source`, `baseRef = origin/<target>`, category `review`,
`reviewPullRequestURL`, and `initialPrompt = ReviewPrompt.render(project.reviewPromptTemplate, pr:)`
(placeholders `{url} {number} {title} {source} {target} {repo}`). The default account is a Claude account
other than the one that ran the PR's own session.

**End of day.** `DaySummary.markdown` over the day's events plus what is open now; the optional
"Summarize with AI" runs one `claude -p --output-format json --model haiku` on a chosen Claude account,
only on click.

## Check with another account (git area)

`HDCore/CrossCheck.swift` (pure, tested), `Git/AppModel+CrossCheck.swift`, `Git/L10n+CrossCheck.swift`,
the "Check with…" menu in the Changes footer. On click only: the diff is refreshed and rendered per file
with `N<new line>` / `O<old line>` prefixes (cut at 120 000 characters, the prompt says so), then one
`claude -p` with `CrossCheck.claudeArguments` (`--output-format json --model sonnet
--no-session-persistence --tools "" --disallowedTools "mcp__*" --strict-mcp-config --mcp-config
'{"mcpServers":{}}' --disable-slash-commands`) runs on the chosen Claude account (accounts other than the
session's own are listed first) with the prompt on stdin, cwd `run/cli/`. `--tools ""` alone removes only
built-in tools: user-scope and plugin MCP servers would still load (8 did on a test account), so MCP is
shut off too. Verified with `--output-format stream-json --verbose`: the `init` event lists no tools, MCP
servers, skills or slash commands. The diff is untrusted, so the checker only reads what it is given and
the prompt tells it to ignore instructions inside the diff.
The reply is a JSON array `{file, line, removedLine, note}` (first array in the text, fences tolerated).
Each finding is anchored to the snapshot that was sent (exact path, else a unique path suffix; a line
not in the diff becomes a file-level note; an unknown file becomes a file-level note on the first file
with the path in its text, so nothing is sent unseen; line numbers that aren't positive integers are
dropped) and added as a `ReviewNote` prefixed
with `[<account label>]`, so the user edits or deletes it and sends the notes to the session's agent the
usual way. Works for Claude and Codex sessions. Verified live with claude 2.1.318: `--tools ""` + stdin
prompt → one turn, JSON array reply.

A Codex account can be the checker too: `codex exec` with `CrossCheck.codexArguments` (`--sandbox
read-only --skip-git-repo-check --ephemeral --ignore-user-config --ignore-rules --color never --json`,
`--disable` for shell_tool, unified_exec, apps, plugins, multi_agent, image_generation, browser_use,
computer_use, view_image, hooks, goals, `-c web_search="disabled"` (the default is `cached`, i.e. on),
`-c approval_policy="never"`, `-c project_doc_max_bytes=0`, prompt on stdin via `-`). Verified with codex
0.166.0: asked to run `ls /` it answers that it has no tool; the real prompt with a small diff returns the
JSON array. `apply_patch` (and `update_plan`) are still offered, not behind a feature flag, but every
write is rejected by the read-only sandbox with approvals set to never, so no tool can act.
`--ignore-user-config` drops only `$CODEX_HOME/config.toml`; `$CODEX_HOME/AGENTS.md` is still injected
and can change the reply's shape (then the run reads as unreadable). `HDCore/CodexExecOutput` reads the
JSONL: the last `item.completed` agent message is the reply unless a `turn.failed` follows; an `error`
event is not terminal (retried stream errors) and is shown only when no `turn.completed` follows it.

## Inbox (inbox area)

`HDCore/Inbox.swift` (arguments, prompts, parsing; tested), `Inbox/*` (store, model, view, strings). The
sidebar's **Inbox** row (`SidebarSelection.inbox`). No chat screen, no mail client, no app
registration: messages are read and answered through the MCP connectors of one Claude account (claude.ai
connectors such as Microsoft 365, Gmail, Slack, or that account's MCP servers).

- **Setup.** Pick the account, then **Load Tools**: one `claude -p --output-format stream-json --verbose
  --model haiku --tools "" --permission-mode dontAsk` run whose first line (`system/init`) lists the
  `mcp__…` tool names and each MCP server's status; servers that aren't `connected` (`needs-auth`) are
  named with how to sign in. Every inbox run sets `MCP_CONNECTION_NONBLOCKING=false` on the command line:
  since claude 2.1.319 claude.ai connectors connect in the background, so without it the init line (and
  the first turn) come before their tools. The list is grouped by server (`Inbox.groups`, mail and chat
  servers first) with readable action names; `Inbox.toolInfo` sorts each tool into read / send / change by
  the words in its name (unknown → change), shown folded away. "Select readers" marks a group's read
  tools; it is only a hint, the user still owns every choice. The user marks tools as Read or Send (one Send tool). Stored in
  `AppSettings.inbox*`; names must be plain `mcp__[A-Za-z0-9_-]+` so they can't widen `--allowedTools`.
- **Refresh** (click only): `claude -p --output-format json --model sonnet --no-session-persistence
  --tools "" --permission-mode dontAsk --allowedTools <read tools> --disable-slash-commands`, prompt on
  stdin: messages from the last N hours that need the user, as a JSON array `{source, messageID, from,
  subject, received, summary, suggestedReply, link}`; message contents are data; change nothing. Items
  without id or sender are dropped; only https links are kept. Items live in memory only.
- **Refresh denies the Send tool explicitly** (`--disallowedTools`): `dontAsk` turns unanswered prompts
  into denials but keeps `permissions.allow` rules from the account's own settings, and a deny rule
  beats them. Another allow rule in those settings could still widen a run; keep inbox accounts' allow
  lists empty for MCP tools.
- **Reply.** The suggested reply opens in an editor; **Send…** shows the exact text in a confirmation
  dialog; then one run allowed only the Send tool, told to send that text unchanged and answer `SENT`.
  Sender-written fields (source, id, from, subject) are flattened to one line, stripped of quotes and
  markers and capped before they reach that prompt. A run that times out hides the item and says the
  reply may have been sent, so it isn't sent twice.
- Verified with claude 2.1.318: `dontAsk` + `--allowedTools X` lets the model call X and refuses any
  other MCP tool (`permission_denials`); the init line lists claude.ai connector tools and a
  `needs-auth` status for a connector that isn't signed in for `-p`. Not run against real mail.

## AI category suggestion (workspace area)

Off unless `settings.aiCategorization`. `settings.aiProvider` picks the model (nil = `claude`):

- `claude`: one `claude -p --model haiku` on `aiCategorizationAccount` (`Categorizer.aiPrompt`/`parseAIAnswer`).
- `jev`: TypeSafe Jev, `POST https://api.typesafe.ai/v1/systemone` with `Authorization: Bearer <key>`;
  one `choice` question whose `criteria` describe each category (`HDCore/Jev.swift`). The answer's
  `choice` is used when `confidence ≥ 0.35`, else the category stays. The key lives in the Keychain under
  `AppModel.jevKeyID` (same service as connection secrets), never in state.json. Jev is a decision
  model and writes no text, so the end-of-day summary still uses a Claude account. Verified live: no key
  → HTTP 403 `{"detail":{"error_type":"authentication_error","message":…}}`.

## Areas and ownership (v0.1 build-out)

| Area | Files | Contract |
|---|---|---|
| shell (done) | `App/*`, `HDCore/{Models,Paths,StateStore,HookProtocol,RuntimeTypes}.swift` | AppModel, SessionRuntime, TerminalRegistry, Theme, L |
| runtime | `Runtime/*`, `HDHook/*`, `HDCore/{EnvBuilder,ShellQuote,ClaudeEventReducer,CodexRollout,UsageParser,SharedContext,Connections}.swift` + tests | `Runtime/AppModel+Runtime.swift` signatures |
| git | `Git/*`, `Inspector/*`, `HDCore/{DiffModels,DiffParser,WorktreePlanner,FilePreview}.swift` + tests | `Git/AppModel+Git.swift` signatures, `InspectorView(sessionID:)` |
| workspace | `UI/*`, `HDCore/{Categorizer,ImportScanner,Jev}.swift` + tests, `scripts/build-app.sh`, `Resources/*` | `UI/AppModel+Workspace.swift` signatures, `MainWindow`, `SettingsView`, `AppCommands` |
| inbox | `Inbox/*`, `HDCore/Inbox.swift` + tests | `Inbox/AppModel+Inbox.swift` (`refreshInbox`, `sendInboxReply`, `loadInboxTools`) |
| tracking | `Tracking/*`, `HDCore/{ActivityLog,PullRequest,PullRequestParsers,DaySummary,Paths+Tracking,WorkItem}.swift` + tests | `Tracking/AppModel+Tracking.swift` (`recordActivity`, `trackingStatusChanged`, `pullRequestOpened`, `recordTaskMoved`) |

Cross-area calls go only through the signatures in those three `AppModel+*.swift` files. Do not edit
another area's files; if you need something from another area, call its contract method.

## Seeing the UI without screen recording (dev aid)

`App/DevSnapshot.swift`: started with `HDLANES_SNAPSHOT_DIR=<dir>` (and always a test home,
`open -n build/hdlanes.app --env HDLANES_HOME=/tmp/hdt --env HDLANES_SNAPSHOT_DIR=<dir>`), the app walks
a fixed tour (first session, Tracking, Inbox, Board, each Settings tab hosted in a window of its own),
draws each window into `<name>.png` with `cacheDisplay` (no Screen Recording permission needed), puts
back the user's last Settings tab and quits. Layer-drawn content (the SwiftTerm terminal) comes out
blank in these images, and the Settings tab bar is drawn without its toolbar styling. Off unless the
variable is set.

## Terminal links (git area)

SwiftTerm checks a clicked link first (unsafe characters and executables, scripts such as `.sh`/`.py` and
apps are blocked; custom schemes are asked about), then calls `requestOpenLink`; `HDTerminalView` overrides it and hands the URL to
`AppModel.openTerminalLink` (`Inspector/AppModel+FilePreview.swift`):

- `file://` to a regular file → `filePreviews[session]`, the **File** tab (`Inspector/FilePanel.swift`).
  `HDCore/FilePreview` reads at most 2 MB as UTF-8; NUL bytes or bad UTF-8 count as binary, image types
  are drawn with `NSImage`. Credential files (`auth.json`, `.credentials.json`, `.env*`, `~/.ssh/*`, `~/.aws/*`, `~/.kube/config`, keys)
  are not read. Nothing is written; the header menu opens it in the default app after re-checking it isn't
  executable, a script or an app by then (otherwise it only reveals it in Finder).
- `file://` to a folder → opened in Finder. `http(s)` to localhost / 127.0.0.1 / 0.0.0.0 (as localhost) /
  [::1] → the Browser tab.
  Anything else → `NSWorkspace.open`, as before.

Paths without an OSC 8 link are resolved by SwiftTerm against the app's own working directory, so only
absolute and `~/` paths open, and a `:line` suffix is dropped.

## UI guidelines (no "AI slop")

- Native macOS: `NavigationSplitView` sidebar (`.listStyle(.sidebar)`), system fonts, SF Symbols,
  `.regularMaterial` only where macOS uses it. No gradients, no glow, no emoji, no oversized rounded
  cards, no marketing copy, no "✨". Density like Xcode / Mail / Linear's macOS app.
- Text sizes: body 13, secondary 11, monospaced code 12. Secondary info in `.secondary`.
- One color per meaning: status colors (`Theme.color(for:)`), account dot color (`Theme.accountColor`),
  category color (`Theme.categoryColor`). Never more than these.
- Every list has an empty state with one sentence + one action; side panels use `CompactEmptyState`
  (13 pt title), not `ContentUnavailableView`'s large title. Every async action has a progress state
  and an error state (`model.show(error:title:)` or inline). No dead buttons: disable with a tooltip
  (`.help`) when unavailable.
- Keyboard first: ⌘N new session, ⌘T new task, ⌘1…⌘9 select session, ⌃⇥ next "needs you", ⌥⌘I inspector, ⇧⌘I import.
- Terminal colors come from `TerminalPalette` (HDCore): built-ins (hdlanes' own dark palette is the
  default and stays dark in both appearances) or a Ghostty / iTerm2 theme file in `themes/`, chosen in
  Settings › Terminal and stored as `settings.terminalTheme` (`builtin:<id>` / `file:<name>`; unknown ids
  fall back to the default). Colors an imported theme leaves out come from the default palette.
  `terminalFont` is a fixed-pitch family (nil = SF Mono). Changes apply to open terminals at once
  (`TerminalRegistry.applyAppearance`).
- A session with an account shows the account's color as a 2 pt line above its terminal.
