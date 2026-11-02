/// Built-in review rules, evaluated after repository and user rules. Syntax is documented on
/// `ReviewRule`; Settings › Review shows this file and creates a user rules file to extend it.
enum DefaultRules {
    static let text = #"""
# Spelunk default review rules.
#
# Order matters: the first matching rule sets the tier. Matching `collect` rules of that tier add
# their reasons too (so several risk signals are listed together). `note` rules only add reasons. `settled` keeps a hunk away from the Claude
# classification pass. Override in .spelunk/review.rules (per repository) or in your user rules;
# turn a rule below off with:  disable "<reason>"

# --- Files ----------------------------------------------------------------------------------------

rule mechanical "lockfile" settled
  path ~ **/{Cargo.lock,package-lock.json,yarn.lock,pnpm-lock.yaml,go.sum,poetry.lock,Gemfile.lock}

rule mechanical "generated or snapshot" settled
  file generated

rule docs "new document"
  lang markdown
  file added

rule docs "documentation"
  lang markdown

rule tests "test file"
  file test

rule supporting "dependency or feature change"
  path ~ **/Cargo.toml
  text touches /features|\[(dev-|build-)?dependencies|^\s*[\w-]+\s*=\s*(\{|")/

rule supporting "manifest change"
  path ~ **/Cargo.toml

rule behavior "{lang} change"
  not lang rust

# --- Rust: structure ------------------------------------------------------------------------------

rule tests "inside #[cfg(test)] / #[test]"
  hunk in-test

rule mechanical "formatting only" settled
  hunk formatting-only

rule critical "safety / invariant comment changed"
  hunk comments-only
  comment touches /SAFETY|INVARIANT|#\s*(Safety|Panics)|\bunsafe\b|\bmust (not|never|always|only)\b/

rule mechanical "comment wording"
  hunk comments-only
  hunk comment-edit
  comment-words <= 3

rule docs "doc comments"
  hunk comments-only
  comment touches /^\/\/[\/!]|^\/\*\*/

rule docs "comments"
  hunk comments-only

rule mechanical "imports"
  hunk imports-only

rule supporting "module declarations"
  hunk mod-decls-only

# --- Rust: risk signals (every matching critical reason is listed) ---------------------------------

rule critical "unsafe code" collect
  code touches /\bunsafe\b/

rule critical "atomics / memory ordering" collect
  code touches /Ordering::|Atomic\w+|\bfence\(/

rule critical "locking" collect
  code touches /\bMutex\b|\bRwLock\b|\.lock\(\)|Condvar|\bSemaphore\b/

rule critical "concurrency / channels" collect
  code touches /\bspawn\w*\(|\bselect!|\bjoin!|mpsc::|oneshot::|broadcast::|watch::/

rule critical "adds panic path" collect
  code adds /\.unwrap\(\)|\.expect\(|panic!|unreachable!|todo!|unimplemented!/

rule critical "serialization format" collect
  code touches /#\[serde|Serialize|Deserialize|\bproto\b|prost::|#\[derive\([^)]*(Serialize|Arbitrary)/

rule critical "Drop / Send / Sync" collect
  code touches /impl\s*Drop\b|unsafe\s*impl\s*(Send|Sync)/

rule critical "public API: {name}" collect
  hunk public-signature

# --- Rust: low-risk shapes ------------------------------------------------------------------------

rule mechanical "{rename}"
  hunk rename

rule supporting "threads values through"
  hunk plumbing

# --- Notes added to whatever tier wins -------------------------------------------------------------

rule note "also edits comments"
  comment-words > 3
  not hunk comments-only

rule note "error propagation removed"
  code removes /\?/

rule note "panic replaced with error"
  code removes /\.unwrap\(\)|\.expect\(|panic!|unreachable!/
  code adds /\?/

# --- Rust: everything else is a behavior change ---------------------------------------------------

rule behavior "new logic"
  hunk structural
  hunk additions-only

rule behavior "control flow / logic"
  hunk structural

rule behavior "added code"
  hunk additions-only

rule behavior "removed code"
  hunk deletions-only

rule behavior "code change"
  lang rust
"""#
}
