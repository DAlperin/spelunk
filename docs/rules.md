# Review rules

Spelunk sorts every hunk of a review into a tier by evaluating a list of rules. The built-in rules
cover Rust and common file types; you can add your own, override them, and attach extra review
material (a command's output, a plot, a Claude summary) to matching hunks.

## Where rules live

| File | Scope | Open it with |
|---|---|---|
| `~/Library/Application Support/Spelunk/review.rules` | Your rules, for every repository | Settings › General › Edit My Rules…, the Triage menu's Edit Review Rules…, or the palette's Edit My Review Rules |
| `<repo>/.spelunk/review.rules` | One repository, usually checked in | The palette's Edit Repository Review Rules |
| Built-in defaults | Always loaded last | Settings › General › View Default Rules, or the palette's View Default Review Rules (opens a copy in a temporary file; editing it changes nothing) |

Opening a rules file that does not exist creates it from a commented template that lists the syntax.
Files are re-read when their modification time changes. Parse errors appear above the review list as
"N rule errors"; hover for the messages, each prefixed with the file and line. A file still in the
old line-based format also shows a note there (see [Old rule files](#old-rule-files)).

## Precedence

Rules are checked in this order: your file, then the repository's file, then the defaults. The
first matching rule that sets a tier decides the hunk's tier, so your rules can override the
repository's and both can override the defaults. A hunk no rule matches is Behavior, with the reason
"code change".

`(disable "<reason>")` removes every rule whose reason is exactly that text from the files loaded
after the one it appears in. A `disable` in your file affects the repository's file and the
defaults; one in the repository's file affects the defaults. It does not affect rules in its own
file, and it does not remove `attach` rules. Match the reason as written in the rule, before
placeholders such as `{name}` are filled in.

```scheme
(disable "comment wording")
(disable "public API: {name}")
```

## File format

A rules file is a list of s-expressions. `;` starts a comment that runs to the end of the line.

```scheme
(rule <tier> "<reason>" [:settled] [:collect]
  <condition>...)

(define <name> <condition>)

(disable "<reason>")

(attach "<title>" [:auto] [:per file|hunk|change] [:model <alias>]
  <condition>...
  (run "<shell command>"))      ; or (claude "<prompt>")
```

A rule matches when all of its conditions hold. Values are written as:

| Value | Written as |
|---|---|
| Strings: reasons, titles, globs, commands, prompts, `llm` questions, tree-sitter queries | `"double quoted"`, with `\"` for a quote and `\\` for a backslash. Any other backslash is kept, so `"\."` is backslash-dot. |
| Regexes | `/like this/` on one line, with `\/` for a slash inside. Add `i` after the closing slash for case-insensitive matching. `^` and `$` match at line boundaries. |
| Names: tiers, file kinds, hunk facts, languages, tree-sitter node kinds, operators | bare words: `critical`, `added`, `comments-only`, `rust`, `await_expression`, `>=` |
| Numbers | `10` |
| Options | words starting with a colon: `:settled`, `:collect`, `:auto`, `:per hunk`, `:model sonnet`, `:depth 2` |

### Tiers

| Tier in rules | Shown as | Kind |
|---|---|---|
| `critical` | Critical | important |
| `behavior` | Behavior | important |
| `supporting` | Plumbing | important |
| `docs` | Docs & comments | low signal |
| `tests` | Tests | low signal |
| `mechanical` | Mechanical | low signal |
| `note` | | adds its reason to whatever tier wins; never sets a tier |

Important tiers are reviewed one hunk at a time and count toward review progress. Low-signal hunks
are listed together in a "Low signal" box with a Mark viewed button.

### Options

| Option | Effect |
|---|---|
| `:settled` | The hunk is kept out of Claude's quick classification pass, so the rule's tier stands unless you run deep triage. |
| `:collect` | When an earlier rule already decided the hunk's tier and this rule matches with the same tier, its reason is added. This is how several critical risk signals are listed together. |

### Reason placeholders

| Placeholder | Filled with |
|---|---|
| `{lang}` | The file's language name |
| `{name}` | The public item whose signature the hunk touches |
| `{rename}` | The rename the hunk performs, such as `rename old → new` |
| `{refs}` | The reference count from a `refs` condition |
| `{callers}` | The caller count from a `callers` condition |

## Conditions

### Combining conditions

| Condition | Holds when |
|---|---|
| `(all c...)` | Every condition holds. A rule's own condition list is an `all`. |
| `(any c...)` | At least one condition holds. |
| `(not c)` | The condition does not hold. |
| a defined name | The condition given to `define` under that name holds. |

`(define <name> <condition>)` names a condition for the rest of the file it is in. A name has to be
defined before it is used, and cannot be the name of a built-in condition.

```scheme
(define risky (any (code touches /\bunsafe\b/) (path "**/ffi/**")))

(rule critical "unsafe or FFI code outside tests"
  risky
  (not (file test)))
```

Conditions that need an answer Spelunk does not have yet (code intelligence and `llm` conditions,
below) are three-valued: true, false or not yet known. `all` is false as soon as one part is false,
`any` is true as soon as one part is true, and `not` of an unknown is unknown. Spelunk only asks
for an answer when it could still change whether the rule matches, so in
`(any (lang rust) (refs > 5))` a Rust file never waits for references.

### Paths, files and hunk shape

| Condition | Holds when |
|---|---|
| `(path "<glob>"...)` | The repository-relative path matches the whole of one of the globs. `*` matches within one path segment, `**` across segments (`**/` also matches no directory), `?` one character, `{a,b}` either alternative. |
| `(lang <name>...)` | The file's language is one of these (`rust`, `markdown`, `toml`, `swift`, …, or an installed grammar's name). |
| `(file added\|deleted\|renamed\|modified)` | The file has that status in the diff. |
| `(file generated)` | The path looks generated or vendored: `Cargo.lock`, `*.snap`, `*.pb.rs`, `*.generated.rs`, a `generated/` or `vendor/` directory, `package-lock.json`, `yarn.lock`, `pnpm-lock.yaml`. |
| `(file test)` | The path looks like a test: a `tests`, `test`, `benches`, `testdata` or `fixtures` directory, or a name ending `_test.rs`, `_tests.rs`, `.snap`, `.slt`, `.td`, or `tests.rs`. |
| `(hunk <fact>)` | The hunk has that fact (table below). |
| `(lines <op> N)` | Added plus removed lines compare to N. |
| `(comment-words <op> N)` | The number of words that differ between added and removed comments compares to N. |

`<op>` is one of `<`, `<=`, `>`, `>=`, `==`.

Hunk facts. Most rely on the Rust lexer and parse, so they only hold in Rust files.

| Fact | Holds when | Rust only |
|---|---|---|
| `formatting-only` | Added and removed code tokens are identical and comment words are unchanged | yes |
| `comments-only` | Code tokens are identical but comment words changed | yes |
| `comment-edit` | The hunk both adds and removes comments | yes |
| `imports-only` | Every changed line is a `use` line or its continuation | yes |
| `mod-decls-only` | Every changed line is a `mod` declaration | yes |
| `in-test` | Every changed line sits in a `#[cfg(test)]` module or `#[test]` function | yes |
| `rename` | The hunk consistently renames local identifiers, and the rename is complete in the file | yes |
| `public-signature` | A changed line is in the header of a public item (other than an `impl` or module), or inside a trait | yes |
| `plumbing` | The net change is only identifiers and punctuation such as `,` `.` `clone` `into` `&`, with no control flow, in at most 12 lines a side | yes |
| `structural` | The hunk adds or removes control flow or operators (`if`, `match`, `return`, `=>`, `==`, `&&`, `let`, …) | yes |
| `additions-only` | The hunk only adds lines | no |
| `deletions-only` | The hunk only removes lines | no |

### Text and syntax

| Condition | Holds when |
|---|---|
| `(code touches /regex/)` | The regex matches changed code with comments removed and string contents blanked, so prose cannot trigger it. Tokens are joined without spaces except between adjacent words, so `/\.unwrap\(\)/` matches `x.unwrap()`. |
| `(code adds /regex/)` | The regex matches more often in added code than in removed code. |
| `(code removes /regex/)` | The regex matches more often in removed code than in added code. |
| `(comment touches /regex/)` | The regex matches the changed comment text. |
| `(text touches /regex/)` | The regex matches the raw changed lines. |
| `(ts touches <kind>...)` | A tree-sitter node of one of these kinds overlaps the changed lines, on either side. |
| `(ts query "<query>")` | A capture of the tree-sitter query overlaps the changed lines, on either side. |


### Code intelligence conditions

These ask about the item the hunk changes (its enclosing function or type), using rust-analyzer when
it is ready, otherwise the SCIP index, tree-sitter and text search, in the same order as navigation.
They are evaluated in a second pass after the review loads, and only where the answer could still
decide the rule, so pairing them with a cheap condition such as `path` or `hunk` limits how many
hunks are looked up. They apply to Rust files only. When no provider can resolve the item, the rule does not match, whether or not the condition
is negated.

| Condition | Holds when |
|---|---|
| `(refs <op> N)` | The number of references to the item compares to N. |
| `(callers <op> N)` | The number of direct callers compares to N. |
| `(callers in "<glob>")` | A direct caller is in a file matching the glob. |
| `(called-from /regex/ [:depth N])` | A caller up to N levels away (default 3, at most 6) has a name matching the regex. |
| `(calls /regex/)` | The changed function calls something whose name matches. |
| `(signature /regex/)` | The item's signature, from hover, matches. |
| `(llm "<yes/no question>")` | A model answers yes for this hunk. |

`llm` questions go to the model set for rule questions (default `sonnet`, low effort; change it in
Settings › Claude or the Triage menu). Each question is sent in batches covering the hunks that need
it, with the diff only and no tools. Answers are cached by hunk content, so a hunk is not asked the
same question twice.

## Examples

From the defaults:

```scheme
(rule mechanical "lockfile" :settled
  (path "**/{Cargo.lock,package-lock.json,yarn.lock,pnpm-lock.yaml,go.sum,poetry.lock,Gemfile.lock}"))

(rule critical "safety / invariant comment changed"
  (hunk comments-only)
  (comment touches /SAFETY|INVARIANT|#\s*(Safety|Panics)|\bunsafe\b|\bmust (not|never|always|only)\b/))

(rule critical "adds panic path" :collect
  (code adds /\.unwrap\(\)|\.expect\(|panic!|unreachable!|todo!|unimplemented!/))

(rule critical "used in {callers} places" :collect
  (hunk public-signature)
  (lang rust)
  (callers > 10))

(rule note "panic replaced with error"
  (code removes /\.unwrap\(\)|\.expect\(|panic!|unreachable!/)
  (code adds /\?/))
```

Your own, following the template's examples:

```scheme
(rule critical "design doc" :collect
  (path "doc/developer/design/**"))

(define takes-lock (code touches /\.lock\(\)/))

(rule critical "lock held across await"
  (ts query "(await_expression) @a")
  takes-lock)

(rule critical "widely used: {refs} references" :collect
  (hunk public-signature)
  (any (refs > 25) (callers in "src/adapter/**")))

(rule critical "reachable from the peek path"
  (lang rust)
  (called-from /sequence_peek|handle_command/ :depth 3))

(rule critical "lock release changes"
  (any takes-lock (code touches /drop\(/))
  (llm "Does this change when a lock is released?"))
```

## Attachments

An `attach` rule adds a review artifact to matching hunks instead of setting a tier. Attachments
appear in the change context pane for the selected hunk, and hunks that have one show a paperclip in
the list.

```scheme
(attach "<title>" [:auto] [:per file|hunk|change] [:model <alias>]
  <condition>...
  (run "<shell command>"))      ; or (claude "<prompt>")
```

An attachment needs one `(run ...)` or `(claude ...)`. Its conditions are the same as a rule's, including
code intelligence and `llm` conditions.

| Part | Meaning |
|---|---|
| `:per file` | One attachment per matching file (the default). |
| `:per hunk` | One per matching hunk, labeled with the hunk's enclosing item. |
| `:per change` | One for all matching hunks together. |
| `:auto` | Runs without a click when Settings › Review › "Run attachments marked auto" is on. Otherwise the card has a Run (or Generate) button. |
| `:model <alias>` | The model for a `claude` attachment; defaults to the Attachments model in Settings › Claude (`sonnet`). |

### `run` commands

The command runs with `/bin/sh -c` in a checkout of the change's head: the working copy when the
review's after side is the working copy, otherwise a detached git worktree at the head commit. It
has 15 minutes to finish.

| Placeholder | Value (shell-quoted) |
|---|---|
| `{file}` | The first matched path |
| `{files}` | All matched paths |
| `{out}` | An empty output directory |
| `{name}` | The first hunk's enclosing item |
| `{head}` | The head checkout directory |

The same values are in the environment as `SPELUNK_FILE`, `SPELUNK_FILES` (newline-separated),
`SPELUNK_OUT`, `SPELUNK_NAME` and `SPELUNK_HEAD_DIR`, along with `SPELUNK_DIFF` (a file holding the
matched hunks), `SPELUNK_BASE` and `SPELUNK_HEAD` (the revisions).

Files the command writes to `{out}` are shown on the card: images and PDFs inline (double-click to
open), Markdown, text, CSV, log and JSON files inline, and anything else as a link that opens it. Standard output is shown as text, unless it is structured
output (below).

```scheme
(attach "Benchmark plot" :per file
  (path "**/benches/**")
  (run "scripts/bench-boxplot.sh {file} {out}"))

(attach "Component render" :per file
  (path "**/*.tsx")
  (run "npx tsx scripts/render-component.ts {file} {out}/render.png"))
```

### `claude` prompts

The prompt runs as a read-only Claude session (Read, Grep and Glob) in the head checkout. Spelunk
adds the change title, the list of changed files, the matched hunks and the path of a file holding
the full diff. `{name}` and `{file}` in the prompt are replaced as for commands.

```scheme
(attach "Usage examples" :per hunk
  (path "**/graphql/**")
  (llm "Does this hunk add a new GraphQL resolver?")
  (claude "Show a basic query for each new resolver and two edge cases, with the expected response shape."))
```

### Structured output

A `claude` attachment always answers in this JSON shape. A `run` command can too: if it exits 0 and
its standard output is a JSON object of this shape, the card renders it instead of plain text.

```json
{
  "summary": "Two or three sentences of Markdown.",
  "findings": [
    { "title": "Unbounded retry", "detail": "…", "path": "src/client.rs", "line": 120, "severity": "risk" }
  ],
  "examples": [
    { "title": "Basic query", "language": "graphql", "code": "{ user(id: 1) { name } }" }
  ],
  "actions": [
    { "kind": "comment", "label": "Ask about the retry limit", "text": "Is there an upper bound on retries here?" },
    { "kind": "ask", "label": "Where is this retried?", "text": "Where else is send_request retried?" },
    { "kind": "trace", "label": "Trace the retry path", "text": "How does a failed request get retried?" },
    { "kind": "open", "label": "Open the caller", "path": "src/api.rs", "line": 42 }
  ]
}
```

| Field | Required parts | Rendered as |
|---|---|---|
| `summary` | | Markdown text |
| `findings` | `title`; optional `detail`, `path`, `line`, `severity` (`info`, `warn` or `risk`) | Rows that open their location |
| `examples` | `title`, `code`; optional `language` | Code blocks with a Copy button |
| `actions` | `kind`, `label`; optional `text`, `path`, `line` | Buttons: `comment` opens the comment composer on the hunk with the text filled in (nothing is posted), `ask` asks Claude, `trace` generates a code path, `open` opens `path:line` |

### Caching

An attachment's result is keyed by the text of its `(attach ...)` form and the content of the hunks it matched. It is
reused, across reopens and between reviews, until either changes. Use Regenerate in the card's menu
to run it again. Failed runs are not cached.

## Trusting repository commands

A `run` command in `.spelunk/review.rules` comes with the code under review, so whoever wrote that
code controls it. Spelunk does not run one, even when marked `:auto`, until you trust the repository:
the card shows "Run Repository Command…", and clicking it shows the command and offers "Trust This
Repository's Rule Commands". Trust is recorded per repository path (in the `rules.trustedRepos`
user default) and covers every command in that file from then on, including later edits.

Commands in your own rules file, and `claude` attachments from either file, do not need trust.

## Writing rules from a description

"New Rule from Description…" (Triage menu or palette) asks the rule-questions model to draft rules
from a sentence. It can read the repository and is given this syntax and the defaults. The draft is
checked with the real parser before you can add it to your rules or to the repository's file, and
the review re-classifies once it is added.

## Old rule files

Rules used to be written one condition per line:

```text
rule critical "design doc" collect
  path ~ doc/developer/design/**
  not hunk in-test
```

A file in that format still loads: it is converted as it is read, and "N rule errors" includes a
note saying so. The palette's Convert Rules Files (or Settings › General › Convert Old Rules Files)
rewrites it. Your file keeps the old text beside it as `review.rules.old`; a repository's file is
rewritten in place, since version control has the old text. Comments are kept, and a line that
cannot be converted becomes a comment and is reported.
