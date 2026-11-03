# Spelunk

Spelunk is a macOS app for reading, tracing and reviewing code. The editor is read-only: you
navigate a repository, follow definitions and callers, record the path a request takes through the code, and
review changes hunk by hunk, from your working copy, a jj change, a git range or a GitHub pull
request. Rust has the most support. Swift works through sourcekit-lsp and an installable grammar,
and other languages get highlighting and an outline from tree-sitter grammars you install.

## What it does

- Code navigation with go to definition, references, callers and callees, implementations and hover
  cards. Every answer is labeled with the provider that produced it, and providers fall back from
  most to least precise.
- Code paths: named, ordered lists of locations with a note on each, which you build by hand or ask
  Claude to generate from a question.
- Review: each hunk is sorted into a tier (Critical, Behavior, Plumbing, Docs, Tests, Mechanical) by
  a rules file you can extend, related hunks are grouped, and Claude can re-check the tiers, write
  an overview and suggest a reading order.
- GitHub pull requests through `gh`: threads on their lines, checks, local draft comments, and one
  submitted review. A local jj change or git branch with an open pull request picks up that PR's
  threads while the diff stays local.
- Ask Claude about the code with read-only tools; any number of questions and generated traces can
  run at once.
- An optional vim mode for the code view.

## Requirements

- macOS 15 or later
- Xcode 16 or later (Swift 6 toolchain) to build

Optional tools, found on `PATH` or in the usual install locations:

| Tool | Used for |
|---|---|
| `rust-analyzer` | Rust code intelligence and SCIP index generation (also found in Zed and VS Code installs, and Homebrew) |
| `sourcekit-lsp` | Swift code intelligence (found through `xcrun`) |
| `rg` | text search and name-based fallbacks (a slower built-in search is used without it) |
| `jj`, `git` | history, diffs and review targets |
| `gh` | GitHub pull requests, using its authentication |
| `cargo` | `cargo clippy` diagnostics |
| `claude` | Claude features (asks, traces, classification, triage, attachments) |

## Build and run

```sh
./scripts/bundle.sh                          # release build, writes dist/Spelunk.app
open dist/Spelunk.app --args -repo ~/path/to/repo
```

`swift build` and `swift test` work as usual. See [docs/development.md](docs/development.md).

## Quick start

1. Open a repository with ⌘O. Each repository gets its own window, and windows come back on relaunch.
2. Press ⌘K to open a file, or browse the Files tab. Click a symbol to see its definition, callers
   and references in the context pane; ⌘-click or ⇧⌘D goes to the definition, ⌘[ goes back.
3. Press ⇧⌘T to add the cursor location to a code path.
4. The Review tab always shows your working copy's changes. Press J and K to move between hunks and
   V to mark one viewed. Use the review menu in the toolbar to review a jj change, a git range or a
   pull request.
5. Press ⌘L to ask Claude a question about what you are looking at.
6. For Swift, install the Swift grammar from Settings › Languages › Presets.

## Code intelligence

Navigation asks providers in order of precision and falls back when one has no answer. Results from
anything weaker than a language server carry a tag naming their source.

| Provider | Used for |
|---|---|
| rust-analyzer, sourcekit-lsp (LSP) | definition, references, hover, call hierarchy, implementations, workspace symbols |
| SCIP (`rust-analyzer scip`, cached per repository) | the same queries for Rust while rust-analyzer starts, or without it |
| tree-sitter (bundled Rust grammar, installed grammars) | highlighting, outline, enclosing items, test regions, callees, change classification |
| ripgrep | text search and name-based fallbacks |
| `cargo clippy` | diagnostics in the gutter and the Problems pane |
| Claude (`claude` CLI) | questions, generated traces, review classification and triage, rule questions, attachments |

## Documentation

- [User guide](docs/user-guide.md): windows, reading code, code paths, reviewing, Claude, settings
- [Keyboard reference](docs/keyboard.md): menu shortcuts, review keys, palette commands, vim mode
- [Review rules](docs/rules.md): the rule file format, conditions, tiers and attachments
- [Development](docs/development.md): building, tests, project layout, storage, debugging
