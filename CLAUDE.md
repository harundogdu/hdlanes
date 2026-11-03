# hdlanes — notes for coding agents

- Read `docs/ARCHITECTURE.md` first. It is the contract: on-disk layout, launch recipe, verified hook and
  Codex rollout fields, area ownership, UI rules.
- Build: `swift build`. Tests: `swift test`. App bundle: `scripts/build-app.sh` (installs to /Applications
  only with `--install`).
- UI strings only through `L` (English + Turkish via `pick`). No literal text in views.
- A file importing SwiftUI must not import SwiftTerm (`Color` collides).
- Code comments in English; keep them short and only where intent isn't obvious.
- Never read, print or log credentials (Keychain items, auth.json, tokens). Only names/existence.
- Commit messages: no `Co-Authored-By` trailer.
