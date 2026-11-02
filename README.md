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

## Tracing

- **Record**: press the record button (⇧⌘R). Each go-to-definition (⌘-click), reference, caller or callee
  you follow becomes a step with the edge type.
- **Add manually**: ⇧⌘T adds the cursor location.
- **Ask Claude**: type a question in the Trace tab. Claude reads the repo and returns ordered steps; each step
  is matched against the parsed outline to fix line numbers, and steps that cannot be matched are flagged.
- **Play**: click steps or use ⌥⌘↓ / ⌥⌘↑. The current step's note shows above the code.
- Traces persist per repository and export as Markdown.

## Review

Open a review from the toolbar: jj revsets (working copy, stack since `trunk()`, custom), git ranges or
uncommitted changes, or a GitHub PR number (via `gh`).

Each hunk is classified into tiers:

- **Critical**: unsafe, atomics/locking/channels, new panic paths, serialization, Drop/Send/Sync, public signatures, trait definitions.
- **Behavior**: control flow and logic changes.
- **Plumbing**: values threaded through calls and struct literals, module declarations, manifest changes.
- **Tests**: test files and `#[cfg(test)]` / `#[test]` regions (from the parsed file, not just paths).
- **Mechanical**: formatting-only (token-identical), comments, imports, complete renames, lockfiles, generated files.

"Triage with Claude" re-checks every hunk against the heuristics, writes an overview and a suggested
reading order. Mechanical hunks are hidden by default. Mark hunks viewed with ⇧⌘V; ⌘J / ⌘K move between
hunks; Before/After switches sides.

## State

Per-repository data (traces, bookmarks, review progress, SCIP cache) lives in
`~/Library/Application Support/Spelunk/<repo>-<hash>/`.

## Debugging

`SPELUNK_DEBUG=1` logs to stderr and enables a command bridge: post a distributed notification named
`dev.spelunk.debug` with a command string (`open path:line`, `click line:col`, `def line:col`,
`review git:BASE:HEAD`, `trace <question>`, `triage`, `dump`, `snapshot <png>`). See `DebugBridge.swift`.
