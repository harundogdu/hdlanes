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
  See [How accounts work](#how-accounts-work).
- **Answer permission prompts from the sidebar.** Claude's tool permission requests show up under the
  session with Allow and Deny. You can add a note when you deny.
- **Subagents at a glance.** Running Claude subagents are listed under their session with the tool they
  are using right now.
- **Usage meters.** Each account shows how much of its 5-hour and weekly limits it has used, taken from
  Claude's status line and Codex's rate-limit events. No extra requests are made.
- **Task board.** Backlog, Active, Review and Done columns with drag and drop. A session can be started
  from a task and stays linked to it. Categories (bug, feature, refactor, test, docs, UI, chore, research)
  are guessed from English and Turkish keywords. If you turn it on, a single `claude -p` call on an account
  you pick can suggest one instead.
- **Keyboard first.** ⌘N new session, ⌘T new task, ⌘1…⌘9 select a session, ⌃⇥ next session that needs
  you, ⇧⌘B board, ⌥⌘I inspector.
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
file. Removing an account moves its folder to the Trash. Your default `~/.claude` and `~/.codex` are never
removed.

## Requirements

- macOS 14 Sonoma or later (Apple silicon or Intel)
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
