# Spelunk

A native macOS code viewer for reading, tracing and reviewing Rust code.

## Build and run

```sh
./scripts/bundle.sh            # release build -> dist/Spelunk.app
open dist/Spelunk.app --args ~/path/to/repo
swift test                     # unit tests
SPELUNK_IT_REPO=~/some/cargo/repo swift test --filter IntegrationTests
```

Requires macOS 15+, Xcode 16+. Optional tools, found on `PATH` or in the usual places:
`rust-analyzer` (also picked up from Zed and VS Code installs), `rg`, `jj`, `git`, `gh`, `cargo`, `claude`.

## Code intelligence

Every navigation answer is labeled with the provider that produced it. Providers are tried from most to
least precise, falling back when one has no answer:

| Provider | Used for |
|---|---|
| rust-analyzer (LSP) | definition, references, hover, call hierarchy, implementations, highlights |
| SCIP (`rust-analyzer scip`, cached per repo) | the same queries offline or while rust-analyzer indexes |
| tree-sitter (Rust grammar) | highlighting, outline, enclosing items, test regions, callees, change classification |
| ripgrep | text search and name-based fallbacks |
| `cargo clippy` | diagnostics in the gutter and Problems tab |
| Claude (`claude` CLI, read-only tools) | questions, generated traces, review triage |

## Code Paths

A code path is a named, ordered list of locations with a note on each: how a request flows, how a value
is built, where a bug travels.

- **+** (⇧⌘T) adds the cursor location after the current step, titled by its enclosing item. A step
  remembers how you got there (definition, caller, reference) but navigation never adds steps on its own.
- Double-click a note to edit it; right-click a step to move it, re-point it at the cursor, or remove it.
- **⋯ › Generate with Claude** writes a path from a question. Steps are matched against parsed outlines to
  fix line numbers; unmatched ones are flagged.
- Step through with ⌥⌘↓ / ⌥⌘↑. Paths persist per repository and copy out as Markdown.

## Review

Open a review from the toolbar, the Changes tab, the Source tab or the command palette: jj revsets
(working copy, stack since `trunk()`, any change in the graph), git ranges or uncommitted changes, or a
GitHub pull request.

Each hunk is classified into tiers:

- **Critical**: unsafe, atomics/locking/channels, new panic paths, serialization, Drop/Send/Sync, public signatures, trait definitions.
- **Behavior**: control flow and logic changes.
- **Plumbing**: values threaded through calls and struct literals, module declarations, manifest changes.
- **Tests**: test files and `#[cfg(test)]` / `#[test]` regions (from the parsed file, not just paths).
- **Mechanical**: formatting-only (token-identical), comments, imports, complete renames, lockfiles, generated files.

Mechanical hunks start collapsed (click the section to expand). "Triage with Claude" re-checks every hunk,
writes an overview and a reading order. ⇧⌘V marks a hunk viewed; ⌘J / ⇧⌘J move between hunks.

Related hunks are kept together inside the importance list: every hunk that removes or adds the same
symbol (identifiers and string literals, so a config flag and its name match) becomes one collapsible
group, filed under the tier of its most important member. "Group with Claude" (Triage menu) asks a cheap
model for logical groups as well. The Change context pane lists the rest of the selected hunk's group.
J / K follow the list as shown.

### Review rules

Classification is a rule file: `.spelunk/review.rules` in the repository, then
`~/Library/Application Support/Spelunk/review.rules`, then the built-in defaults (Triage menu, "Edit
Review Rules"). Beyond path, language, hunk-shape, regex and tree-sitter conditions, rules can ask:

- code intelligence, answered by rust-analyzer or SCIP after the first pass: `refs > 20`, `callers > 5`,
  `callers in src/adapter/**`, `called-from /sequence_peek/ depth 3`, `calls /block_on/`, `signature /-> Result/`;
- a cheap model: `llm "Does this change when a lock is released?"`, batched per question and cached per hunk.

`attach` rules add a review artifact to matching files or hunks: `run <command>` (files it writes to
`{out}` show inline, so a script can render a component or plot benchmarks) or `claude "<prompt>"`.
Results are cached until the rule or the hunks change. "New Rule from Description" drafts rules from a
sentence and checks them with the parser before adding them.

### GitHub

Through `gh` (its authentication is used):

- Pull request lists (review requested, mine, all open) in Source › Pull Requests.
- PR header with state, checks (click for the list), review decision, and thread counts.
- Review threads shown on their hunks and in the gutter, with reply and resolve.
- Line comments drafted from the editor's context menu, kept locally, then posted in one review
  (Comment / Approve / Request changes) after a confirmation.
- PR commits are fetched from whichever remote points at the repository; when they are unavailable, file
  contents come from the GitHub contents API.
- "Copy GitHub Link" / "Open on GitHub" in the command palette.

## Source control

Source › Changes shows the jj graph (default log or any revset), the working copy's description and
files, and per-change actions: review, edit, new, squash into parent, set or push bookmarks, abandon,
fetch, undo. Push and abandon ask first. Every jj command gets its message explicitly; `EDITOR` is set to
`true` for spawned tools so nothing waits on an editor. Git repositories without jj get a read-only log.

## Palettes

- **⌘K** files: fuzzy path search (space-separated fragments), recent files first, `path:42` for a line,
  `@name` for symbols in the current file, `#name` for workspace symbols from rust-analyzer.
- **⇧⌘K** commands: every action in the app.

## Languages

Rust uses a bundled grammar. Other languages install from Settings › Languages: give a grammar's git
URL (or pick a preset). Spelunk clones it, reads `tree-sitter.json` for grammar names and file types,
compiles `src/parser.c` and any scanner with the system compiler into a dylib, and copies
`queries/highlights.scm` and `queries/tags.scm` (the outline). Queries can be edited in place and
reloaded. Grammars live in `~/Library/Application Support/Spelunk/grammars`; the runtime is tree-sitter
0.25 (ABI 13–15).

## Claude models

Questions, code paths and review triage each have their own model and effort (Settings, or the picker
next to each feature). The default is `opus`; classification, grouping, rule questions and attachments
default to `sonnet`. Any number of asks and traces run at once in the Claude pane (⌘L); finished answers
are kept and a repeated question at the same revision is answered from the cache. Every model result in
review (classification, triage, groups, rule answers, attachments) is cached by hunk content.

## State

Per-repository data (traces, bookmarks, review progress, SCIP cache) lives in
`~/Library/Application Support/Spelunk/<repo>-<hash>/`.

## Debugging

`SPELUNK_DEBUG=1` logs to stderr and enables a command bridge: post a distributed notification named
`dev.spelunk.debug` with a command string (`open path:line`, `click line:col`, `def line:col`,
`review git:BASE:HEAD`, `review pr:N`, `trace <question>`, `triage`, `palette files|commands`, `ptype <text>`,
`tab source`, `addstep`, `newpath`, `dump`, `snapshot <png>`). See `DebugBridge.swift`.
