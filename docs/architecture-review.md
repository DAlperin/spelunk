# Spelunk architecture review (2026-11-02)

Three independent reads of the codebase (state and UI; the review pipeline; code intelligence, LLM
integration and infrastructure) agreed on two root causes and found a set of secondary ones. Most
bugs fixed one at a time during development were symptoms of these.

## Root causes

### 1. No navigation model

"Where am I and why" is spread over about eighteen fields on `Workspace` (`document`, `selection`,
`cursor`, `selectedHunkID`, `contextFocus`, `contextPinned`, `inspectorPane`, `traces.currentStep`,
`activeReviewKey`, `changeContext`, `splitDocument`, `currentThreadID`, ...), written from roughly
ten entry points (`open`, `show`, `selectHunk`, `showThread`, `jump`, `playStep`, `didClick`,
`startReview`, the review menu, background completions) and directly from views. Each entry point
resets a different subset. Facts that should be derived are stored: the current step is an index
instead of "the step at the editor's location", the inspector subject is a flag instead of the last
navigation's reason. Async completions (`selectHunk`'s document load, `goToDefinition`, finished
Claude jobs, PR loads) write navigation state with no generation check, so a stale result can move
the editor or switch the pane after the user has moved on.

Symptoms: empty context pane until toggling, no way back to the hunk, a step left marked current,
panes switching unexpectedly, a generated path taking over the editor, J/K disagreeing with the list.

### 2. Locations do not carry a code version

`CodeLocation` is path plus range. Which text the range belongs to (working copy, review base, review
head, the SCIP index's revision) is inferred from `SourceDocument.revisionLabel` strings and from the
fact that `DocumentCache` reads the working copy. rust-analyzer answers about the working copy are
opened in head documents; go-to-definition on a Before view queries working-copy positions; SCIP is
used without checking that the file still matches the index; traces, bookmarks and drafts store no
version; the GitHub comment side is a string comparison.

Symptoms: asks and attachments reading the base, files from a PR opening as the working copy, trace
steps verified against the wrong text.

## Secondary findings

- **Hunk identity is positional.** `Hunk.id` is `path#index`, so anything keyed by it across an
  await (deep triage, the semantic pass, selection, attachments) can land on a different hunk after a
  reload. `contentKey` collides for identical hunks in one file.
- **Loading is not a transaction.** `ReviewSession.load()` mutates revisions, title and document
  caches before classification commits; the second pass's reentrancy guard drops new work instead of
  restarting it.
- **Persistence is keyed by relative targets.** `@-`→`@` state accumulates across every change ever
  at `@`; pending review comments carry no PR number or commit, so drafts can be submitted to a
  different PR; a decode failure silently overwrites saved state.
- **Head checkout races.** Concurrent callers race `git worktree add`; failures fall back to the
  working copy silently.
- **Processes.** `Shell.run` ignores cancellation and has no timeout; stdin is written synchronously
  on the caller's thread; stdout can be truncated by a drain race; nothing limits how many `claude`,
  `rg` or `git` processes run at once.
- **LSP lifecycle.** A late exit callback from a restarted rust-analyzer can drop the new client;
  documents are opened and never closed or resynced; cancellation is indistinguishable from failure,
  so cancelled lookups fall through to ripgrep.
- **Rules engine.** An unavailable semantic answer makes `not` conditions true; `disable` only affects
  defaults; repo rules cannot be overridden by user rules; the line lexer can mark a hunk
  `comments-only` (and settled) when it starts inside a string or block comment.
- **Tier precedence.** A low-effort quick pass overrides any unsettled rule tier, including critical
  risk signals and tiers raised by the semantic pass.
- **Performance.** `CodeView.updateNSView` rebuilds phantom lines, the display document and hunk
  regions on any observed change; `DocumentCache` reads and parses on the main thread from view
  bodies; several review queries are quadratic.
- **Concurrency checking is off.** Both targets build in Swift 5 language mode, so `@unchecked
  Sendable` and `assumeIsolated` claims are unchecked.
- **Security** (fixed first): the debug bridge accepted commands from any local process; Claude
  sessions in a PR-head worktree loaded that tree's project settings and hooks; repository rule
  files could run shell commands automatically; `git clone` took an unseparated URL.

## Plan

Each phase lands, builds and tests on its own.

1. **Security.** Token-gated debug bridge confined to temp paths; Claude runs with user settings only
   and all hooks disabled; repository rule commands need trust; `--` for clone; SIGPIPE ignored.
2. **Identity and processes.** Content-based hunk ids with an occurrence index; cancellable `Shell`
   and `Claude` runs with timeouts, off-thread stdin and a complete stdout drain; a process budget;
   the semantic provider receives the asking session; load generations, with superseded passes
   cancelled and restarted.
3. **Navigation.** A `Navigator` with one `go(to:because:)` entry point and a generation token; the
   current step stored by id and derived from the editor location; the inspector subject derived from
   the navigation reason; pane changes only on user actions; one `activate(review:)` that clears
   per-review selection; J/K and the list share one `ReviewListing`.
4. **Versions.** `CodeVersion` on documents and locations; providers declare which versions they
   answer for; locations from another version are mapped through the diff or reported unavailable;
   traces, bookmarks and drafts store their version; drafts carry PR number and commit.
5. **Intelligence lifecycle.** Generation tokens for rust-analyzer, SCIP and clippy runs; typed
   provider answers (found, empty, unavailable, cancelled); SCIP staleness by file hash; didClose and
   watched-file notifications.
6. **Rules and caches.** Tri-state semantics preserved through `not`; rule precedence and `disable`
   as documented; cache keys include model, prompt version and rules hash; tier provenance with rule
   authority over the quick pass.
7. **Performance and concurrency.** Memoized editor display pipeline; off-main document store with
   LRU; index maps per review load; Swift 6 language mode module by module.
