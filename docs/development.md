# Developing Spelunk

## Building

Spelunk is a Swift package with one executable target. It needs macOS 15 and a Swift 6 toolchain
(Xcode 16 or later).

```sh
swift build                    # debug build in .build/
swift build -c release
.build/debug/Spelunk -repo ~/path/to/repo
```

A repository passed with `-repo <path>` opens in the first window. Pass it with the flag: a bare
path argument is taken by AppKit as a document to open, which suppresses the first window.

Dependencies:

- [SwiftTreeSitter](https://github.com/ChimeHQ/SwiftTreeSitter), pinned to a revision on `main`
  that uses the tree-sitter 0.25 runtime, so grammars with ABI 15 load.
- [tree-sitter-rust](https://github.com/tree-sitter/tree-sitter-rust), the bundled Rust grammar,
  pinned to an exact release through its own Swift package.

## Bundling

```sh
./scripts/bundle.sh            # release build
./scripts/bundle.sh debug      # debug build
open dist/Spelunk.app --args -repo ~/path/to/repo
```

`scripts/bundle.sh` builds with the given configuration (default `release`), copies the binary, the app icon and
any resource bundles into `dist/Spelunk.app`, writes an `Info.plist` (bundle identifier
`dev.spelunk.Spelunk`, version 0.1.0, minimum macOS 15.0), signs the bundle ad hoc, and prints the
app's path. `dist/` is ignored by git.

The app icon is `assets/AppIcon.icns`, rendered from `assets/AppIcon.svg` by `scripts/icon.sh`
(which needs `rsvg-convert`, from `brew install librsvg`). Run it after editing the SVG and commit
both files; the bundle script copies the `.icns` and does not render it.

## Tests

```sh
swift test
SPELUNK_IT_REPO=~/path/to/cargo/workspace swift test --filter IntegrationTests
```

The unit tests are in `Tests/SpelunkTests`: `CoreTests`, `RulesTests`, `GrammarTests` and
`DisplayDocTests`. `IntegrationTests` run against a real Cargo workspace named by `SPELUNK_IT_REPO`
and exercise `rust-analyzer scip` and a live rust-analyzer; they skip when the variable is unset or
rust-analyzer is not found.

## Swift 6 language mode

Both targets build with `swiftLanguageMode(.v6)`, so data-race checking is complete and errors are
fatal. The conventions that follow from it:

- UI-facing state (`Workspace`, `ReviewSession`, `LanguageServer`, `SCIPService`, `GitHubService`)
  is `@MainActor @Observable`, and `IntelHub` is `@MainActor`.
- The per-repository store is an `actor` (`Store`), as is the per-tool process budget
  (`ProcessBudget`).
- Values handed to background work are `Sendable` structs. Shared caches that must be reached from
  any thread (`ReviewRules`, `QueryCache`, `GrammarRegistry`) guard their state with a lock and are
  marked `@unchecked Sendable`; a few constant tables are `nonisolated(unsafe)`.
- Child processes go through `ProcessRunner`, which drains pipes on their own threads, writes stdin
  off the caller's thread, terminates the process when the calling task is cancelled, and limits how
  many of each tool run at once (`claude` follows Settings, `rust-analyzer` 2, `cargo` 1, anything
  else 12).

## Project layout

### `Sources/Spelunk/App`

| File | Contents |
|---|---|
| `SpelunkApp.swift` | App entry point, menu commands, `AppModel` (one workspace per window, restoring open repositories), `ReviewNav` hunk ordering, and the single-key `ReviewKeys` |
| `DebugBridge.swift` | Optional command bridge for driving the UI from outside the process (see below) |

### `Sources/Spelunk/Core`

| File | Contents |
|---|---|
| `Preferences.swift` | Every preference key and default (`Prefs`), registered at launch |
| `Store.swift` | The per-repository SQLite store |
| `Shell.swift` | Running tools with a developer `PATH` and editor variables set to `true`; `AppPaths` for per-repository support folders; a stable string hash |
| `ProcessRunner.swift` | Child process execution with cancellation, timeouts and the per-tool budget |
| `Text.swift` | Positions and ranges (zero-based lines, UTF-16 columns), line tables, `SourceLanguage` |
| `Log.swift` | Debug logging to stderr when `SPELUNK_DEBUG` is set |

### `Sources/Spelunk/Intel`

| File | Contents |
|---|---|
| `IntelHub.swift` | Navigation queries with the provider fallback chain (LSP, SCIP, tree-sitter, text search) |
| `IntelModels.swift` | `IntelSource` (provider labels and precision), reference hits, symbol details, call tree nodes |
| `LanguageServer.swift` | rust-analyzer and sourcekit-lsp specs, binary discovery, server lifecycle and LSP requests |
| `LSPClient.swift` | JSON-RPC 2.0 over a child process's stdio |
| `SCIP.swift` | A protobuf reader for SCIP indexes, the decoded index, and `SCIPService` (generate, cache, staleness) |
| `TextSearch.swift` | ripgrep search with a pure-Swift fallback |
| `Clippy.swift` | `cargo clippy --message-format=json` diagnostics |

### `Sources/Spelunk/LLM`

| File | Contents |
|---|---|
| `Claude.swift` | Per-feature model and effort settings and the `claude` CLI runner (stream-json, read-only tools, structured output) |
| `ClaudeTasks.swift` | System prompts and response schemas for each Claude feature, and turning a generated trace into steps |

### `Sources/Spelunk/Review`

| File | Contents |
|---|---|
| `ReviewSession.swift` | Review targets, diff loading, snapshots, the quick pass and deep triage, GitHub drafts and submission |
| `Diff.swift` | Unified diff parsing into files, hunks and lines; hunk content keys |
| `Classifier.swift` | Tiers, the Rust token lexer, and the per-hunk facts that rules test |
| `Rules.swift` | The rule language: forms and conditions, rule loading and precedence, three-valued evaluation, rules file template |
| `SExpr.swift` | The s-expression reader rules files are written in |
| `DefaultRules.swift` | The built-in rules |
| `SecondPass.swift` | Semantic and `llm` conditions after the first pass, and attachments (matching, running, caching, trust) |
| `Grouping.swift` | Symbol-based hunk groups, Claude groups, and the tier sections of the review list |
| `GitHub.swift` | `gh`-based pull request lists, details, threads, checks and review writes |
| `LinkedPR.swift` | Finding the open pull request for a local review's bookmark or branch |
| `CommitRange.swift` | The commits in a review range and single-commit diffs |
| `HeadCheckout.swift` | Git worktrees at a review's head for Claude sessions and commands |
| `ReviewPersistence.swift` | Review identity, loading and saving review state, legacy JSON import |

### `Sources/Spelunk/Syntax`

| File | Contents |
|---|---|
| `Syntax.swift` | tree-sitter parsing, highlighting tokens, the outline, test regions |
| `Grammars.swift` | Installing, compiling and loading third-party grammars; presets |
| `GrammarProbe.swift` | Checking a grammar in a child process before it is loaded |

### `Sources/Spelunk/Trace`

| File | Contents |
|---|---|
| `Trace.swift` | Code paths, steps and edges (`TraceStore`), and bookmarks (`BookmarkStore`) |
| `Connectors.swift` | How one step reaches the next, and step markers for the open file |
| `ItemSync.swift` | Keeping paths and bookmarks in the store's `items` table |

### `Sources/Spelunk/Workspace`

| File | Contents |
|---|---|
| `Workspace.swift` | Per-window state: files, navigation, reviews, threads, diff modes, inline blocks |
| `Navigation.swift` | Navigation reasons and generations, closing and switching reviews |
| `Files.swift` | VCS detection and file listing, the file tree, file classification, `SourceDocument` and the document cache |
| `SCM.swift` | The jj change graph or git log, working-copy status, and jj commands |
| `CommitGraph.swift` | Lane layout for the history graph |
| `ChangeContext.swift` | What the selected hunk touches: its function and callers, affected callers, reaching tests |
| `ClaudeJobs.swift` | Asks and generated traces as jobs, their persistence and caching |
| `HeadIntel.swift` | A second rust-analyzer rooted at a review head |
| `SemanticRules.swift` | Answering semantic rule conditions with the workspace's code intelligence |
| `FileWatcher.swift` | FSEvents watch on the repository, ignoring VCS metadata and build output |

### `Sources/Spelunk/Views`

| File | Contents |
|---|---|
| `MainView.swift` | Window root, welcome screen, toolbar, review menu and picker, editor column, status bar, hunk strip |
| `SidebarView.swift` | Sidebar tabs, file tree, search, fuzzy matching |
| `ChangesView.swift` | The Review tab: review header, tier list, Triage menu, commit stepper, checkout |
| `SCMView.swift` | The History tab: change graph and pull request list |
| `CodeView.swift` | The code view (`SourceTextView`), gutter, context menu, hunk boundary drawing |
| `DisplayDoc.swift` | The displayed document: real lines interleaved with inline diff lines and embedded blocks |
| `InlineBlocks.swift` | Threads, drafts and the comment composer embedded under lines |
| `Minimap.swift` | The minimap and hunk regions |
| `Hover.swift` | Hover cards |
| `InspectorView.swift` | The context pane and its panes (context, change context, code paths, outline, bookmarks, problems, conversation) |
| `AskSheet.swift` | The Claude pane and job cards |
| `AttachmentViews.swift` | Attachment cards and structured payloads |
| `ReviewGitHubViews.swift` | Pull request conversation, pending review bar and submission |
| `RuleWriter.swift` | New Rule from Description |
| `Palette.swift` | File and command palettes |
| `Vim.swift` | Vim navigation for the code view |
| `SettingsView.swift` | The Settings window |
| `ModelMenu.swift` | Model and effort pickers |
| `LanguagesSettings.swift` | Grammar management in Settings |
| `Theme.swift` | Fonts and colors |

## Storage

Per-repository data lives in `~/Library/Application Support/Spelunk/<repo-name>-<hash>/`, where the
hash is of the repository's full path.

| Path | Contents |
|---|---|
| `spelunk.sqlite` | The store (below) |
| `index.scip`, `index.meta.json` | The SCIP index and when, at which revision and with which tool it was generated |
| `review-snapshot-<hash>.json` | The last loaded diff and classification of a review, shown at once on reopen (not kept for the working copy or a single commit) |
| `review-diffs/<hash>.diff` | A review's full diff, readable by Claude sessions |
| `attachments/<key>/` | An attachment's `hunks.diff` and its command's `out/` directory |
| `checkouts/<commit>/` | Git worktrees at review heads; the three most recently used are kept |

`spelunk.sqlite` runs in WAL mode so several windows can share it. Migrations are numbered by
`PRAGMA user_version`. Tables:

| Table | Contents |
|---|---|
| `results` | Content-addressed results that do not depend on which review asked: Claude tiers per hunk (`triage.v1`), `llm` rule answers (`conditions.v1`), attachment results (`attachment.v1`). Rows record when they were last used and are pruned after the "Forget cached results" setting (90 days) when a repository opens. |
| `review_state` | Per-review user state (viewed marks, notes, overview, reading order, Claude groups), keyed by a resolved review identity: `pr:<n>`, `jj:<change id>`, or commit ids, never a relative name such as `@`. |
| `drafts` | Pending review comments, stamped with the pull request and commit they were written for |
| `jobs` | Finished Claude asks and traces |
| `items` | Code paths and bookmarks, one row each, ordered by position |

Earlier versions kept JSON files in the same folder (`review-*.json`, `claude-jobs.json`,
`traces.json`, `bookmarks.json`); each is imported once and renamed with an `.imported` suffix.

Shared data lives in `~/Library/Application Support/Spelunk/`: `review.rules` (your rules) and
`grammars/` (installed grammars). Preferences, open and recent repositories, per-feature Claude
models, and the list of repositories whose rule commands are trusted are user defaults.

## Debugging

### Logging

Set `SPELUNK_DEBUG` (any value) to log to stderr:

```sh
SPELUNK_DEBUG=1 .build/debug/Spelunk -repo ~/path/to/repo
```

### Debug bridge

The bridge lets a script drive the UI. It is off unless the app is launched with `SPELUNK_BRIDGE`
set to a token of at least eight characters. Commands are distributed notifications named
`dev.spelunk.debug.<token>` whose object is the command string, so only a sender that knows the
token can drive the app. Most commands report through the debug log, so set `SPELUNK_DEBUG` too.

```sh
TOKEN=$(uuidgen)
SPELUNK_DEBUG=1 SPELUNK_BRIDGE=$TOKEN .build/debug/Spelunk -repo ~/path/to/repo 2>/tmp/spelunk.log &
```

A sender, for example as a Swift script run with `swift post.swift "$TOKEN" dump`:

```swift
import Foundation
let token = CommandLine.arguments[1], command = CommandLine.arguments[2]
DistributedNotificationCenter.default().postNotificationName(
    Notification.Name("dev.spelunk.debug.\(token)"), object: command, userInfo: nil, deliverImmediately: true)
```

Commands that write files (`snapshot`, `snapshotv`, `snapshotwin`, `record`) accept only paths
that resolve under the temporary directory (`NSTemporaryDirectory()`), `/private/tmp` or `/tmp`,
and ignore anything else.

Some commands, with the full list in `DebugBridge.run`:

| Command | Action |
|---|---|
| `openrepo <path>`, `newwindow`, `windows` | Open a repository, open a window, log windows |
| `open <path>:<line>`, `click <line>:<col>`, `def <line>:<col>`, `back` | Navigate |
| `review jj:<from>:<to>`, `review git:<base>:<head>`, `review pr:<n>`, `review wc` | Open a review |
| `hunk next\|prev`, `selecthunk <text>`, `mode inline\|split\|after\|before`, `commit next\|prev\|all\|<n>` | Move through a review |
| `triage`, `groupclaude`, `ask <question>`, `trace <question>` | Run Claude features |
| `palette files\|commands`, `ptype <text>`, `pclose`, `tab <name>`, `pane <name>` | Drive the UI |
| `key <chars>`, `ctrlkey <char>`, `keycode <n>`, `clickat <x> <y>` | Post input events |
| `dump` | Log the workspace, review, jobs and source control state |
| `snapshot <png>`, `record <dir>`, `recordstop` | Capture the window as a PNG, or as JPEG frames about ten times a second |

### Grammar probe

Third-party grammars are native code, so each new or rebuilt grammar is checked in a child process
before the app loads it. The app runs its own executable with `--probe-grammar <dylib> <symbol>`;
`SpelunkApp.init` calls `GrammarProbe.runIfRequested()`, which in that process loads the dylib,
checks that its ABI is within the range the tree-sitter runtime supports, parses a sample full of
nesting, quotes, escapes and non-ASCII text, and exits before any window opens. The parent waits up to 10 seconds.
A grammar that crashes, hangs or fails is not loaded, and the error is shown in Settings ›
Languages. A pass is recorded in `probe.txt` in the grammar's folder, keyed by the dylib's size,
modification time and symbol. Every parse in the app, Rust included, is limited to 2 seconds.

## Architecture notes

[docs/architecture-review.md](architecture-review.md) is a review of the codebase dated 2026-11-02:
two root causes (no single navigation model; locations without a code version) and a list of
secondary findings. Some findings describe code that has since changed, for example rule precedence
(user rules now load before repository rules) and draft comments (now stamped with their pull
request and commit), so check the current code before acting on one.
