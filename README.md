# hdlanes

A native macOS app for running many Claude Code and OpenAI Codex CLI sessions side by side. Each session
gets its own terminal, its own git worktree and its own account, and you can use several accounts at the
same time.

hdlanes doesn't wrap or replace the agents. It runs the `claude` and `codex` you already have installed,
each in a real terminal, and watches them through Claude Code's hooks and status line and Codex's
session files. It shows you which sessions need you, which are working and which have finished.

## Why

Running more than one agent quickly turns into a pile of terminal tabs. You lose track of which one is
waiting on a permission prompt, which branch each one is on, and which subscription is about to hit its
limit. If you have a personal and a work plan, switching between them means logging out and back in.

hdlanes keeps every session in one window and points each one at the account you chose. You don't have to
log out of anything.

## Features

- **Sessions in a sidebar.** Claude Code, Codex or a plain shell, grouped by project or by category.
  Sessions waiting on you come first. A filter shows only the ones that need you, are working, or are
  done. Unread results show in bold.
- **Real terminals.** Every session is a full terminal (SwiftTerm) running your login shell, so your
  PATH, nvm and aliases work. Switching sessions never restarts a process.
- **One worktree per session.** New sessions can branch into their own git worktree, so two agents never
  edit the same files. Per project you can set the worktree folder, a setup command (for example
  `npm ci`) and gitignored files to copy in (for example `.env`).
- **Several accounts at once.** Add as many Claude and Codex accounts as you like and pick one per session.
  Every account sees the skills, agents, commands and project memory of your default account, so
  switching accounts doesn't mean starting from scratch. See [How accounts work](#how-accounts-work).
- **Import what you already have.** File › Import… (⇧⌘I) finds account folders you already use from the
  terminal or an editor (`CLAUDE_CONFIG_DIR` / `CODEX_HOME` in VS Code, Cursor or Windsurf settings and in
  your shell profile, or `~/.claude-*` / `~/.codex-*` folders) and adds them without a new login. It also
  lists your past Claude Code and Codex conversations (from the terminal, the VS Code extension or the
  desktop apps), grouped by folder, so you can bring them into the sidebar and resume them there. See
  [Importing](#importing).
- **Answer permission prompts from the sidebar.** Claude's tool permission requests show up under the
  session with Allow and Deny. You can add a note when you deny.
- **Subagents at a glance.** Running Claude subagents are listed under their session with the tool they
  are using right now. The **Agents** tab shows every subagent and a live feed of tool calls (Claude and
  Codex).
- **Review the diff, then send notes back.** The **Changes** tab shows the session's changes against its
  base branch. Leave notes on lines and send them to the agent as one message, or push the branch and open
  a pull request with `gh`.
- **Check with another account.** In the **Changes** tab, **Check with…** has another Claude account read
  the diff once (no tools and no MCP servers, so it can't touch your files) and adds what it finds as notes on the lines.
  Edit or delete them, then send them to the session's agent like your own notes. It runs only when you
  click and uses that account's quota.
- **Connections.** Settings › Connections keeps tokens, MCP servers and kubeconfigs for your sessions,
  for all projects or only some. Secrets stay in your Keychain and reach a session only as environment
  variables, never on its command line. Claude sessions also get the MCP servers (a local command or a
  URL with the token in a header). Codex and shell sessions get the variables. For a cluster, give a
  read-only kubeconfig if the agents should only look. A variable your shell profile exports itself
  (for example `export KUBECONFIG=…` in `.zshrc`) wins over the connection's.
- **Browser.** The **Browser** tab opens the dev server URLs a session prints (`localhost:3000` and the
  like) next to its terminal.
- **Clickable paths.** Click a file path in a terminal and it opens read-only in the **File** tab, with
  one click on to your editor, Finder or the clipboard. Folders open in Finder, local dev server links in
  the Browser tab, everything else in the app macOS picks.
- **Usage meters.** Each account shows how much of its 5-hour and weekly limits it has used, taken from
  Claude's status line and Codex's rate-limit events. No extra requests are made.
- **Tracking.** One view for "what's going on, what needs me, what got done". **Today** lists sessions
  and pull requests waiting for you (oldest first, with the reason), what each working agent is doing,
  turns that finished today with their last message, and your open pull requests with CI, review and
  conflict state, above a quiet log of the day. **Pull Requests** shows the ones you opened and the ones
  waiting for your review, read with `gh` (GitHub) and `az` (Azure DevOps); hdlanes only reads them. A
  **Review…** button checks a PR's branch out in a fresh worktree and starts Claude or Codex on it with a
  prompt you can set per project. **End of Day** builds a Markdown report you can copy or save. Activity
  is kept in `~/.hdlanes/activity.jsonl`.
- **Inbox.** Messages that need you (mail and chat), each with a short summary and a suggested reply
  you can edit, send after a confirmation, or open in its app. hdlanes has no mail login of its own: it
  reads through the connectors of a Claude account you pick (Microsoft 365, Gmail, Slack and others in
  claude.ai), allowed only the read tools you tick, and sends only with the one tool you mark for sending.
  It reads only when you press Refresh, and keeps nothing on disk.
- **Task board.** Backlog, Active, Review and Done columns with drag and drop. A session can be started
  from a task and stays linked to it. Categories (bug, feature, refactor, test, docs, UI, chore, research)
  are guessed from English and Turkish keywords. If you turn it on, a single `claude -p` call on an account
  you pick can suggest one instead.
- **Keyboard first.** ⌘N new session, ⌘T new task, ⌘1…⌘9 select a session, ⌃⇥ next session that needs
  you, ⇧⌘B board, ⌥⌘I inspector, ⇧⌘I import.
- **English and Turkish** interface.

## How accounts work

Claude Code and Codex both keep their login, history and settings in one directory, and both let you
choose that directory with an environment variable:

| CLI | Variable | hdlanes account folder |
|---|---|---|
| Claude Code | `CLAUDE_CONFIG_DIR` | `~/.hdlanes/accounts/claude/<id>/` |
| Codex | `CODEX_HOME` | `~/.hdlanes/accounts/codex/<id>/` |

Every account you add in hdlanes gets its own private folder (mode 0700), and each session starts its
agent with that folder's variable set. Two sessions on two accounts are two separate logins that run side
by side.

Your existing logins (`~/.claude` and `~/.codex`) show up as the default **Claude** and **Codex**
accounts. hdlanes starts those **without** setting the variable. Claude Code stores its macOS Keychain
entry under a name derived from the exact config dir string, so setting `CLAUDE_CONFIG_DIR=~/.claude`
would make your existing login look logged out. For the same reason a managed account's folder path is
fixed once and never changes.

**Shared context.** An account hdlanes creates sees what your default account has: for Claude the
`skills/`, `agents/`, `commands/` folders and `CLAUDE.md` of `~/.claude`, and the project's memory; for
Codex `AGENTS.md`, `skills/`, `agents/` and `prompts/` of `~/.codex`. The folders are symlinked into the
account's folder (anything the account already has of its own is left alone), and project memory is
pointed at the default account's (`autoMemoryDirectory`), so what one account learns about a repository
the others read too. Logins, settings and history stay separate. You can turn this off per account in
Settings › Accounts. For an imported folder it is off by default, and turning it on shares only project
memory: hdlanes doesn't add links to a folder it didn't create. While sharing is on, a memory folder the
account built up on its own (`<account>/projects/…/memory`) is left on disk but not read, and an
`autoMemoryDirectory` in the account's own `settings.json` is overridden; turn sharing off to use them.

When hdlanes starts an agent it also unsets credential variables your shell profile might export
(`ANTHROPIC_API_KEY`, `CLAUDE_CODE_OAUTH_TOKEN`, `OPENAI_API_KEY`, …), so they can't override the
account you picked.

Ways to sign in an account:

- **Browser login.** Runs the vendor's own login (`claude auth login`, `codex login`) in a terminal inside
  hdlanes. You sign in on the vendor's page, and hdlanes never sees your password. The browser uses
  whichever account is signed in there, so to add a second account use a private window or another
  browser profile.
- **Token (Claude).** Runs `claude setup-token` (Pro or Max plan, valid for a year). You paste the printed
  token, and hdlanes writes it to that account's `settings.json` (mode 0600).
- **Access token (Codex).** Passed to `codex login --with-access-token` on stdin.
- **API key.** For Claude it is saved in the account folder (0600) and read through `apiKeyHelper`. For
  Codex it is passed to `codex login --with-api-key` on stdin.

hdlanes never reads or prints your existing credentials, and secrets are never written to its own state
file. Removing an account hdlanes created moves its folder to the Trash. Removing an imported account only
removes it from hdlanes; its folder stays where it is. Your default `~/.claude` and `~/.codex` are never
removed.

## Importing

**Accounts.** If you already run `CLAUDE_CONFIG_DIR=~/.claude-work claude` (or set it in the Claude Code
VS Code extension's environment variables, or use a second `CODEX_HOME`), Import › Accounts lists those
folders and adds them as accounts that point at the folder in place. Nothing is copied or moved, and
you don't sign in again. The folder path is kept exactly as you wrote it, because Claude Code's Keychain
entry depends on the exact string (`~/.claude-2` and `~/.claude-2/` are two different logins). You can
also pick a folder yourself. From shell profiles and editor settings hdlanes reads only these two
variables and nothing else. The Claude desktop app keeps its own login, which can't be imported; add that
account with a browser login instead.

**Sessions.** Import › Sessions lists the conversations of every Claude and Codex account from the last
7, 30 or 90 days, grouped by folder, with where each one was started (desktop app, VS Code, terminal).
Imported sessions land in the sidebar under the project that holds their folder (a new project is added
when none does). They aren't running; **Resume** continues the conversation (`claude --resume`,
`codex resume`) in its folder with its account. Runs started with `claude -p` or `codex exec` are hidden
unless you ask for them, and sessions whose folder no longer exists (usually a removed worktree) are
left out. A project's context menu has **Import Past Sessions…**, filtered to that project.

## Requirements

- macOS 14 Sonoma or later (Apple silicon or Intel). hdlanes is macOS only; a Windows port would be a
  separate app, and contributions in that direction are welcome.
- [Claude Code](https://docs.anthropic.com/en/docs/claude-code) and/or the
  [Codex CLI](https://github.com/openai/codex) installed and on your shell's PATH
- git, for worktrees
- To build: Xcode 16 or later, or a Swift 6 toolchain

## Build and install

```sh
cd hdlanes
swift build                       # debug build
swift test                        # unit tests
scripts/build-app.sh              # release build → build/hdlanes.app
scripts/build-app.sh --install    # same, then copy to /Applications
scripts/build-app.sh --zip        # same, plus build/hdlanes-<version>.zip
```

`build-app.sh` signs with the first "Apple Development" identity in your keychain and falls back to
ad-hoc signing. Set `HDLANES_SIGN_IDENTITY=-` to force ad-hoc.

During development you can also start it with `swift run hdlanes`.

hdlanes keeps its data in `~/.hdlanes` (set `HDLANES_HOME` to use another folder). If `state.json` doesn't
decode, hdlanes keeps a copy next to it before starting fresh. If it can't be read at all, hdlanes leaves it
alone, shows a banner and doesn't save until the problem is fixed.

## Status and known limits (v0.1)

- Folder-trust questions from Claude Code and Codex in a new worktree are answered in the terminal.
- Codex permission prompts are answered in the terminal; Allow/Deny in the sidebar is Claude only for now.
- Quitting hdlanes ends every session's processes. Claude and Codex sessions can be resumed afterwards
  (`claude --resume`, `codex resume`).

## Acknowledgements

hdlanes is inspired by:

- [omux](https://github.com/onurozcan/omux) by onurozcan (MIT license)
- [Harp](https://github.com/dominikmartn/harp) by dominikmartn

The terminal is [SwiftTerm](https://github.com/migueldeicaza/SwiftTerm) by Miguel de Icaza.

## Disclaimer

hdlanes is an independent project. It is not affiliated with, endorsed by or sponsored by Anthropic or
OpenAI. Claude and Claude Code are trademarks of Anthropic. Codex and ChatGPT are trademarks of OpenAI.

## License

MIT. See [LICENSE](LICENSE).
