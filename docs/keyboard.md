# Keyboard reference

## Menu shortcuts

These work in any repository window.

| Shortcut | Command | Menu |
|---|---|---|
| ⌘N | New Window (shows the welcome screen) | File |
| ⌘O | Open Repository… | File |
| ⌘, | Settings | Spelunk |
| ⌘[ | Back | Navigate |
| ⌘] | Forward | Navigate |
| ⇧⌘D | Go to Definition (of the symbol at the cursor) | Navigate |
| ⌘K | Go to File… | Navigate |
| ⇧⌘K | Command Palette… | Navigate |
| ⌘P | Filter File Tree (switches to the Files tab and focuses its filter) | Navigate |
| ⇧⌘F | Find in Repository… (switches to the Search tab) | Navigate |
| ⇧⌘T | Add Location to Code Path | Code Paths |
| ⌥] or ⌥⌘↓ | Next Step of the active code path | Code Paths |
| ⌥[ or ⌥⌘↑ | Previous Step of the active code path | Code Paths |
| ⇧⌘B | Toggle Bookmark at the cursor line | Code Paths |
| ⌥⌘W | Close Review, Back to Working Copy | Review |
| ⌘J | Next Hunk | Review |
| ⇧⌘J | Previous Hunk | Review |
| ⇧⌘V | Mark Hunk Viewed (toggles, then moves to the next hunk) | Review |
| ⌘L | Ask… (opens the Claude pane with the question field focused) | Claude |

Other shortcuts outside the menu bar:

| Shortcut | Where | Action |
|---|---|---|
| ⌃1 … ⌃9 | Review menu in the toolbar | Show the open review at that position (the working copy is first) |
| ⌘0 … ⌘9 | Bookmarks pane, while it is showing | Open the first ten bookmarks |
| ⌘-click | Code view | Go to definition |
| Double-click | Gutter | Toggle a bookmark on that line |

## Review keys

Single-letter keys act on the review shown in the window. They apply when no text field has focus,
the palette and comment composer are closed, and, with vim mode on, the code view does not have
focus (vim bindings apply there instead; see below). In a jj or git repository the working-copy
review is always open, so these keys are always live in the code view when vim mode is off.

Letters are case-insensitive except J.

| Key | Action |
|---|---|
| J | Next hunk, in the order the review list shows |
| ⇧J | Next important hunk not yet viewed, wrapping around |
| K | Previous hunk |
| V | Toggle viewed on the selected hunk, then go to the next unviewed important hunk |
| C | Draft a review comment at the cursor (needs a pull request) |
| N | Next pull request thread (unresolved threads first) |
| P | Previous pull request thread |
| R | Resolve or unresolve the current thread |
| Esc | Return the context pane to the selected hunk after looking at a symbol |

## Editors and sheets

| Shortcut | Where | Action |
|---|---|---|
| ↑ ↓, ↩, Esc | Palette | Move, run the selected item, close |
| ⌘↩ | Inline comment composer | Add the comment to the pending review |
| ⌥⌘↩ | Inline comment composer | Post the comment now, outside a review |
| Esc | Inline comment composer | Discard the draft |
| ⇧⌘↩ | Pending review bar | Submit… (opens the confirmation) |
| ⌘↩ | Claude pane | Ask |
| ⇧⌘↩ | Claude pane | Trace (turn the question into a code path) |
| Esc | Code path note | Stop editing the note |
| ↩, Esc | New Rule from Description | Add Rule, Cancel |

## Palettes

⌘K opens the file palette. It takes space-separated fuzzy fragments and lists recent files first.

| Input | Result |
|---|---|
| `path` | Files whose path matches the fragments |
| `path:42` | That file, at line 42 |
| `:42` | Line 42 of the open file |
| `@name` | Symbols in the open file, from its outline |
| `#name` | Workspace symbols from rust-analyzer; from tree-sitter definitions when rust-analyzer is not running |

⇧⌘K opens the command palette. Commands appear only when they apply; the condition is noted where
there is one. Typing filters by title and by the subtitle shown under it.

| Command | Shortcut | Available when |
|---|---|---|
| Go to File… | ⌘K | always |
| Go to Symbol in Workspace… | | always (opens the file palette) |
| Go Back / Go Forward | ⌘[ / ⌘] | there is history in that direction |
| Go to Definition | ⇧⌘D | the cursor is in a file |
| Show Files, Show Search, Show Source Control | ⇧⌘F for Search | always |
| Show Changes | | a review is open |
| Review Working Copy, Review Stack Since trunk() | | jj repository |
| Review Uncommitted Git Changes, Review GitHub Pull Request… | | the repository has git |
| Triage Review with Claude | | a review is open |
| Next Hunk / Previous Hunk | ⌘J / ⇧⌘J | a review is open |
| Mark Hunk Viewed | ⇧⌘V | a hunk is selected |
| Diff: Inline, Diff: Split, Diff: After, Diff: Before | | a review is open (the current mode is hidden) |
| Submit GitHub Review… | | the review has a pull request |
| Close Review | | a review other than the working copy is shown |
| Add Location to Code Path | ⇧⌘T | a file is open |
| New Code Path, New Code Path from Cursor | | always / a file is open |
| Next Code Path Step / Previous Code Path Step | ⌥⌘↓ / ⌥⌘↑ | a code path is active |
| Copy Code Path as Markdown | | a code path is active |
| Open Code Path: *title* | | one entry per code path (first 20) |
| Ask Claude… | ⌘L | always |
| Turn On Vim Navigation / Turn Off Vim Navigation | | always |
| Ignore Whitespace Changes / Show Whitespace Changes | | always |
| Close Review, Back to Working Copy | ⌥⌘W | a review other than the working copy is shown |
| Next Commit in Review, Previous Commit in Review, Review All Commits Together | | the review range has more than one commit |
| New Review Rule from Description… | | always |
| Toggle Bookmark | ⇧⌘B | a file is open |
| Copy File Path | | a file is open (copies `path:line`) |
| Copy GitHub Link, Open on GitHub | | a file is open and the repository has git |
| Reveal File in Finder | | a file is open |
| Run cargo clippy | | always |
| Generate SCIP Index | | always |
| Restart *server* | | always (the language server for the open file) |
| Show Tests in File Tree / Hide Tests in File Tree | | always |
| Show Source Files Only / Show All Files in Tree | | always |
| jj: New Change, jj: Describe Working Copy…, jj: Git Fetch, jj: Undo Last Operation | | jj repository |
| Open Repository… | ⌘O | always |
| Open Recent: *name* | | up to six recent repositories |
| Edit My Review Rules, Edit Repository Review Rules, View Default Review Rules | | always |
| Settings… | ⌘, | always |
| Install Language Grammar… | | always (opens Settings) |

## Vim mode

Turn it on in Settings › Editor › Keyboard ("Vim navigation in the code view") or with the palette
command. It applies to the code view only. The status bar shows the mode (NORMAL, VISUAL, VISUAL
LINE) and any keys typed so far. Keys with ⌘ or ⌥ go to the app as usual, and letters that are not
commands do nothing.

A number before a motion repeats it (`5j`). Esc leaves visual mode, or clears a pending count or
key.

### Motions

Motions work in normal and both visual modes. Arrow keys work as motions too.

| Keys | Motion |
|---|---|
| `h` `j` `k` `l` | Left, down, up, right (`j` and `k` keep the column across short lines) |
| `w` `b` `e` | Next word start, previous word start, word end |
| `W` `B` `E` | The same for whitespace-separated words |
| `0` `^` `$` | Line start, first non-blank, line end |
| `gg` | First line; with a count, that line |
| `G` | Last line; with a count, that line |
| `H` `M` `L` | Top, middle, bottom of the visible area |
| `{` `}` | Previous, next blank line |
| `%` | Matching bracket on the line |
| `f` `F` `t` `T` + char | Find the character forward or backward on the line, onto or just before it |
| `;` `,` | Repeat the last find, same or opposite direction |
| Ctrl-d / Ctrl-u | Half a page down / up |
| Ctrl-f / Ctrl-b | A page down / up |

### Scrolling, search and selection

| Keys | Action |
|---|---|
| `zz` `zt` `zb` | Scroll so the cursor line is centered, at the top, at the bottom |
| `/` | Open the find bar |
| `n` `N` | Next, previous match of the find bar |
| `*` `#` | Next, previous occurrence of the whole word under the cursor |
| `v` | Toggle visual mode |
| `V` | Toggle visual line mode |
| `y` | Copy the selection to the clipboard and return to normal mode |

### Code intelligence and history

| Keys | Action |
|---|---|
| `gd` | Go to definition |
| `gh` | Show the hover card for the symbol under the cursor |
| `K` | Show the hover card when no review is open, otherwise previous hunk. In a jj or git repository the working-copy review is always open, so use `gh` there. |
| Ctrl-o | Back |
| Ctrl-i or Tab | Forward |

### Review bindings

| Keys | Action |
|---|---|
| `J` | Next hunk (takes a count) |
| `K` | Previous hunk (takes a count) |
| `]h` or `]c` | Next hunk (takes a count) |
| `[h` or `[c` | Previous hunk (takes a count) |
| `]u` | Next unviewed important hunk |
| `]t` `[t` | Next, previous pull request thread (takes a count) |
| `c` or `C` | Draft a review comment on the cursor line; in visual mode, on the selected lines |

### Leader keys

The leader is the space bar.

| Keys | Action |
|---|---|
| Space `v` | Toggle viewed on the selected hunk, then go to the next unviewed important hunk |
| Space `c` | Draft a review comment |
| Space `r` | Resolve or unresolve the current thread |
| Space `a` | Open the Claude pane to ask a question |
| Space `p` | Add the cursor location to the code path |

An unknown key after `g`, `z`, `]`, `[` or space beeps.
