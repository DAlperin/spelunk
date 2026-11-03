import Foundation
import SwiftTreeSitter

/// Review rules: s-expressions that classify diff hunks and attach review artifacts.
///
/// ```
/// ; comment
/// (define <name> <condition>)
/// (rule <tier> "<reason>" [:settled] [:collect] <condition>...)
/// (disable "<reason>")
/// (attach "<title>" [:auto] [:per file|hunk|change] [:model <alias>]
///   <condition>...
///   (run "<shell command>")      ; or (claude "<prompt>")
/// ```
///
/// Tiers: critical, behavior, supporting, docs, tests, mechanical, plus `note`, which only adds a
/// reason. Rules are checked in order (your file, then the repository's, then defaults); the first
/// matching non-note rule sets the tier. A `:collect` rule that also matches adds its reason when its
/// tier won, which is how several risk signals are listed together. `:settled` keeps a hunk out of
/// the Claude classification pass. `disable` removes rules with that reason from the files loaded
/// after its own, defaults included; it never removes attach rules. A rule's conditions must all
/// hold. `define` names a condition for the rest of its file. Reasons may use `{lang}`, `{name}`
/// (public item), `{rename}`, `{refs}` and `{callers}`.
///
/// Conditions:
/// - `(all c...)`, `(any c...)`, `(not c)`, or a defined name
/// - `(path "<glob>"...)`                         (any of the globs; `*`, `**`, `?`, `{a,b}`)
/// - `(lang <name>...)`                           (rust, markdown, toml, or an installed grammar)
/// - `(file added|deleted|renamed|modified|generated|test)`
/// - `(hunk <fact>)`: formatting-only, comments-only, comment-edit, imports-only, mod-decls-only,
///   in-test, rename, public-signature, plumbing, structural, additions-only, deletions-only
/// - `(code touches|adds|removes /regex/)`        (code with comments and string contents removed)
/// - `(comment touches /regex/)`, `(text touches /regex/)`   (changed comment text, raw changed lines)
/// - `(comment-words <op> N)`, `(lines <op> N)`   (op: < <= > >= ==)
/// - `(ts touches <node-kind>...)`, `(ts query "<tree-sitter query>")`
///
/// Semantic conditions ask rust-analyzer (or the SCIP index, then text search) about the item the
/// hunk changes. They are checked after the first pass, only where they can still change the outcome:
/// - `(refs <op> N)`, `(callers <op> N)`, `(callers in "<glob>")`
/// - `(called-from /regex/ [:depth N])`           (a transitive caller's name matches; depth 3)
/// - `(calls /regex/)`, `(signature /regex/)`
/// - `(llm "<yes/no question>")`                  (asked of a cheap model, batched, cached per hunk)
///
/// Conditions are three-valued: an answer not yet known keeps the rule pending, and `not`, `all` and
/// `any` keep it pending only while it could still decide the outcome. A semantic question no
/// provider could answer means the rule cannot fire, negated or not.
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
    var conditions: RuleExpr
    var source: String
    var line: Int

    var location: String { "\(source):\(line)" }
}

/// A rule's condition: a test, or a combination of them.
indirect enum RuleExpr: Sendable {
    case test(ReviewRule.Condition)
    case not(RuleExpr)
    case all([RuleExpr])
    case any([RuleExpr])

    static let always = RuleExpr.all([])
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
    var conditions: RuleExpr
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
    static let ops: Set<String> = ["<", "<=", ">", ">=", "=="]

    /// Parses one rules file. `disabled` collects reasons from `disable` forms.
    static func parse(_ text: String, source: String) -> (rules: [ReviewRule], disabled: Set<String>, errors: [String]) {
        let r = parseAll(text, source: source)
        return (r.rules, r.disabled, r.errors)
    }

    static func parseAll(_ text: String, source: String) -> (rules: [ReviewRule], attachments: [AttachRule], disabled: Set<String>, errors: [String]) {
        var text = text
        var errors: [String] = []
        if LegacyRules.isLegacy(text) {
            let converted = LegacyRules.convert(text)
            text = converted.text
            errors += converted.errors.map { "\(source):\($0)" }
            errors.append("\(source): uses the old line-based rule format; it was read as converted, and Convert Rules Files (in the palette) rewrites it")
        }
        let forms: [SExpr]
        do { forms = try SExpr.read(text) } catch let e as SExpr.ReadError {
            return ([], [], [], errors + ["\(source):\(e.line): \(e.message)"])
        } catch { return ([], [], [], errors + ["\(source): \(error.localizedDescription)"]) }

        var rules: [ReviewRule] = []
        var attachments: [AttachRule] = []
        var disabled: Set<String> = []
        var defines: [String: RuleExpr] = [:]
        for form in forms {
            do {
                guard let items = form.list, let head = items.first?.symbol else {
                    throw ParseError(line: form.line, message: "expected `(rule …)`, `(attach …)`, `(define …)` or `(disable …)`, found \(form.describe)")
                }
                let args = Array(items.dropFirst())
                switch head {
                case "rule": rules.append(try rule(args, form, source: source, defines: defines))
                case "attach": attachments.append(try attach(args, form, text: text, source: source, defines: defines))
                case "disable":
                    guard args.count == 1, let r = args[0].string else { throw ParseError(line: form.line, message: "use `(disable \"<reason>\")`") }
                    disabled.insert(r)
                case "define":
                    guard args.count == 2, let name = args[0].symbol, !name.hasPrefix(":") else {
                        throw ParseError(line: form.line, message: "use `(define <name> <condition>)`")
                    }
                    guard !conditionHeads.contains(name) else { throw ParseError(line: form.line, message: "`\(name)` is a built-in condition") }
                    defines[name] = try condition(args[1], defines)
                default:
                    throw ParseError(line: form.line, message: "unknown form `\(head)`; expected rule, attach, define or disable")
                }
            } catch let e as ParseError {
                errors.append("\(source):\(e.line): \(e.message)")
            } catch {
                errors.append("\(source):\(form.line): \(error.localizedDescription)")
            }
        }
        return (rules, attachments, disabled, errors)
    }

    struct ParseError: Error, LocalizedError {
        var line: Int
        var message: String
        var errorDescription: String? { message }
    }

    private static func rule(_ args: [SExpr], _ form: SExpr, source: String, defines: [String: RuleExpr]) throws -> ReviewRule {
        guard args.count >= 2, let tierName = args[0].symbol else { throw ParseError(line: form.line, message: "use `(rule <tier> \"<reason>\" <condition>…)`") }
        let tier: ReviewRule.Tier
        if tierName == "note" { tier = .note } else if let t = ChangeTier(rawValue: tierName) { tier = .tier(t) } else {
            throw ParseError(line: args[0].line, message: "unknown tier `\(tierName)`")
        }
        guard let reason = args[1].string else { throw ParseError(line: args[1].line, message: "a rule's reason is a quoted string") }
        var settled = false, collect = false
        var conds: [RuleExpr] = []
        for a in args.dropFirst(2) {
            if let k = a.symbol, k.hasPrefix(":") {
                switch k {
                case ":settled": settled = true
                case ":collect": collect = true
                default: throw ParseError(line: a.line, message: "unknown option `\(k)`; rules take :settled and :collect")
                }
                continue
            }
            conds.append(try condition(a, defines))
        }
        return ReviewRule(tier: tier, reason: reason, settled: settled, collect: collect, conditions: .all(conds), source: source, line: form.line)
    }

    private static func attach(_ args: [SExpr], _ form: SExpr, text: String, source: String, defines: [String: RuleExpr]) throws -> AttachRule {
        guard let title = args.first?.string else { throw ParseError(line: form.line, message: "use `(attach \"<title>\" … (run \"<command>\"))`") }
        var auto = false
        var scope = AttachRule.Scope.file
        var model: String?
        var action: AttachRule.Action?
        var conds: [RuleExpr] = []
        var i = 1
        while i < args.count {
            let a = args[i]
            if let k = a.symbol, k.hasPrefix(":") {
                switch k {
                case ":auto": auto = true
                case ":per":
                    guard i + 1 < args.count, let s = args[i + 1].symbol.flatMap(AttachRule.Scope.init(rawValue:)) else {
                        throw ParseError(line: a.line, message: "use `:per file`, `:per hunk` or `:per change`")
                    }
                    scope = s
                    i += 1
                case ":model":
                    guard i + 1 < args.count, let m = args[i + 1].symbol ?? args[i + 1].string else { throw ParseError(line: a.line, message: "use `:model <alias>`") }
                    model = m
                    i += 1
                default: throw ParseError(line: a.line, message: "unknown option `\(k)`; attach takes :auto, :per and :model")
                }
                i += 1
                continue
            }
            if let l = a.list, let h = l.first?.symbol, h == "run" || h == "claude" {
                guard l.count == 2, let body = l[1].string else { throw ParseError(line: a.line, message: "use `(\(h) \"…\")`") }
                guard action == nil else { throw ParseError(line: a.line, message: "an attach has one `run` or `claude`") }
                action = h == "run" ? .run(body) : .claude(body)
            } else {
                conds.append(try condition(a, defines))
            }
            i += 1
        }
        guard action != nil else { throw ParseError(line: form.line, message: "attach needs `(run \"<command>\")` or `(claude \"<prompt>\")`") }
        return AttachRule(title: title, auto: auto, scope: scope, conditions: .all(conds), action: action, model: model,
                          source: source, line: form.line, text: String(text[form.range]))
    }

    static let conditionHeads: Set<String> = [
        "all", "any", "not", "path", "lang", "file", "hunk", "code", "comment", "text", "comment-words", "lines",
        "ts", "refs", "callers", "called-from", "calls", "signature", "llm",
    ]

    private static func condition(_ e: SExpr, _ defines: [String: RuleExpr]) throws -> RuleExpr {
        if let name = e.symbol {
            guard let d = defines[name] else { throw ParseError(line: e.line, message: "`\(name)` is not defined above") }
            return d
        }
        guard let items = e.list, let head = items.first?.symbol else { throw ParseError(line: e.line, message: "expected a condition, found \(e.describe)") }
        let args = Array(items.dropFirst())
        func fail(_ usage: String) -> ParseError { ParseError(line: e.line, message: "use `\(usage)`") }
        func regexArg(_ a: SExpr?, _ usage: String) throws -> NSRegularExpression {
            guard let a, case .regex(let p, let f) = a.kind else { throw ParseError(line: e.line, message: "use `\(usage)`; regexes are written /like this/") }
            return try regex(p, f, line: a.line)
        }
        func opArg(_ usage: String) throws -> (String, Int) {
            guard args.count == 2, let op = args[0].symbol, ops.contains(op), case .number(let n) = args[1].kind else { throw fail(usage) }
            return (op, n)
        }
        switch head {
        case "all": return .all(try args.map { try condition($0, defines) })
        case "any": return .any(try args.map { try condition($0, defines) })
        case "not":
            guard args.count == 1 else { throw fail("(not <condition>)") }
            return .not(try condition(args[0], defines))
        case "path":
            let globs = args.compactMap(\.string)
            guard !globs.isEmpty, globs.count == args.count else { throw fail("(path \"<glob>\"…)") }
            let res = try globs.map { RuleExpr.test(.path(try glob($0, line: e.line))) }
            return res.count == 1 ? res[0] : .any(res)
        case "lang":
            let names = args.compactMap(\.symbol)
            guard !names.isEmpty, names.count == args.count else { throw fail("(lang <name>…)") }
            return .test(.lang(Set(names.map { $0.lowercased() })))
        case "file":
            guard args.count == 1, let k = args[0].symbol, fileKinds.contains(k) else {
                throw ParseError(line: e.line, message: "use `(file \(fileKinds.sorted().joined(separator: "|")))`")
            }
            return .test(.file(k))
        case "hunk":
            guard args.count == 1, let f = args[0].symbol, facts.contains(f) else {
                throw ParseError(line: e.line, message: "unknown hunk fact (known: \(facts.sorted().joined(separator: ", ")))")
            }
            return .test(.hunk(f))
        case "code", "comment", "text":
            let modes = head == "code" ? ["touches", "adds", "removes"] : ["touches"]
            let usage = "(\(head) \(modes.joined(separator: "|")) /regex/)"
            guard args.count == 2, let mode = args[0].symbol, modes.contains(mode) else { throw fail(usage) }
            let re = try regexArg(args[1], usage)
            return .test(head == "code" ? .code(mode, re) : head == "comment" ? .comment(re) : .text(re))
        case "comment-words", "lines":
            let (op, n) = try opArg("(\(head) <op> N)")
            return .test(head == "lines" ? .lines(op, n) : .commentWords(op, n))
        case "refs":
            let (op, n) = try opArg("(refs <op> N)")
            return .test(.semantic(.refs(op, n)))
        case "callers":
            if args.count == 2, args[0].symbol == "in", let g = args[1].string { return .test(.semantic(.callersIn(try glob(g, line: e.line)))) }
            let (op, n) = try opArg("(callers <op> N)` or `(callers in \"<glob>\")")
            return .test(.semantic(.callers(op, n)))
        case "called-from":
            let usage = "(called-from /regex/ [:depth N])"
            var depth = 3
            if args.count == 3 {
                guard args[1].symbol == ":depth", case .number(let d) = args[2].kind else { throw fail(usage) }
                depth = d
            } else if args.count != 1 { throw fail(usage) }
            return .test(.semantic(.calledFrom(try regexArg(args.first, usage), min(6, max(1, depth)))))
        case "calls", "signature":
            guard args.count == 1 else { throw fail("(\(head) /regex/)") }
            let re = try regexArg(args[0], "(\(head) /regex/)")
            return .test(.semantic(head == "calls" ? .calls(re) : .signature(re)))
        case "llm":
            guard args.count == 1, let q = args[0].string, !q.isEmpty else { throw fail("(llm \"<yes/no question>\")") }
            return .test(.llm(q))
        case "ts":
            let usage = "(ts touches <kind>…)` or `(ts query \"<query>\")"
            guard args.count >= 2, let mode = args[0].symbol else { throw fail(usage) }
            if mode == "touches" {
                let kinds = args.dropFirst().compactMap(\.symbol)
                guard kinds.count == args.count - 1 else { throw fail(usage) }
                return .test(.tsQuery("[" + kinds.map { "(\($0))" }.joined(separator: " ") + "] @node"))
            }
            guard mode == "query", args.count == 2, let q = args[1].string else { throw fail(usage) }
            return .test(.tsQuery(q))
        default:
            throw ParseError(line: e.line, message: "unknown condition `\(head)`")
        }
    }

    private static func regex(_ body: String, _ flags: String, line: Int) throws -> NSRegularExpression {
        var opts: NSRegularExpression.Options = [.anchorsMatchLines]
        if flags.contains("i") { opts.insert(.caseInsensitive) }
        do { return try NSRegularExpression(pattern: body, options: opts) } catch {
            throw ParseError(line: line, message: "bad regex /\(body)/")
        }
    }

    static func glob(_ g: String, line: Int = 0) throws -> NSRegularExpression {
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
        do { return try NSRegularExpression(pattern: out + "$") } catch { throw ParseError(line: line, message: "bad glob `\(g)`") }
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

    /// Three-valued truth plus `undecidable`: a semantic question no provider could answer, which
    /// keeps a rule from firing whichever way it is negated.
    enum Truth { case yes, no, unknown, undecidable }

    static func truth(_ e: RuleExpr, _ f: HunkFacts) -> Truth {
        switch e {
        case .test(let c):
            if case .semantic = c, let s = f.semantic, !s.available { return .undecidable }
            guard let v = f.check(c) else { return .unknown }
            return v ? .yes : .no
        case .not(let x):
            switch truth(x, f) {
            case .yes: return .no
            case .no: return .yes
            case let t: return t
            }
        case .all(let xs):
            // One false decides; otherwise an undecidable part blocks the rule; otherwise it waits.
            var r = Truth.yes
            for x in xs {
                switch truth(x, f) {
                case .no: return .no
                case .undecidable: r = .undecidable
                case .unknown: if r == .yes { r = .unknown }
                case .yes: break
                }
            }
            return r
        case .any(let xs):
            var r = Truth.no
            for x in xs {
                switch truth(x, f) {
                case .yes: return .yes
                case .unknown: r = .unknown
                case .undecidable: if r == .no { r = .undecidable }
                case .no: break
                }
            }
            return r
        }
    }

    /// True or false once decided; nil while an answer that could change it is missing.
    static func match(_ e: RuleExpr, _ f: HunkFacts) -> Bool? {
        switch truth(e, f) {
        case .yes: true
        case .unknown: nil
        case .no, .undecidable: false
        }
    }

    /// The answers that could still decide `e`: only from parts that are themselves undecided.
    static func pending(_ e: RuleExpr, _ f: HunkFacts) -> RulePending {
        var p = RulePending()
        guard truth(e, f) == .unknown else { return p }
        switch e {
        case .test(.semantic(let q)): p.needs = q.needs
        case .test(.llm(let q)): p.questions.insert(q)
        case .test: break
        case .not(let x): p = pending(x, f)
        case .all(let xs), .any(let xs): for x in xs { p.formUnion(pending(x, f)) }
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
    ; Spelunk review rules (yours). These run before the defaults; the first matching rule wins.
    ; See "View Default Rules" for every built-in rule.
    ;
    ; (rule <critical|behavior|supporting|docs|tests|mechanical|note> "<reason>" [:settled] [:collect]
    ;   <condition>...)                       all conditions must hold
    ; (define <name> <condition>)             a named condition for the rest of this file
    ; (disable "<reason of a default rule>")
    ;
    ; Conditions:
    ;   (all c...)  (any c...)  (not c)  <defined name>
    ;   (path "src/adapter/**" "doc/**")      (lang rust markdown)      (file added|deleted|generated|test)
    ;   (hunk comments-only|formatting-only|imports-only|in-test|public-signature|rename|plumbing|...)
    ;   (code touches|adds|removes /regex/)   (comment touches /regex/)  (text touches /regex/)
    ;   (comment-words > 3)                   (lines > 40)
    ;   (ts touches <node kind>...)           (ts query "<tree-sitter query>")
    ; Semantic (rust-analyzer, else SCIP; checked only when they can still change the outcome):
    ;   (refs > 20)  (callers > 5)  (callers in "src/adapter/**")
    ;   (called-from /sequence_peek|handle_command/ :depth 3)  (calls /block_on|spawn_blocking/)
    ;   (signature /-> Result</)  (llm "Does this change when a lock is released?")
    ;
    ; (attach "<title>" [:auto] [:per file|hunk|change] [:model sonnet]   adds a review artifact
    ;   <condition>...
    ;   (run "<command>")      {file} {files} {out} {name}; files written to {out} are shown inline
    ;   (claude "<prompt>"))   read-only Claude session; Markdown answer
    ;
    ; Examples:
    ;
    ; (rule critical "design doc" :collect
    ;   (path "doc/developer/design/**"))
    ;
    ; (define concurrency (code touches /\.lock\(\)|spawn\w*\(|mpsc::/))
    ; (rule critical "lock held across await"
    ;   (ts query "(await_expression) @a")
    ;   concurrency)
    ;
    ; (rule critical "widely used: {refs} references" :collect
    ;   (hunk public-signature)
    ;   (any (refs > 25) (callers in "src/adapter/**")))
    ;
    ; (attach "Benchmark plot" :per file
    ;   (path "**/benches/**")
    ;   (run "scripts/bench-boxplot.sh {file} {out}"))
    ;
    ; (attach "Usage examples" :per hunk
    ;   (path "**/graphql/**")
    ;   (llm "Does this hunk add a new GraphQL resolver?")
    ;   (claude "Show a basic query for each new resolver and two edge cases, with the expected response shape."))
    ;
    ; (disable "comment wording")

    """#

    /// Syntax reference for writing rules, given to Claude when it drafts one.
    static var reference: String {
        template.split(separator: "\n").filter { $0.hasPrefix(";") }.map { String($0.dropFirst(min(2, $0.count))) }.joined(separator: "\n")
    }

    static func append(_ text: String, toRepo root: URL?) throws {
        let u = root.map(ReviewRules.repoURL) ?? ReviewRules.userURL
        try FileManager.default.createDirectory(at: u.deletingLastPathComponent(), withIntermediateDirectories: true)
        var existing = (try? String(contentsOf: u, encoding: .utf8)) ?? (root == nil ? template : template.replacingOccurrences(of: "(yours)", with: "(this repository)"))
        if !existing.hasSuffix("\n") { existing += "\n" }
        try (existing + "\n" + text.trimmingCharacters(in: .whitespacesAndNewlines) + "\n").write(to: u, atomically: true, encoding: .utf8)
    }

    /// Rewrites rules files still in the line-based format as s-expressions. Your file keeps a copy
    /// of the old text beside it (`review.rules.old`); a repository's file is under version control,
    /// so it is rewritten in place. Returns a summary for the status bar.
    static func convertLegacy(root: URL?) -> String {
        var done: [String] = [], failed: [String] = []
        let files = [(ReviewRules.userURL, true)] + (root.map { [(ReviewRules.repoURL($0), false)] } ?? [])
        for (u, backup) in files {
            guard let text = try? String(contentsOf: u, encoding: .utf8), LegacyRules.isLegacy(text) else { continue }
            let c = LegacyRules.convert(text)
            do {
                if backup { try text.write(to: u.appendingPathExtension("old"), atomically: true, encoding: .utf8) }
                try c.text.write(to: u, atomically: true, encoding: .utf8)
                done.append(backup ? "your rules" : ".spelunk/review.rules")
                if !c.errors.isEmpty { failed.append("\(c.errors.count) lines left as comments in \(u.path)") }
            } catch {
                failed.append("\(u.path): \(error.localizedDescription)")
            }
        }
        if done.isEmpty && failed.isEmpty { return "No rules files use the old format" }
        return (done.isEmpty ? "" : "Converted " + done.joined(separator: " and ")) + (failed.isEmpty ? "" : "; " + failed.joined(separator: "; "))
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
