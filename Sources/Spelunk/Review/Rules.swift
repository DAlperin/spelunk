import Foundation
import SwiftTreeSitter

/// A small rule language for classifying diff hunks.
///
/// ```
/// # comment
/// rule <tier> "<reason>" [settled] [collect]
///   <condition>
///   not <condition>
/// disable "<reason>"
/// ```
///
/// Tiers: critical, behavior, supporting, docs, tests, mechanical, plus `note`, which only adds a
/// reason. Rules are checked in order (your file, then the repository's, then defaults); the first
/// matching non-note rule sets the tier. A `collect` rule that also matches adds its reason when its
/// tier won, which is how several risk signals are listed together. `settled` keeps a hunk out of
/// the Claude classification pass. `disable` removes earlier-loaded or
/// default rules with that reason. Reasons may use `{lang}`, `{name}` (public item) and `{rename}`.
///
/// Conditions, all of which must hold:
/// - `path ~ <glob>`                                  (`*`, `**`, `?`, `{a,b}`)
/// - `lang <name>[,<name>…]`                          (rust, markdown, toml, or an installed grammar)
/// - `file added|deleted|renamed|modified|generated|test`
/// - `hunk <fact>`: formatting-only, comments-only, comment-edit, imports-only, mod-decls-only,
///   in-test, rename, public-signature, plumbing, structural, additions-only, deletions-only
/// - `code touches|adds|removes /regex/`              (code with comments and string contents removed)
/// - `comment touches /regex/`                        (changed comment text)
/// - `text touches /regex/`                           (raw changed lines)
/// - `comment-words <op> N`, `lines <op> N`           (op: < <= > >= ==)
/// - `ts touches <node-kind>[,<node-kind>…]`          (a syntax node of that kind overlaps the change)
/// - `ts query <tree-sitter query>`                   (a query match overlaps the change)
///
/// Semantic conditions ask rust-analyzer (or the SCIP index, then text search) about the item the
/// hunk changes. They are checked after the first pass, only for hunks whose other conditions hold:
/// - `refs <op> N`                                    (references to the changed item)
/// - `callers <op> N`, `callers in <glob>`            (direct call sites, and where they are)
/// - `called-from /regex/ [depth N]`                  (a transitive caller's name matches; depth 3)
/// - `calls /regex/`                                  (the changed function calls a matching name)
/// - `signature /regex/`                              (the item's signature from hover)
/// - `llm "<yes/no question>"`                        (asked of a cheap model, batched, cached per hunk)
///
/// Reasons may also use `{refs}` and `{callers}`.
///
/// Attachments add a review artifact to matching changes instead of setting a tier:
/// ```
/// attach "<title>" [auto] [per file|hunk|change]
///   <conditions>
///   run <shell command>          ({file} {files} {out} {name}; output files written to {out} are shown)
///   claude "<prompt>"            (read-only Claude session; the answer is shown as Markdown)
///   model <alias>
/// ```
struct ReviewRule: Sendable {
    enum Tier: Sendable, Equatable {
        case tier(ChangeTier)
        case note
    }

    enum Condition: Sendable {
        case path(NSRegularExpression)
        case lang(Set<String>)
        case file(String)
        case hunk(String)
        case code(String, NSRegularExpression)
        case comment(NSRegularExpression)
        case text(NSRegularExpression)
        case commentWords(String, Int)
        case lines(String, Int)
        case tsQuery(String)
        case semantic(Semantic)
        case llm(String)
    }

    enum Semantic: Sendable {
        case refs(String, Int)
        case callers(String, Int)
        case callersIn(NSRegularExpression)
        case calledFrom(NSRegularExpression, Int)
        case calls(NSRegularExpression)
        case signature(NSRegularExpression)

        var needs: SemanticNeeds {
            switch self {
            case .refs: SemanticNeeds(refs: true)
            case .callers, .callersIn: SemanticNeeds(callers: true)
            case .calledFrom(_, let d): SemanticNeeds(callers: true, depth: d)
            case .calls: SemanticNeeds(callees: true)
            case .signature: SemanticNeeds(signature: true)
            }
        }
    }

    var tier: Tier
    var reason: String
    var settled: Bool
    var collect: Bool
    var conditions: [(negated: Bool, condition: Condition)]
    var source: String
    var line: Int

    var location: String { "\(source):\(line)" }
}

extension NSRegularExpression: @retroactive @unchecked Sendable {}

/// Which semantic answers a hunk's pending rules need.
struct SemanticNeeds: Sendable, Hashable, Codable {
    var refs = false
    var callers = false
    var callees = false
    var signature = false
    var depth = 0

    var isEmpty: Bool { !refs && !callers && !callees && !signature }
    func union(_ o: SemanticNeeds) -> SemanticNeeds {
        SemanticNeeds(refs: refs || o.refs, callers: callers || o.callers, callees: callees || o.callees,
                      signature: signature || o.signature, depth: max(depth, o.depth))
    }
    func covers(_ o: SemanticNeeds) -> Bool { union(o) == self }
}

/// Code-intelligence answers about the item a hunk changes.
struct SemanticFacts: Sendable {
    struct Caller: Sendable, Hashable { var name: String; var path: String }
    /// False when no provider could resolve the item; semantic conditions then do not hold.
    var available = true
    var item: String?
    var refs: Int?
    var callers: [Caller] = []
    /// Names of callers up to the requested depth, nearest first.
    var transitiveCallers: [String] = []
    var callees: [String] = []
    var signature: String?
    var source: IntelSource?

    static let unavailable = SemanticFacts(available: false)
}

/// Conditions a hunk's rules could not decide in the first pass.
struct RulePending: Sendable, Hashable, Codable {
    var needs = SemanticNeeds()
    var questions: Set<String> = []
    var isEmpty: Bool { needs.isEmpty && questions.isEmpty }
    mutating func formUnion(_ o: RulePending) { needs = needs.union(o.needs); questions.formUnion(o.questions) }
}

struct AttachRule: Sendable, Identifiable {
    enum Action: Sendable { case run(String), claude(String) }
    enum Scope: String, Sendable { case file, hunk, change }
    var title: String
    var auto: Bool
    var scope: Scope
    var conditions: [(negated: Bool, condition: ReviewRule.Condition)]
    var action: Action?
    var model: String?
    var source: String
    var line: Int
    /// The rule as written, so a cached result is reused only while the rule is unchanged.
    var text: String
    var id: String { "\(source):\(line):\(title)" }
}

struct RuleSet: Sendable {
    var rules: [ReviewRule] = []
    var attachments: [AttachRule] = []
    var errors: [String] = []
}

enum RuleParser {
    static let facts: Set<String> = [
        "formatting-only", "comments-only", "comment-edit", "imports-only", "mod-decls-only", "in-test", "rename",
        "public-signature", "plumbing", "structural", "additions-only", "deletions-only",
    ]
    static let fileKinds: Set<String> = ["added", "deleted", "renamed", "modified", "generated", "test"]

    /// Parses one rules file. `disabled` collects reasons from `disable` lines.
    static func parse(_ text: String, source: String) -> (rules: [ReviewRule], disabled: Set<String>, errors: [String]) {
        let r = parseAll(text, source: source)
        return (r.rules, r.disabled, r.errors)
    }

    static func parseAll(_ text: String, source: String) -> (rules: [ReviewRule], attachments: [AttachRule], disabled: Set<String>, errors: [String]) {
        var rules: [ReviewRule] = []
        var attachments: [AttachRule] = []
        var disabled: Set<String> = []
        var errors: [String] = []
        var current: ReviewRule?
        var attach: AttachRule?

        func flush() {
            if let c = current { rules.append(c) }
            current = nil
            if let a = attach {
                if a.action == nil { errors.append("\(source):\(a.line): attach needs `run <command>` or `claude \"<prompt>\"`") }
                else { attachments.append(a) }
            }
            attach = nil
        }

        for (i, rawLine) in text.components(separatedBy: "\n").enumerated() {
            let n = i + 1
            let line = stripComment(rawLine)
            let trimmed = line.trimmingCharacters(in: .whitespaces)
            if trimmed.isEmpty { continue }
            let indented = line.first == " " || line.first == "\t"

            if !indented {
                flush()
                if trimmed.hasPrefix("disable ") {
                    if let r = quoted(String(trimmed.dropFirst(8))) { disabled.insert(r) } else {
                        errors.append("\(source):\(n): disable needs a quoted reason")
                    }
                    continue
                }
                if trimmed.hasPrefix("attach ") {
                    let rest = String(trimmed.dropFirst(7)).trimmingCharacters(in: .whitespaces)
                    guard let title = quoted(rest) else {
                        errors.append("\(source):\(n): attach needs a quoted title")
                        continue
                    }
                    let flags = rest.dropFirst(title.count + 2).split(separator: " ").map(String.init)
                    var scope = AttachRule.Scope.file
                    var i = 0
                    while i < flags.count {
                        if flags[i] == "per", i + 1 < flags.count, let s = AttachRule.Scope(rawValue: flags[i + 1]) { scope = s; i += 2; continue }
                        if flags[i] != "auto" { errors.append("\(source):\(n): unexpected `\(flags[i])`") }
                        i += 1
                    }
                    attach = AttachRule(title: title, auto: flags.contains("auto"), scope: scope, conditions: [], action: nil, model: nil,
                                        source: source, line: n, text: trimmed)
                    continue
                }
                guard trimmed.hasPrefix("rule ") else {
                    errors.append("\(source):\(n): expected `rule`, `attach`, `disable` or an indented condition")
                    continue
                }
                let rest = trimmed.dropFirst(5).trimmingCharacters(in: .whitespaces)
                let tierName = rest.prefix { !$0.isWhitespace }
                let afterTier = rest.dropFirst(tierName.count).trimmingCharacters(in: .whitespaces)
                let tier: ReviewRule.Tier
                if tierName == "note" { tier = .note } else if let t = ChangeTier(rawValue: String(tierName)) { tier = .tier(t) } else {
                    errors.append("\(source):\(n): unknown tier `\(tierName)`")
                    continue
                }
                guard let reason = quoted(afterTier) else {
                    errors.append("\(source):\(n): rule needs a quoted reason")
                    continue
                }
                let flags = afterTier.dropFirst(reason.count + 2).split(separator: " ").map(String.init)
                current = ReviewRule(tier: tier, reason: reason, settled: flags.contains("settled"), collect: flags.contains("collect"),
                                     conditions: [], source: source, line: n)
                if let bad = flags.first(where: { $0 != "settled" && $0 != "collect" }) { errors.append("\(source):\(n): unexpected `\(bad)`") }
                continue
            }

            if attach != nil {
                attach!.text += "\n" + trimmed
                if trimmed.hasPrefix("run ") { attach!.action = .run(String(trimmed.dropFirst(4)).trimmingCharacters(in: .whitespaces)); continue }
                if trimmed.hasPrefix("claude ") {
                    let arg = String(trimmed.dropFirst(7)).trimmingCharacters(in: .whitespaces)
                    attach!.action = .claude(quoted(arg) ?? arg)
                    continue
                }
                if trimmed.hasPrefix("model ") { attach!.model = String(trimmed.dropFirst(6)).trimmingCharacters(in: .whitespaces); continue }
                var body = trimmed
                var negated = false
                if body.hasPrefix("not ") { negated = true; body = String(body.dropFirst(4)).trimmingCharacters(in: .whitespaces) }
                do { attach!.conditions.append((negated, try condition(body))) } catch { errors.append("\(source):\(n): \(error.localizedDescription)") }
                continue
            }
            guard current != nil else {
                errors.append("\(source):\(n): condition outside a rule")
                continue
            }
            var body = trimmed
            var negated = false
            if body.hasPrefix("not ") { negated = true; body = String(body.dropFirst(4)).trimmingCharacters(in: .whitespaces) }
            do {
                current!.conditions.append((negated, try condition(body)))
            } catch {
                errors.append("\(source):\(n): \(error.localizedDescription)")
            }
        }
        flush()
        return (rules, attachments, disabled, errors)
    }

    struct ParseError: Error, LocalizedError {
        var message: String
        var errorDescription: String? { message }
    }

    private static func condition(_ s: String) throws -> ReviewRule.Condition {
        let parts = s.split(separator: " ", maxSplits: 1).map(String.init)
        let head = parts[0], arg = parts.count > 1 ? parts[1].trimmingCharacters(in: .whitespaces) : ""
        switch head {
        case "path":
            guard arg.hasPrefix("~") else { throw ParseError(message: "use `path ~ <glob>`") }
            return .path(try glob(arg.dropFirst().trimmingCharacters(in: .whitespaces)))
        case "lang":
            return .lang(Set(arg.split(separator: ",").map { $0.trimmingCharacters(in: .whitespaces).lowercased() }))
        case "file":
            guard fileKinds.contains(arg) else { throw ParseError(message: "unknown file kind `\(arg)`") }
            return .file(arg)
        case "hunk":
            guard facts.contains(arg) else { throw ParseError(message: "unknown hunk fact `\(arg)` (known: \(facts.sorted().joined(separator: ", ")))") }
            return .hunk(arg)
        case "code", "comment", "text":
            let sub = arg.split(separator: " ", maxSplits: 1).map(String.init)
            guard sub.count == 2 else { throw ParseError(message: "use `\(head) touches /regex/`") }
            let re = try regex(sub[1])
            if head == "code" {
                guard ["touches", "adds", "removes"].contains(sub[0]) else { throw ParseError(message: "use `code touches|adds|removes /regex/`") }
                return .code(sub[0], re)
            }
            guard sub[0] == "touches" else { throw ParseError(message: "use `\(head) touches /regex/`") }
            return head == "comment" ? .comment(re) : .text(re)
        case "comment-words", "lines":
            let sub = arg.split(separator: " ").map(String.init)
            guard sub.count == 2, ["<", "<=", ">", ">=", "=="].contains(sub[0]), let n = Int(sub[1]) else {
                throw ParseError(message: "use `\(head) <op> N`")
            }
            return head == "lines" ? .lines(sub[0], n) : .commentWords(sub[0], n)
        case "refs", "callers":
            let sub = arg.split(separator: " ", maxSplits: 1).map(String.init)
            if head == "callers", sub.first == "in", sub.count == 2 { return .semantic(.callersIn(try glob(sub[1]))) }
            guard sub.count == 2, ["<", "<=", ">", ">=", "=="].contains(sub[0]), let n = Int(sub[1].trimmingCharacters(in: .whitespaces)) else {
                throw ParseError(message: head == "refs" ? "use `refs <op> N`" : "use `callers <op> N` or `callers in <glob>`")
            }
            return .semantic(head == "refs" ? .refs(sub[0], n) : .callers(sub[0], n))
        case "called-from":
            var depth = 3
            var re = arg
            if let r = arg.range(of: #"\s+depth\s+\d+\s*$"#, options: .regularExpression) {
                depth = Int(arg[r].split(separator: " ").last ?? "3") ?? 3
                re = String(arg[..<r.lowerBound])
            }
            return .semantic(.calledFrom(try regex(re), min(6, max(1, depth))))
        case "calls": return .semantic(.calls(try regex(arg)))
        case "signature": return .semantic(.signature(try regex(arg)))
        case "llm":
            guard let q = quoted(arg), !q.isEmpty else { throw ParseError(message: "use `llm \"<yes/no question>\"`") }
            return .llm(q)
        case "ts":
            let sub = arg.split(separator: " ", maxSplits: 1).map(String.init)
            guard sub.count == 2 else { throw ParseError(message: "use `ts touches <kinds>` or `ts query <query>`") }
            if sub[0] == "touches" {
                let kinds = sub[1].split(separator: ",").map { $0.trimmingCharacters(in: .whitespaces) }
                return .tsQuery("[" + kinds.map { "(\($0))" }.joined(separator: " ") + "] @node")
            }
            guard sub[0] == "query" else { throw ParseError(message: "use `ts touches <kinds>` or `ts query <query>`") }
            return .tsQuery(sub[1])
        default:
            throw ParseError(message: "unknown condition `\(head)`")
        }
    }

    private static func stripComment(_ s: String) -> String {
        // `#` starts a comment unless inside a /regex/, a "string" or a tree-sitter query (#eq? etc.).
        var inRegex = false, inString = false, depth = 0
        var prev: Character = " "
        for (i, c) in s.enumerated() {
            if c == "\"" && prev != "\\" { inString.toggle() }
            // A regex opens with a slash after whitespace (an argument), so paths like src/lib.rs are not regexes.
            if c == "/" && !inString {
                if inRegex { if prev != "\\" { inRegex = false } } else if prev == " " || prev == "\t" { inRegex = true }
            }
            if c == "(" && !inString && !inRegex { depth += 1 }
            if c == ")" && !inString && !inRegex { depth -= 1 }
            if c == "#" && !inRegex && !inString && depth == 0 && (i == 0 || prev == " " || prev == "\t") {
                return String(s.prefix(i))
            }
            prev = c
        }
        return s
    }

    private static func quoted(_ s: String) -> String? {
        guard s.hasPrefix("\""), let end = s.dropFirst().firstIndex(of: "\"") else { return nil }
        return String(s[s.index(after: s.startIndex)..<end])
    }

    private static func regex(_ s: String) throws -> NSRegularExpression {
        guard s.hasPrefix("/"), let end = s.lastIndex(of: "/"), end != s.startIndex else { throw ParseError(message: "regex must be written /like this/") }
        let body = String(s[s.index(after: s.startIndex)..<end])
        let flags = s[s.index(after: end)...]
        var opts: NSRegularExpression.Options = [.anchorsMatchLines]
        if flags.contains("i") { opts.insert(.caseInsensitive) }
        do { return try NSRegularExpression(pattern: body, options: opts) } catch {
            throw ParseError(message: "bad regex /\(body)/")
        }
    }

    static func glob(_ g: String) throws -> NSRegularExpression {
        var out = "^"
        var i = g.startIndex
        var inBrace = false
        while i < g.endIndex {
            let c = g[i]
            let next = g.index(after: i)
            if c == "*" && next < g.endIndex && g[next] == "*" {
                let after = g.index(after: next)
                if after < g.endIndex && g[after] == "/" { out += "(?:.*/)?"; i = g.index(after: after); continue }
                out += ".*"; i = after; continue
            }
            switch c {
            case "*": out += "[^/]*"
            case "?": out += "[^/]"
            case "{": out += "(?:"; inBrace = true
            case "}": out += ")"; inBrace = false
            case "," where inBrace: out += "|"
            default: out += NSRegularExpression.escapedPattern(for: String(c))
            }
            i = next
        }
        do { return try NSRegularExpression(pattern: out + "$") } catch { throw ParseError(message: "bad glob `\(g)`") }
    }
}

/// Loads and caches rule files for a repository: `<repo>/.spelunk/review.rules`, the user's
/// `~/Library/Application Support/Spelunk/review.rules`, then the built-in defaults.
final class ReviewRules: @unchecked Sendable {
    static let shared = ReviewRules()
    private let lock = NSLock()
    private var cache: [String: (stamp: String, set: RuleSet)] = [:]

    static var userURL: URL {
        FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0].appendingPathComponent("Spelunk/review.rules")
    }

    static func repoURL(_ root: URL) -> URL { root.appendingPathComponent(".spelunk/review.rules") }

    /// Defaults alone, for callers without a repository (tests, previews).
    let defaultsOnly: RuleSet = {
        let d = RuleParser.parse(DefaultRules.text, source: "defaults")
        return RuleSet(rules: d.rules, errors: d.errors)
    }()

    func rules(for root: URL) -> RuleSet {
        let files = [Self.repoURL(root), Self.userURL]
        let stamp = files.map { u in
            ((try? FileManager.default.attributesOfItem(atPath: u.path)[.modificationDate] as? Date)?.timeIntervalSince1970).map { "\($0)" } ?? "-"
        }.joined(separator: "|")
        lock.lock()
        if let c = cache[root.path], c.stamp == stamp { lock.unlock(); return c.set }
        lock.unlock()

        var set = RuleSet()
        var disabled: Set<String> = []
        // Your rules come first, so they can override or disable the repository's; `disable` removes
        // rules with that reason from every file loaded after it, defaults included.
        for (url, name) in [(files[1], "~/…/Spelunk/review.rules"), (files[0], ".spelunk/review.rules")] {
            guard let text = try? String(contentsOf: url, encoding: .utf8) else { continue }
            let r = RuleParser.parseAll(text, source: name)
            set.rules += r.rules.filter { !disabled.contains($0.reason) }
            set.attachments += r.attachments
            set.errors += r.errors
            disabled.formUnion(r.disabled)
        }
        let d = RuleParser.parse(DefaultRules.text, source: "defaults")
        set.errors += d.errors
        set.rules += d.rules.filter { !disabled.contains($0.reason) }
        lock.lock()
        cache[root.path] = (stamp, set)
        lock.unlock()
        return set
    }
}

/// What a rule can ask about a hunk. Computed once per hunk by `ChangeClassifier`.
struct HunkFacts: @unchecked Sendable {
    var path: String
    var langs: Set<String>
    var langDisplay: String
    var fileKinds: Set<String>
    var facts: Set<String>
    var addedCode: String
    var removedCode: String
    var changedComments: String
    var changedText: String
    var commentWords: Int
    var changedLines: Int
    var publicName: String?
    var rename: String?
    /// Lazily evaluates a tree-sitter query against the changed region of either side.
    var tsMatches: (String) -> Bool
    /// Filled in by the second pass; nil while unknown.
    var semantic: SemanticFacts?
    /// Answers to `llm` questions about this hunk; a missing key is unknown.
    var answers: [String: Bool] = [:]

    func count(_ re: NSRegularExpression, _ s: String) -> Int {
        re.numberOfMatches(in: s, range: NSRange(location: 0, length: (s as NSString).length))
    }

    /// Whether a condition holds; nil when it needs an answer the first pass does not have.
    func check(_ c: ReviewRule.Condition) -> Bool? {
        switch c {
        case .semantic(let q):
            guard let s = semantic else { return nil }
            guard s.available else { return false }
            switch q {
            case .refs(let op, let n): return s.refs.map { compare($0, op, n) } ?? false
            case .callers(let op, let n): return compare(s.callers.count, op, n)
            case .callersIn(let re): return s.callers.contains { count(re, $0.path) > 0 }
            case .calledFrom(let re, _): return s.transitiveCallers.contains { count(re, $0) > 0 }
            case .calls(let re): return s.callees.contains { count(re, $0) > 0 }
            case .signature(let re): return s.signature.map { count(re, $0) > 0 } ?? false
            }
        case .llm(let q): return answers[q]
        default: return holds(c)
        }
    }

    func holds(_ c: ReviewRule.Condition) -> Bool {
        switch c {
        case .semantic, .llm: return check(c) ?? false
        case .path(let re): return count(re, path) > 0
        case .lang(let l): return !langs.isDisjoint(with: l)
        case .file(let k): return fileKinds.contains(k)
        case .hunk(let f): return facts.contains(f)
        case .code(let mode, let re):
            let a = count(re, addedCode), r = count(re, removedCode)
            switch mode {
            case "adds": return a > r
            case "removes": return r > a
            default: return a + r > 0
            }
        case .comment(let re): return count(re, changedComments) > 0
        case .text(let re): return count(re, changedText) > 0
        case .commentWords(let op, let n): return compare(commentWords, op, n)
        case .lines(let op, let n): return compare(changedLines, op, n)
        case .tsQuery(let q): return tsMatches(q)
        }
    }

    private func compare(_ v: Int, _ op: String, _ n: Int) -> Bool {
        switch op {
        case "<": v < n
        case "<=": v <= n
        case ">": v > n
        case ">=": v >= n
        default: v == n
        }
    }

    func expand(_ reason: String) -> String {
        reason.replacingOccurrences(of: "{lang}", with: langDisplay)
            .replacingOccurrences(of: "{refs}", with: semantic?.refs.map(String.init) ?? "?")
            .replacingOccurrences(of: "{callers}", with: semantic.map { String($0.callers.count) } ?? "?")
            .replacingOccurrences(of: "{name}", with: publicName ?? "?")
            .replacingOccurrences(of: "{rename}", with: rename ?? "rename")
    }
}

extension RuleSet {
    struct Outcome {
        var tier: ChangeTier
        var reasons: [String]
        var settled: Bool
        var rule: String?
        var pending = RulePending()
    }

    /// Tri-state match: false if a known condition fails, nil if only unknown ones remain.
    static func match(_ conditions: [(negated: Bool, condition: ReviewRule.Condition)], _ f: HunkFacts) -> Bool? {
        var unknown = false
        for c in conditions {
            // A semantic question nobody could answer leaves the rule undecidable: it does not fire,
            // whether or not the condition is negated.
            if case .semantic = c.condition, let s = f.semantic, !s.available { return false }
            guard let v = f.check(c.condition) else { unknown = true; continue }
            if v == c.negated { return false }
        }
        return unknown ? nil : true
    }

    static func pending(_ conditions: [(negated: Bool, condition: ReviewRule.Condition)], _ f: HunkFacts) -> RulePending {
        var p = RulePending()
        for c in conditions where f.check(c.condition) == nil {
            switch c.condition {
            case .semantic(let q): p.needs = p.needs.union(q.needs)
            case .llm(let q): p.questions.insert(q)
            default: break
            }
        }
        return p
    }

    func evaluate(_ f: HunkFacts) -> Outcome {
        var decided: ReviewRule?
        var reasons: [String] = []
        var notes: [String] = []
        var settled = false
        var pending = RulePending()
        for r in rules {
            let m = Self.match(r.conditions, f)
            if m == nil {
                // Only rules that could still change the outcome are worth an answer.
                let relevant: Bool
                switch r.tier {
                case .note: relevant = true
                case .tier(let t):
                    if decided == nil { relevant = true }
                    else if r.collect, case .tier(let dt) = decided!.tier { relevant = dt == t } else { relevant = false }
                }
                if relevant { pending.formUnion(Self.pending(r.conditions, f)) }
                continue
            }
            guard m == true else { continue }
            switch r.tier {
            case .note:
                notes.append(f.expand(r.reason))
            case .tier(let t):
                if decided == nil {
                    decided = r
                    reasons.append(f.expand(r.reason))
                    settled = r.settled
                } else if r.collect, case .tier(let dt) = decided!.tier, dt == t {
                    let e = f.expand(r.reason)
                    if !reasons.contains(e) { reasons.append(e) }
                }
            }
        }
        guard let d = decided, case .tier(let t) = d.tier else {
            return Outcome(tier: .behavior, reasons: ["code change"] + notes, settled: false, rule: nil, pending: pending)
        }
        return Outcome(tier: t, reasons: reasons + notes.filter { !reasons.contains($0) }, settled: settled, rule: d.location, pending: pending)
    }
}

/// Caches compiled tree-sitter queries per grammar.
final class QueryCache: @unchecked Sendable {
    static let shared = QueryCache()
    private let lock = NSLock()
    private var cache: [String: Query?] = [:]
    private(set) var errors: [String: String] = [:]

    func query(_ source: String, language: SwiftTreeSitter.Language, key: String) -> Query? {
        let k = key + "\u{1}" + source
        lock.lock(); defer { lock.unlock() }
        if let q = cache[k] { return q }
        do {
            let q = try Query(language: language, data: Data(source.utf8))
            cache[k] = q
            return q
        } catch {
            errors[source] = "\(error)"
            cache[k] = .some(nil)
            return nil
        }
    }
}

import AppKit

/// Opening and seeding rule files from the UI.
enum RulesFiles {
    static let template = #"""
    # Spelunk review rules (yours). These run before the defaults; the first matching rule wins.
    # See "View Default Rules" for every built-in rule and the full condition list.
    #
    # rule <critical|behavior|supporting|docs|tests|mechanical|note> "<reason>" [settled] [collect]
    #   path ~ <glob>               lang rust,markdown        file added|deleted|generated|test
    #   hunk comments-only|formatting-only|imports-only|in-test|public-signature|rename|plumbing|...
    #   code touches|adds|removes /regex/    comment touches /regex/    text touches /regex/
    #   comment-words > 3            lines > 40
    #   ts touches <node kinds>      ts query <tree-sitter query>
    #   not <condition>
    # Semantic (rust-analyzer, else SCIP; checked only when the other conditions hold):
    #   refs > 20      callers > 5      callers in src/adapter/**
    #   called-from /sequence_peek|handle_command/ depth 3      calls /block_on|spawn_blocking/
    #   signature /-> Result</      llm "Does this change when a lock is released?"
    # disable "<reason of a default rule>"
    #
    # attach "<title>" [auto] [per file|hunk|change]     (adds a review artifact instead of a tier)
    #   <conditions>
    #   run <command>        {file} {files} {out} {name}; files written to {out} are shown inline
    #   claude "<prompt>"    read-only Claude session; Markdown answer
    #   model sonnet
    #
    # Examples:
    #
    # rule critical "design doc" collect
    #   path ~ doc/developer/design/**
    #
    # rule critical "lock held across await"
    #   ts query (await_expression) @a
    #   code touches /\.lock\(\)/
    #
    # rule critical "widely used: {refs} references" collect
    #   hunk public-signature
    #   refs > 25
    #
    # attach "Benchmark plot" per file
    #   path ~ **/benches/**
    #   run scripts/bench-boxplot.sh {file} {out}
    #
    # attach "Component render" per file
    #   path ~ **/*.tsx
    #   run npx tsx scripts/render-component.ts {file} {out}/render.png
    #
    # attach "Usage examples" per hunk
    #   path ~ **/graphql/**
    #   llm "Does this hunk add a new GraphQL resolver?"
    #   claude "Show a basic query for each new resolver and two edge cases, with the expected response shape."
    #
    # disable "comment wording"

    """#

    /// Syntax reference for writing rules, given to Claude when it drafts one.
    static var reference: String {
        template.split(separator: "\n").filter { $0.hasPrefix("#") }.map { String($0.dropFirst(min(2, $0.count))) }.joined(separator: "\n")
    }

    static func append(_ text: String, toRepo root: URL?) throws {
        let u = root.map(ReviewRules.repoURL) ?? ReviewRules.userURL
        try FileManager.default.createDirectory(at: u.deletingLastPathComponent(), withIntermediateDirectories: true)
        var existing = (try? String(contentsOf: u, encoding: .utf8)) ?? (root == nil ? template : template.replacingOccurrences(of: "(yours)", with: "(this repository)"))
        if !existing.hasSuffix("\n") { existing += "\n" }
        try (existing + "\n" + text.trimmingCharacters(in: .whitespacesAndNewlines) + "\n").write(to: u, atomically: true, encoding: .utf8)
    }

    static func openUserRules() {
        let u = ReviewRules.userURL
        if !FileManager.default.fileExists(atPath: u.path) {
            try? FileManager.default.createDirectory(at: u.deletingLastPathComponent(), withIntermediateDirectories: true)
            try? template.write(to: u, atomically: true, encoding: .utf8)
        }
        NSWorkspace.shared.open(u)
    }

    static func openRepoRules(_ root: URL) {
        let u = ReviewRules.repoURL(root)
        if !FileManager.default.fileExists(atPath: u.path) {
            try? FileManager.default.createDirectory(at: u.deletingLastPathComponent(), withIntermediateDirectories: true)
            try? template.replacingOccurrences(of: "(yours)", with: "(this repository)").write(to: u, atomically: true, encoding: .utf8)
        }
        NSWorkspace.shared.open(u)
    }

    static func openDefaults() {
        let u = FileManager.default.temporaryDirectory.appendingPathComponent("spelunk-default.rules")
        try? DefaultRules.text.write(to: u, atomically: true, encoding: .utf8)
        NSWorkspace.shared.open(u)
    }
}
