# Spelunk user guide

Spelunk is a code viewer: the editor is read-only. It changes a repository only through commands
you run from it (jj operations in the History tab, checkouts, rules you add to
`.spelunk/review.rules`), by fetching pull request commits, and by creating git worktrees for head
checkouts outside the repository. It writes to GitHub only when you post a comment, reply, resolve a
thread or submit a review.

Keyboard shortcuts are collected in [keyboard.md](keyboard.md) and the review rule language in
[rules.md](rules.md).

## Repositories and windows

- Open a repository with ⌘O (File › Open Repository…) or from the welcome screen, which lists the
  ten most recently opened repositories.
- Each repository opens in its own window. Opening a repository that already has a window brings
  that window forward.
- ⌘N opens a new window with the welcome screen.
- Windows that were open when you quit come back on the next launch.
- From the command line: `open dist/Spelunk.app --args -repo ~/path/to/repo`.

If the folder is not a jj or git repository but contains repositories, the Files tab lists them so
you can open one, or browse the folder anyway.

When a repository opens, Spelunk lists its files, starts rust-analyzer if there is a `Cargo.toml` at
the root (Settings › Code Intelligence › "Start language servers automatically"), loads the cached
SCIP index if there is one, starts the working-copy review, and opens `README.md`, `src/main.rs` or
`src/lib.rs`.

## The window

- The sidebar has four tabs: Review, Files, Search and History.
- The editor in the middle shows one file, with a breadcrumb bar above it (path and enclosing item)
  and a status bar below. The chip at the right of the breadcrumb says which version of the file is
  open: Working copy (the file on disk), After (as a review has it, with its commit) in green, or
  Before in red. Its menu switches to the file's other versions. When a fixed review is active and
  the file open is the working copy's, the chip turns orange and reads "not <review>'s version".
- The context pane on the right (toggle it with the rightmost toolbar button) follows what you are
  doing. Its Panes menu switches between Context, Claude, Conversation, Code Paths, Outline,
  Bookmarks and Problems.
- The toolbar has Back and Forward, a repository menu (restart the language server, run cargo
  clippy, generate the SCIP index, reveal in Finder), the review menu, the diff mode picker while a
  reviewed file is open, and Ask and Trace buttons.

## Reading code

### Files, Search and History

Files is the repository's file tree. Type in the filter field (⌘P focuses it) and press Return to
open the first match. The filter menu at the bottom toggles "Source files only" and "Show tests".
While a code path is open, "Path files" limits the tree to files that hold its steps.

The target button next to the filter field turns on following (it is on by default): the tree
expands to whichever file the code view has open and scrolls it into view. Turn it off to keep the
tree where you left it; the palette's "Reveal Open File in Files" reveals the open file once either
way. Files added or deleted on disk appear in or leave the tree at the next refresh.

Search runs ripgrep over the working copy. The buttons next to the field toggle regular expressions
(`.*`), whole word (`W`), case sensitivity (`Aa`), Rust files only (`.rs`, on by default) and
definitions only (`Defs`, which looks for `fn`, `struct`, `enum`, `trait` and similar followed by the
query).

History has two sections:

- Changes shows the jj change graph, or for a git repository without jj, the git log. With the
  revset field empty it shows what `jj log` shows plus the last 30 ancestors of `@`, so history
  under a pushed stack stays in view; type any revset to replace it, or pick a preset such as
  `trunk()..@` from the menu. In a jj
  repository the working-copy box lets you describe `@`, commit, start a new change, or review `@`.
  Each change's context menu can review it, review from it to `@`, edit, start a new change on top,
  squash into the parent, set or push bookmarks, abandon, or copy its id. Push and abandon ask for
  confirmation first. Spelunk passes every jj command its message explicitly and sets `EDITOR` to
  `true` for the tools it starts, so nothing waits on an editor.
- Pull Requests lists the repository's open GitHub pull requests through `gh`: review requested,
  mine, or all open, with a search field that takes GitHub search syntax or `#number`. Each row's
  context menu has Review in Spelunk, Open on GitHub and Copy URL.

### Going to a file

⌘K opens the file palette: type fragments of a path separated by spaces. `path:42` opens a line,
`:42` jumps within the open file, `@name` lists symbols in the open file, and `#name` searches
workspace symbols. ⇧⌘K opens the command palette, which lists every action in the app.

### The context pane

Click a symbol to load it into the context pane: its kind, definition, signature and docs, callers
(expandable up to entry points), callees in call order, implementations, references, and mentions in
files of other languages. Test callers are hidden until you show them. Click any entry to go there.
Pin keeps the current symbol while you click elsewhere.

The footer names the provider that answered and has a Details button with the state of every
provider (see [Code intelligence](#code-intelligence)).

### Go to definition, back and forward

⌘-click a symbol, press ⇧⌘D, or use the context menu's "Go to Definition of …". When there are
several definitions the status bar says how many and the first is shown. ⌘[ and ⌘] (or the toolbar
arrows) move back and forward through the places you have been, returning to the exact line and to
the same version of the file.

The editor's context menu also has Show Callers, Show Callees, code path and bookmark commands,
"Add Review Comment…" when the review has a pull request, "Ask Claude About This…", and "Generate
Code Path for … with Claude".

### Hover cards

Rest the pointer on a symbol to see its kind, signature, docs and a link to its definition. The
card stays while the pointer is on the symbol or the card, so its link can be clicked. Keywords get
no card. Turn hover off or change the delay (0.6 s by default) in Settings › Editor › Hover.

### Outline

The Outline pane lists the items of the open file from its tree-sitter parse, with their line
counts and test items marked. Click one to go there. In the file palette, `@name` searches the same
items.

### Minimap

The minimap at the right edge of the editor shows the whole file's line shapes and the visible
area; click or drag to scroll. In a review it adds diff colors, every hunk tinted by its tier, and
the selected hunk outlined. Hover a hunk on the minimap to see what it is. The editor also marks the selected
hunk's extent with a tier-colored bar and dashed lines. Both can be turned off in Settings › Editor ›
Review aids.

### Folding

A function's body can be folded to one "⋯ N lines" line, leaving its signature and closing line
visible. By default, files that belong to the review being shown open with every function folded
that has no changes, inline removed lines, threads or comments, and the function you arrive in stays
open (in review mode; see [Reviewing and browsing](#reviewing-and-browsing)). Settings › Editor ›
Folding can apply this to every file or turn it off. A fold that hides
changed lines keeps the change's color on its placeholder.

Folded functions show a chevron (›) beside their first line's number; with the pointer over the
gutter, open functions show one too (⌄). Click a chevron to fold or unfold that function. The status
bar shows how many of the file's functions are folded, and clicking it gives Fold All Functions,
Unfold All Functions, Reset to Default Folds, and the setting for how files open.

Any jump to a line inside a fold (a hunk, a definition, a code path step, history) unfolds it.
Click a placeholder to open it. Navigate › Fold Function (⌥⌘←) and Unfold Function (⌥⌘→) act on the
function at the cursor, with ⇧ for every function in the file; in vim mode, `za`, `zo`, `zc`, `zR`
and `zM` do the same. Folds are kept per file and version while the window is open, separately for
review mode and browsing, and the split diff view shows no folds so its two sides stay aligned.

### Diff modes

While a file of the review is open, the toolbar's picker sets how it is shown:

| Mode | Shows |
|---|---|
| Plain | The file without the review's diff: change bars in the gutter only |
| Inline | The new version, with removed lines in place, numbered with their old line numbers |
| Split | The old version on the left and the new on the right, scrolled together |
| After | The new version only |
| Before | The old version only (from the command palette, "Diff: Before") |

### Whitespace

Review diffs ignore whitespace by default (`git diff -w`, `jj diff --ignore-all-space`): hunks that
only re-indent or change spacing are left out, and files with nothing else changed drop out of the
review. The toolbar button next to the diff mode picker, the palette commands "Show Whitespace
Changes" / "Ignore Whitespace Changes" and Settings › Review › Diff switch it for every open review.
A pull request whose commits cannot be fetched locally uses GitHub's diff, which always includes
whitespace.

## Code intelligence

Navigation asks the most precise provider available and falls back when it cannot answer:

1. The file's language server: rust-analyzer for `.rs`, sourcekit-lsp for `.swift`, and `lake serve`
   for `.lean`. A server counts as available while it is indexing as well as when ready. The Lean
   server starts when the first `.lean` file opens, in the nearest folder above it that holds a
   `lakefile.toml` or `lakefile.lean`, and goes through elan so the project's `lean-toolchain` picks
   the version.
2. The SCIP index, for Rust. It is generated with `rust-analyzer scip` and cached per repository.
   While rust-analyzer is still warming up, the SCIP index answers first (Settings › Code
   Intelligence › "Answer from the SCIP index while rust-analyzer warms up"). A file modified after
   the index was generated is not answered from it.
3. tree-sitter: definitions found by searching for item keywords and confirming against the parsed
   outline, callers found as call expressions grouped by enclosing function, callees from the
   function body.
4. Text search with ripgrep, for references, implementations (`impl … Name`) and callers.

When the open file is not the working copy (a review's Before or After), the status bar says where
answers come from: "answers from the working copy" in orange when the working copy's intelligence
answers at the matching place, which can differ from the code on screen, or "answers from the review
head" once the review's own rust-analyzer is running. The context pane's footer adds "about the
working copy's code" in the same case. Any fixed review with Rust files offers "Index head" in its
header to start that rust-analyzer.

Back and Forward reach locations in any open review, not only the active one; the version chip says
which review a file belongs to.

Every answer carries its source. Results from anything below a language server have a small tag:
SCIP (it may trail the working copy), tree-sitter (types are not resolved), or text search (it may
include false matches). Hover the tag for the caveat.

Click the provider status in the status bar, or Details in the context pane footer, to see each
provider's state. From there you can start, restart or stop a language server, generate or reindex
the SCIP index (generation is never automatic), reveal the index cache, and set the extra arguments
for `cargo clippy` (default `--workspace`).

`cargo clippy` runs on request (palette, repository menu or that popover). Its diagnostics show as
dots in the gutter and in the Problems pane.

rust-analyzer starts when a Rust repository opens. sourcekit-lsp starts the first time a Swift file
is opened. Each server keeps a limited number of files open (24 by default). Binary paths can be
set in Settings › Code Intelligence; otherwise Spelunk looks on `PATH`, then (for rust-analyzer) in
Zed's and VS Code's installs and Homebrew, and (for sourcekit-lsp) through `xcrun`.

## Code paths and bookmarks

A code path is a named, ordered list of locations with a note on each: how a request flows, how a
value is built, where a bug travels. Paths are kept per repository.

### Building a path

- ⇧⌘T (or the toolbar's Trace button, or "Add to Code Path" in the context menu) adds the cursor
  location after the current step, titled by its enclosing item, and opens its note for editing.
  If no path is active, one is created.
- Each step remembers how you got there: go to definition, reference, called from, calls,
  implementation, or added by hand. Navigating never adds steps on its own.
- New paths come from the Code Paths pane's menu or the palette: New Code Path, New Code Path from
  Cursor, or Generate with Claude….
- In the Code Paths pane, click a step to go to it. The current step shows its whole note and an
  "Edit note" link; right-click any step to edit its note, move it up or down, set its location to
  the cursor, or remove it. The path menu at the top of the pane also has Rename…, Duplicate and
  Delete.

### Following a path

No path is open until you pick one, from the Code Paths pane or its menu. While one is open, a
banner above the editor shows the path, which step you are on and its note. ⌥] and ⌥[ (or ⌥⌘↓ and
⌥⌘↑), or the banner's arrows, move to the next and previous step. The × in the banner or the pane,
or Code Paths › Close Code Path, closes the path and clears its marks from the editor and the file
tree. Steps are
numbered in the gutter, and a "→ step N" marker follows a call site that leads to another step.
Between steps, Spelunk looks for a call from one step's function to the next; a hop where it finds
none (a channel, a trait object, an async boundary) is marked inferred.

"Share as Markdown" in the pane, or "Copy Code Path as Markdown" in the palette, copies the path.

### When the code changes

Steps and bookmarks in the working copy remember the item they are in, their line and the lines
around it. When their file opens, and again when you visit one, Spelunk checks the file: if the
saved line has moved (code added above it, functions reordered), the step moves with it, searched
for inside its item first and then in the whole file. If the line itself changed, the step keeps its
distance into the item. If nothing matches, the step stays on its last known line and the status bar
says so. Steps in a commit (from a review) never move.

### Paths as text

Code Paths › Copy Code Path as Text copies a path in a plain format with no line numbers: the title
on the first line, then one step per line as `file:symbol:note`. In the file and symbol fields,
write `\:` for a colon and `\\` for a backslash; the note can contain anything but a newline.

```text
SUBSCRIBE from pgwire to the compute replica
src/pgwire/src/protocol.rs:StateMachine\:\:run:Reads the query message and hands it to the adapter.
src/adapter/src/coord.rs:Coordinator\:\:sequence_plan:Plans the SUBSCRIBE and installs a dataflow.
```

Code Paths › Import Code Path from Clipboard reads that format and finds each step by its symbol,
so a script or Claude Code in a terminal can write a path for Spelunk to open. Steps whose symbol is
not found in the named file are marked unverified.

### Paths from Claude

Generate with Claude… (also the Claude pane's Trace button, ⇧⌘↩) turns a question into a path,
anchored at the cursor if you leave that checked. Claude is asked to verify every step in the code,
to say which branch the path takes where the route depends on a condition, and to keep direct calls
apart from dispatch, callbacks, channels and spawned tasks. Notes of steps reached some other way
than a direct call start with how: `[dispatch]`, `[callback]`, `[channel]`, `[spawned task]`,
`[inferred]` (a connection Claude believes in but could not see), or `[boundary]` (the last verified
call before code it cannot read). Steps are matched against the parsed files to fix their line
numbers; a step that cannot be matched to a symbol is marked unverified. A finished path
does not move the editor; open it from its card in the Claude pane or from the path picker. Refine…
and Regenerate start a new run from the same question.

### Bookmarks

⇧⌘B or a double-click in the gutter toggles a bookmark on the cursor line. The Bookmarks pane lists
them with the review or revision they were made in; while it is open, ⌘0 to ⌘9 jump to the first
ten. Right-click to remove one.

## Reviewing

### Review targets

The working copy review is always open: `@` against its parent in a jj repository, or uncommitted
changes against `HEAD` in git. It refreshes as files change on disk and when history moves (a jj
operation such as `jj new`, `jj edit` or `jj describe`, or a git commit or checkout), after a short
delay (0.6 s, Settings › Review › Live review). When `@` is empty (just after `jj new` or `jj commit`), the
working-copy review shows its parent instead, and says so: the header reads "@- <id>" with a line
explaining it, and the toolbar "Working copy · @ empty, showing <id>". The parent's files are the
working copy's, so navigation stays live. As soon as `@` has changes of its own, the review shows
them. Turn this off in Settings › Review › Live review ("When @ is empty, review its parent"); the
Review tab then offers "Review the Parent Change (@-)", which opens that change by its id, so the
review stays on it when `@` moves again.

When `@` becomes a different change (`jj new`, `jj commit`, `jj edit`), the Review tab says so at the
top: "@ moved at 17:53", which change it was, and a link to review that change. The notice goes away
when you dismiss it or `@` moves back. A hunk selection that no longer exists is dropped, and while
the review has no changes the diff picker and review keys are hidden.

### Reviewing and browsing

The editor shows a review's files in one of two ways. With the diff shown (review mode) you get
removed lines inline, tier bars on hunks, unchanged functions folded, comments, and the whitespace
button. Plain shows the same files as ordinary code, with change bars in the gutter: green for added
lines, blue for lines that replace removed ones, and a red tick where lines were deleted. The
toolbar's picker (Plain, Inline, Split, After) shows and switches the choice whenever the open file is
one of the active review's.

How you arrive decides it, not which sidebar tab is showing. Selecting a hunk, moving between hunks
(J and K, or the Navigate menu), a review thread or a comment shows the diff. Opening a file from the
Files tab, search results, the palette or the History file list shows it plain while the active
review follows the working copy. Everything else (definitions, references, Back) leaves it as it was.
Moving between hunks no longer switches the sidebar to the Review tab, so History or Search stays
open while you step through a review.

A fixed review's diff appears only on its own versions of its files:
opening the working copy of a file the review touches shows that file without the review's diff or
its hunk strip, and the version chip turns orange. Pick After in the chip's menu to go back to the
review's version.

While a file changes on disk (your editor, Claude, a checkout), the open view keeps its place. The
line at the top and the caret follow the code around the edit, and in review mode a folded function
that gains a change unfolds.

Open other reviews from the review menu in the toolbar ("Compare Revisions…" and "Review a Pull
Request…"), the History tab, or the command palette:

| Target | How to open it |
|---|---|
| A jj change | History › Changes › Review This Change (diffed against its parent) |
| A jj range | Compare Revisions… with from and to revsets, "Stack since trunk()", or Review from Here to @ |
| Uncommitted git changes | Compare Revisions… › Uncommitted git changes |
| A git base to the working tree | Compare Revisions… with a base (default `origin/main`); Spelunk diffs from its merge base with `HEAD` |
| A git commit | History › Changes › Review This Change in a git repository |
| A GitHub pull request | History › Pull Requests › Review in Spelunk, or a PR number in Compare Revisions… |

Revisions written relative to `@` (such as `@-`, or "Review the Parent Change") are resolved to
change ids when the review opens, so the review stays on that change after `@` moves; git refs such
as `HEAD~1` are resolved to commits the same way. A review whose head is `@` written out by id is the
working-copy review. A range that ends at `@` ("Stack since trunk()", Review from Here to @) follows
the working copy: it reloads as files change, like the working-copy review. Every other review is
fixed at the commits it loaded.

A fixed review's header says what it was loaded at: "Fixed at 1c5b729d · loaded 17:52", and
"checked out as @" or "parent of @" when it is. Whenever history moves (and when you switch to the
review) Spelunk checks its revisions again without reloading. If the change was rewritten, or the
commits under it were, the header says so with a Reload link; if it no longer exists (abandoned or
hidden), it offers to close the review. A pull request says when commits were pushed after it
loaded. The ⟳ button reloads any fixed review. Viewed marks are kept by hunk content, so they
survive a reload. Reviews that follow `@` show "following @" instead.

Open reviews are kept per repository and come back when it reopens, showing their last result at
once while they reload. After Check out (or a `jj edit` of your own), a fixed review whose change is
now `@` says so and offers to switch to the working-copy review, which follows the same change live.

Each review you open is pinned in the review menu beside the working copy; ⌃1 to ⌃9 switch between
them. The toolbar names the active review ("Working copy · qqtqomnp", "Change qqtqomnp", "Range a → b",
"PR #123") and how many are open. Each menu row says what the review diffs, its size, and whether it
follows the working copy or is fixed at the commits it loaded, with the time it loaded.

For a pull request, Spelunk fetches the PR's head from a remote that points at the GitHub repository
(`git fetch <remote> pull/N/head`) the first time, then diffs locally from the merge base. If the
commits cannot be fetched, it uses `gh pr diff` and reads file contents from the GitHub API. When
you reopen a review, the last result is shown immediately while it refreshes.

### Linking a local change to its pull request

A local review (the working copy, a jj change or a git branch) looks for an open pull request whose
head branch is one of the reviewed revision's local jj bookmarks, or the git branch name. When it
finds one, the review header shows the pull request, and the review gets the PR's threads, checks,
the Conversation pane and the comment composer, while the diff is still computed locally. Threads
anchor to the PR's pushed head, so their line numbers may not match a local change that is ahead of
it until you push.

### Tiers and the review list

Each hunk is sorted into a tier by the [review rules](rules.md):

| Tier | Typical contents |
|---|---|
| Critical | unsafe code, atomics and locking, concurrency and channels, new panic paths, serialization, Drop/Send/Sync, public signatures, changed safety comments |
| Behavior | control flow and logic, added or removed code, changes in languages other than Rust |
| Plumbing | values threaded through calls, module declarations, manifest and dependency changes |
| Docs | Markdown and comment changes |
| Tests | test files and `#[cfg(test)]` / `#[test]` regions |
| Mechanical | formatting-only and comment-wording changes, imports, complete renames, lockfiles, generated files |

The list has two modes. Importance lists the Critical, Behavior and Plumbing tiers, then a "Low
signal" box holding Docs, Tests and Mechanical hunks, which you can mark viewed together. Files lists
files ordered by their most important hunk. The importance bar and the "x/y important reviewed"
count above the list cover the important tiers only; a review with nothing important says so instead.

The strip above the editor shows the selected hunk's tier, enclosing item, size and summary; hover
the summary to see which rule decided it and what Claude said. In the context pane, the change
context shows why the hunk got its tier, the callers of the item it changes, the remaining callers
of functions whose calls it removes, the tests that reach it, its attachments, and other hunks in
its group. Esc returns the pane to the hunk after you click a symbol.

### Groups

Related hunks are kept together inside the importance list. Each name the change declares (a
function, type, variant, field, constant or module it adds, removes or redefines) forms a group
with every hunk that mentions it, including mentions in string literals, so a config flag and its
name match. A new or deleted file declares its own name, so it is listed with the `mod` line that
declares it. Names the change only uses, such as library methods, do not form groups, and a name
mentioned nearly everywhere groups only the hunks that declare it. Groups are filed under the tier
of their most important member. Spelling variants such as `ENABLE_FOO`, `enable_foo` and
`EnableFoo` count as one. A hunk that adds or deletes a whole file is titled with the file's name.

Triage › Group with Claude asks a cheaper model (Hunk grouping, `sonnet` by default) for logical
groups too; those are listed first. "Keep Related Hunks Together" in the Triage menu turns grouping
in the list off and on. Settings › Review › Grouping sets the maximum number of groups, how much
overlap merges two groups, and how long a plain word must be to count.

### Quick pass and deep triage

After the rules run, a quick pass sends every hunk the rules did not mark `settled` to the Quick
classification model (`sonnet`, low effort by default) with the diff text only and no tools, in
batches of 120 hunks. The model may move a hunk to another tier, except that the quick pass cannot
lower a hunk the rules call Critical. Each result is cached by hunk content, so reopening a review
or refreshing the working copy only sends hunks never seen before. Turn the automatic pass off in
Settings › Review, or run it from Triage › Classify New Hunks Now.

Deep triage (Triage › Deep Triage with Claude, or "Triage Review with Claude" in the palette) runs
the Review triage model (`opus` by default) in a checkout of the change's head with read-only tools.
It re-checks every hunk, can change any tier, writes a summary for each hunk and an overview of the
change, and proposes a reading order that the list then follows. The overview appears in the change
context pane and is marked "(before latest edits)" once the diff changes.

A sparkle on a hunk means Claude classified it (one sparkle for the quick pass, several for deep
triage).

### Attachments

Rules can attach extra material to matching hunks: a command's output or files (a plot, a rendered
component), or a Claude answer with findings, examples and suggested actions. Attachments appear in
the change context pane. See [rules.md](rules.md#attachments).

### Commit-by-commit review

When a review's range has more than one commit, a commit stepper appears in the review header. Pick
"All N commits" or one commit from its menu, or step with its arrows or the palette's Next Commit in
Review and Previous Commit in Review. One commit is diffed against its first parent. Viewed marks
are kept by hunk content, so a hunk you viewed in one commit stays viewed wherever the same hunk
appears.

### PR head indexing

Code intelligence normally answers about the working copy, mapping positions from the reviewed
version to the same identifier there. For a pull request review whose after side is not the
working copy, "Index head" in the pull request header starts a second rust-analyzer in a worktree
at the head commit, so symbols in head files are answered about that code. It costs a second full
index. Settings › Code Intelligence › "Index pull request heads with their own rust-analyzer"
starts it automatically for any opened review whose after side is not the working copy and that
touches Rust files.

Head checkouts are detached git worktrees under the repository's application support folder; the
three most recently used are kept.

### Viewed state

Mark a hunk viewed with V, ⇧⌘V, Space v in vim mode, or the Viewed button on the hunk strip. Marks
are stored per review, keyed by hunk content, under a name that keeps meaning the same code: the
pull request number, the jj change id (a change reviewed against its parent keeps its marks across
rebases), or commit ids. A hunk whose content changes needs another look.

### Comments, threads and submitting a review

Comments go to a GitHub pull request, so they need a PR review or a linked PR.

1. Start a comment with C (or `c` / Space c in vim mode, where visual mode comments on the selected
   lines), or "Add Review Comment…" in the editor's context menu. A cursor on an inline removed line
   comments on the old side.
2. Write it in the composer that opens under the line. "Suggest change" inserts a GitHub suggestion
   block with the line's text. A warning appears if the line is outside the diff, since GitHub
   rejects those.
3. ⌘↩ (Add to review) keeps it as a draft. ⌥⌘↩ (Comment now) posts it immediately on its own.
4. Drafts are stored locally, stamped with the pull request and head commit they were written
   against, and listed in the pending review bar below the editor as links to their lines.
5. In the pending review bar, choose Comment, Approve or Request changes and press Submit… (⇧⌘↩).
   A confirmation shows how many comments will be posted and as whom, with an optional summary.
   "Post" sends the review and all drafts in one request.

Existing threads show under their lines in the editor and as speech bubbles in the gutter (orange
for unresolved). N and P (or `]t` and `[t` in vim mode) move between threads, unresolved first; R
resolves or unresolves the current one. The Conversation pane lists every thread with Reply and
Resolve buttons, plus checks and reviewers. Spelunk writes to GitHub only from these explicit
actions.

### Checking out a change

A pinned review's header has a Check out menu with ways to make the change's head your working copy,
each confirmed first:

| Review | Options |
|---|---|
| jj change or range | `jj new <rev>` (new change on top) or `jj edit <rev>` |
| git range, in a jj repository | `jj new <head>` |
| git range | `git switch --detach <head>` (needs a clean working tree) |
| Pull request, in a jj repository | fetch the PR head as `<remote>/pr/N`, `jj git import`, then `jj new` on it |
| Pull request | `gh pr checkout N` |

### Closing a review

⌥⌘W, the toolbar's close button, "Close …" in the review menu, or Close Review in the palette
closes the review being shown and returns to the working copy. A head rust-analyzer for that review
stops, and a file open at the review's version reopens as the working copy at the same line. The
working copy review cannot be closed. Viewed marks, drafts and Claude results stay stored, so
reopening the same review restores them.

## Claude

Claude features run the `claude` CLI (found on `PATH`, or set in Settings › Claude › Claude CLI).
Sessions load your user settings only, with hooks disabled and no MCP servers or slash commands,
since they often run in a checkout of someone else's change.

| Feature | Model setting (default) | Tools |
|---|---|---|
| Ask | Questions (`opus`) | Read, Grep, Glob |
| Generated code paths | Traces (`opus`) | Read, Grep, Glob |
| Deep triage | Review triage (`opus`) | Read, Grep, Glob |
| Quick classification | Quick classification (`sonnet`, low effort) | none |
| Grouping | Hunk grouping (`sonnet`) | none |
| `llm` rule conditions, New Rule from Description | Rule questions (`sonnet`, low effort) | none; Read, Grep, Glob for the rule writer |
| `claude` attachments | Attachments (`sonnet`) | Read, Grep, Glob |

Each feature's model and effort can be set in Settings › Claude or from the small picker next to the
feature (in the Claude pane, the Triage menu and the rule writer). Aliases (`fable`, `opus`,
`sonnet`, `haiku`) resolve to the latest model in each family; full model names also work. Efforts
are `low`, `medium`, `high`, `xhigh` and `max`.

When the review being shown is not the working copy, asks and traces run in a checkout of the
change's head and can read the change's full diff, so answers refer to that version.

### Ask

⌘L, the toolbar's Ask button, or Space a in vim mode opens the Claude pane with the question field
focused. Leave the location checkbox ticked to tell Claude where you are looking. Ask (⌘↩) answers
in prose with clickable `path:line` citations; Trace (⇧⌘↩) turns the question into a code path.

### The job list

Every ask and trace is a card in the Claude pane, newest first, with its progress (the tools it is
using), cost and time. Any number can be started; at most four Claude sessions run at once (Settings
› Claude › Runs), and the rest wait. The status bar shows how many are running and how many finished
while the pane was not showing. A card's menu has Run Again, Copy Answer and Remove; Clear finished
removes all finished cards.

### Caching

- A finished ask or trace is kept across relaunches (the last 60 by default). Asking the same
  question with the same anchor, at the same revision and review, shows the earlier answer marked
  "Cached" at no cost. Run Again asks anew.
- Review results (quick and deep tiers, `llm` answers, attachment results) are cached by hunk
  content and shared across reviews in the repository.
- Cached results not used for 90 days are removed when the repository is next opened.

## Languages

Rust uses a bundled tree-sitter grammar. Lean has a built-in highlighter and outline: declarations
(`def`, `theorem`, `structure`, `inductive`, `instance`, …) nested under their `namespace` or
`section`, with tactics and doc comments marked. Other languages get a basic highlighter until you install a
grammar in Settings › Languages: pick a preset (Swift, Python, Go, JavaScript, TypeScript + TSX, C,
C++, Java, JSON, Bash, TOML, YAML, …) or give a grammar's git URL, with an optional subdirectory
and tag or branch. Spelunk clones it, reads `tree-sitter.json` for grammar names and file types,
compiles `src/parser.c` and any scanner with the system compiler into a dylib, and copies
`queries/highlights.scm` and `queries/tags.scm` (the outline). Each new grammar is first loaded and
exercised in a separate process, and one that crashes, hangs or has an unsupported ABI is never
loaded into the app. Queries can be edited in place and reloaded. Grammars live in
`~/Library/Application Support/Spelunk/grammars`.

## Settings

### General

Buttons to edit your review rules and view the defaults, and a note on windows.

### Editor

| Setting | Default | Range |
|---|---|---|
| Font size | 13 pt | 9–24 |
| Line spacing | 1.18 | 1.0–1.8 |
| Tab width | 4 spaces | 1–8 |
| Draw the selected hunk's boundary | on | |
| Show the minimap | on | |
| Minimap width | 70 pt | 40–140 |
| Start with function bodies folded | Unchanged functions in review files | never, review files, every file |
| Vim navigation in the code view | off | |
| Show symbol details on hover | on | |
| Hover delay | 0.6 s | 0.2–2.0 |

Text settings apply when a file is next opened.

### Review

| Setting | Default | Range |
|---|---|---|
| Ignore whitespace changes | on | |
| Classify new hunks with Claude automatically | on | |
| Hunks per classification request | 120 | 20–400 |
| Keep related hunks together in the list | on | |
| Most groups per review | 80 | 10–200 |
| Merge groups sharing N% of hunks | 60% | 30–90% |
| Plain words group only when N+ characters | 14 | 8–30 |
| Refresh after files change | 0.6 s | 0.2–3.0 |
| Run attachments marked auto | on | |

### Claude

| Setting | Default | Range |
|---|---|---|
| Model and effort per feature | see [Claude](#claude) | |
| At most N Claude sessions at once | 4 | 1–12 |
| Stop a session after | 30 min | 2–120 |
| Keep the last N asks and traces | 60 | 10–500 |
| Forget cached results unused for | 90 days | 7–365 |
| Claude CLI path | empty (found on `PATH`) | |

### Code Intelligence

| Setting | Default | Range |
|---|---|---|
| Start language servers automatically | on | |
| rust-analyzer path | empty (detect) | |
| sourcekit-lsp path | empty (detect) | |
| lake path for Lean | empty (detect) | |
| Keep N files open in each server | 24 | 4–100 |
| Index pull request heads with their own rust-analyzer | off | |
| Answer from the SCIP index while rust-analyzer warms up | on | |
| Keep N parsed files in memory | 300 | 50–2000 |

### Languages

Installed grammars, with buttons to edit their queries, reveal them, remove them, reload queries,
and add a grammar.
