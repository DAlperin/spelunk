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
/// reason. Rules are checked in order (repository file, then user file, then defaults); the first
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

struct RuleSet: Sendable {
    var rules: [ReviewRule] = []
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
        var rules: [ReviewRule] = []
        var disabled: Set<String> = []
        var errors: [String] = []
        var current: ReviewRule?

        func flush() {
            if let c = current { rules.append(c) }
            current = nil
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
                guard trimmed.hasPrefix("rule ") else {
                    errors.append("\(source):\(n): expected `rule`, `disable` or an indented condition")
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
        return (rules, disabled, errors)
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
            if c == "/" && prev != "\\" && !inString { inRegex.toggle() }
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
        for (url, name) in [(files[0], ".spelunk/review.rules"), (files[1], "~/…/Spelunk/review.rules")] {
            guard let text = try? String(contentsOf: url, encoding: .utf8) else { continue }
            let r = RuleParser.parse(text, source: name)
            set.rules += r.rules
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
struct HunkFacts {
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

    func count(_ re: NSRegularExpression, _ s: String) -> Int {
        re.numberOfMatches(in: s, range: NSRange(location: 0, length: (s as NSString).length))
    }

    func holds(_ c: ReviewRule.Condition) -> Bool {
        switch c {
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
    }

    func evaluate(_ f: HunkFacts) -> Outcome {
        var decided: ReviewRule?
        var reasons: [String] = []
        var notes: [String] = []
        var settled = false
        for r in rules {
            let matches = r.conditions.allSatisfy { $0.negated != f.holds($0.condition) }
            guard matches else { continue }
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
            return Outcome(tier: .behavior, reasons: ["code change"] + notes, settled: false, rule: nil)
        }
        return Outcome(tier: t, reasons: reasons + notes.filter { !reasons.contains($0) }, settled: settled, rule: d.location)
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
    # disable "<reason of a default rule>"
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
    # disable "comment wording"

    """#

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
