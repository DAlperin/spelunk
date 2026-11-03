import Foundation
import SwiftTreeSitter

enum ChangeTier: String, Codable, CaseIterable, Identifiable, Comparable, Sendable {
    case critical, behavior, supporting, docs, tests, mechanical

    var id: String { rawValue }
    var rank: Int { ChangeTier.allCases.firstIndex(of: self)! }
    static func < (a: ChangeTier, b: ChangeTier) -> Bool { a.rank < b.rank }

    var title: String {
        switch self {
        case .critical: "Critical"
        case .behavior: "Behavior"
        case .supporting: "Plumbing"
        case .docs: "Docs & comments"
        case .tests: "Tests"
        case .mechanical: "Mechanical"
        }
    }

    var shortTitle: String {
        switch self {
        case .critical: "Critical"
        case .behavior: "Behavior"
        case .supporting: "Plumbing"
        case .docs: "Docs"
        case .tests: "Tests"
        case .mechanical: "Noise"
        }
    }

    /// Docs, tests and mechanical changes are acknowledged in bulk; the rest are reviewed one by one.
    var isLowSignal: Bool { self == .docs || self == .tests || self == .mechanical }

    /// Shape as well as color, so tiers stay distinguishable without hue.
    var glyph: String {
        switch self {
        case .critical: "diamond.fill"
        case .behavior: "circle.fill"
        case .supporting: "circle"
        case .docs, .tests, .mechanical: "minus"
        }
    }

    static let important: [ChangeTier] = [.critical, .behavior, .supporting]
    static let lowSignal: [ChangeTier] = [.docs, .tests, .mechanical]
}

struct HunkAnalysis: Sendable, Codable {
    var tier: ChangeTier
    var reasons: [String]
    var enclosing: String?
    /// Keeps the hunk out of the Claude classification pass.
    var settled = false
    /// Where the deciding rule is defined, e.g. `defaults:42`.
    var rule: String?
    /// Semantic or `llm` conditions the first pass could not decide.
    var pending = RulePending()
}

/// Small Rust lexer for comparing hunks token-by-token. Comments and whitespace are dropped.
enum RustTokens {
    struct Tok: Hashable { var text: String; var isIdent: Bool; var isComment: Bool }

    static func lex(_ s: String) -> [Tok] {
        let c = Array(s.unicodeScalars)
        var i = 0
        var out: [Tok] = []
        func isIdStart(_ u: Unicode.Scalar) -> Bool { u == "_" || CharacterSet.letters.contains(u) }
        func isId(_ u: Unicode.Scalar) -> Bool { isIdStart(u) || CharacterSet.decimalDigits.contains(u) }
        let multi = ["::", "->", "=>", "==", "!=", "<=", ">=", "&&", "||", "+=", "-=", "*=", "/=", "..=", "...", "..", "<<", ">>"]
        while i < c.count {
            let u = c[i]
            if CharacterSet.whitespacesAndNewlines.contains(u) { i += 1; continue }
            if u == "/" && i + 1 < c.count && c[i + 1] == "/" {
                var j = i; while j < c.count && c[j] != "\n" { j += 1 }
                out.append(Tok(text: String(String.UnicodeScalarView(c[i..<j])), isIdent: false, isComment: true)); i = j; continue
            }
            if u == "/" && i + 1 < c.count && c[i + 1] == "*" {
                var j = i + 2; while j + 1 < c.count && !(c[j] == "*" && c[j + 1] == "/") { j += 1 }
                j = min(c.count, j + 2)
                out.append(Tok(text: String(String.UnicodeScalarView(c[i..<j])), isIdent: false, isComment: true)); i = j; continue
            }
            if u == "\"" {
                var j = i + 1
                while j < c.count && c[j] != "\"" { if c[j] == "\\" { j += 1 }; j += 1 }
                j = min(c.count, j + 1)
                out.append(Tok(text: String(String.UnicodeScalarView(c[i..<j])), isIdent: false, isComment: false)); i = j; continue
            }
            if isIdStart(u) {
                var j = i; while j < c.count && isId(c[j]) { j += 1 }
                out.append(Tok(text: String(String.UnicodeScalarView(c[i..<j])), isIdent: true, isComment: false)); i = j; continue
            }
            if CharacterSet.decimalDigits.contains(u) {
                var j = i; while j < c.count && (isId(c[j]) || c[j] == ".") { j += 1 }
                out.append(Tok(text: String(String.UnicodeScalarView(c[i..<j])), isIdent: false, isComment: false)); i = j; continue
            }
            var matched = false
            for m in multi {
                let ms = Array(m.unicodeScalars)
                if i + ms.count <= c.count && Array(c[i..<(i + ms.count)]) == ms {
                    out.append(Tok(text: m, isIdent: false, isComment: false)); i += ms.count; matched = true; break
                }
            }
            if matched { continue }
            out.append(Tok(text: String(u), isIdent: false, isComment: false)); i += 1
        }
        return out
    }

    static let keywords: Set<String> = ["fn", "let", "mut", "pub", "impl", "struct", "enum", "trait", "use", "mod", "match", "if",
        "else", "for", "while", "loop", "return", "async", "await", "move", "where", "type", "const", "static", "unsafe",
        "dyn", "crate", "super", "as", "in", "ref", "break", "continue", "true", "false", "Some", "None", "Ok", "Err"]
}

/// Classifies diff hunks by computing facts about each hunk and evaluating the review rules
/// (see `ReviewRule`). The built-in behaviour lives in `DefaultRules`; repositories and users layer
/// their own rule files on top.
enum ChangeClassifier {
    static func classify(file: FileDiff, hunk: Hunk, oldDoc: SourceDocument?, newDoc: SourceDocument?, root: URL? = nil) -> HunkAnalysis {
        analyze(file: file, hunk: hunk, oldDoc: oldDoc, newDoc: newDoc, root: root).analysis
    }

    /// The analysis plus the facts behind it, kept so the second pass can re-evaluate with answers.
    static func analyze(file: FileDiff, hunk: Hunk, oldDoc: SourceDocument?, newDoc: SourceDocument?, root: URL? = nil) -> (analysis: HunkAnalysis, facts: HunkFacts) {
        let rules = root.map { ReviewRules.shared.rules(for: $0) } ?? ReviewRules.shared.defaultsOnly
        let facts = Self.facts(file: file, hunk: hunk, oldDoc: oldDoc, newDoc: newDoc)
        return (evaluate(rules, facts, enclosing: enclosing(file: file, hunk: hunk, oldDoc: oldDoc, newDoc: newDoc)), facts)
    }

    static func evaluate(_ rules: RuleSet, _ facts: HunkFacts, enclosing: String?) -> HunkAnalysis {
        let outcome = rules.evaluate(facts)
        return HunkAnalysis(tier: outcome.tier, reasons: outcome.reasons, enclosing: enclosing,
                            settled: outcome.settled, rule: outcome.rule, pending: outcome.pending)
    }

    /// Names the hunk after the first changed line that sits inside an item, so a hunk that starts
    /// with import churn is still titled by the item it actually touches.
    static func enclosing(file: FileDiff, hunk: Hunk, oldDoc: SourceDocument?, newDoc: SourceDocument?) -> String? {
        hunk.added.lazy.compactMap { $0.newLine }.compactMap { newDoc?.syntax.enclosingItem(line: $0, strict: true)?.qualifiedName }.first
            ?? hunk.removed.lazy.compactMap { $0.oldLine }.compactMap { oldDoc?.syntax.enclosingItem(line: $0, strict: true)?.qualifiedName }.first
            ?? hunk.added.first?.newLine.flatMap { newDoc?.syntax.enclosingItem(line: $0)?.qualifiedName }
            ?? (FileClassifier.isGenerated(file.path) || hunk.header.isEmpty ? nil : headerName(hunk.header))
    }

    private static let declRE = try! NSRegularExpression(pattern: #"\b(?:def|class|fn|func|function|struct|enum|impl|trait|interface|type|message|service)\s+([A-Za-z_][\w.]*)"#)

    /// A diff hunk header (the enclosing line git shows) reduced to the declared name when it has one.
    static func headerName(_ header: String) -> String {
        let h = header.trimmingCharacters(in: .whitespaces)
        let ns = h as NSString
        if let m = declRE.firstMatch(in: h, range: NSRange(location: 0, length: ns.length)) {
            let kw = ns.substring(with: m.range).split(separator: " ").first.map(String.init) ?? ""
            return kw + " " + ns.substring(with: m.range(at: 1))
        }
        return h.trimmingCharacters(in: CharacterSet(charactersIn: "({:= "))
    }

    static func facts(file: FileDiff, hunk: Hunk, oldDoc: SourceDocument?, newDoc: SourceDocument?) -> HunkFacts {
        let path = file.path
        let lang = SourceLanguage.from(path: path)
        var langs: Set<String> = [lang.rawValue]
        if let g = GrammarRegistry.shared.grammar(forPath: path) { langs.insert(g.spec.name) }
        var kinds: Set<String> = [file.status.rawValue]
        if FileClassifier.isGenerated(path) { kinds.insert("generated") }
        if FileClassifier.isTest(path) { kinds.insert("test") }

        let addedText = hunk.added.map(\.text).joined(separator: "\n")
        let removedText = hunk.removed.map(\.text).joined(separator: "\n")
        let addedToks = RustTokens.lex(addedText)
        let removedToks = RustTokens.lex(removedText)
        let addedCode = addedToks.filter { !$0.isComment }
        let removedCode = removedToks.filter { !$0.isComment }
        let addedComments = addedToks.filter(\.isComment).map(\.text)
        let removedComments = removedToks.filter(\.isComment).map(\.text)
        let commentWords = wordDelta(addedComments, removedComments)

        var facts: Set<String> = []
        var publicName: String?
        var rename: String?
        // Token-level facts rely on the Rust lexer, so they only apply to Rust files.
        if lang == .rust {
            let addedInTest = hunk.added.allSatisfy { l in l.newLine.map { newDoc?.syntax.isTestLine($0) ?? false } ?? true }
            let removedInTest = hunk.removed.allSatisfy { l in l.oldLine.map { oldDoc?.syntax.isTestLine($0) ?? false } ?? true }
            if (!hunk.added.isEmpty || !hunk.removed.isEmpty) && addedInTest && removedInTest && (newDoc != nil || oldDoc != nil) {
                facts.insert("in-test")
            }
            if addedCode.map(\.text) == removedCode.map(\.text) {
                facts.insert(commentWords == 0 ? "formatting-only" : "comments-only")
            }
            if !addedComments.isEmpty && !removedComments.isEmpty { facts.insert("comment-edit") }

            let changed = (hunk.added + hunk.removed).map { $0.text.trimmingCharacters(in: .whitespaces) }.filter { !$0.isEmpty }
            let importLike = changed.allSatisfy { l in
                l.hasPrefix("use ") || l.hasPrefix("pub use ") || l.hasPrefix("pub(crate) use ") || l.hasPrefix("//")
                    || l.range(of: #"^[\w:{}, *]+[,};]*$"#, options: .regularExpression) != nil && !l.contains("(")
            }
            if importLike && changed.contains(where: { $0.contains("use ") }) { facts.insert("imports-only") }
            if !changed.isEmpty && changed.allSatisfy({ $0.hasPrefix("mod ") || $0.hasPrefix("pub mod ") || $0.hasPrefix("pub(crate) mod ") }) {
                facts.insert("mod-decls-only")
            }

            publicName = touchesPublicSignature(newDoc, hunk.added.compactMap(\.newLine)) ?? touchesPublicSignature(oldDoc, hunk.removed.compactMap(\.oldLine))
            if publicName != nil { facts.insert("public-signature") }
            rename = consistentRename(removedCode, addedCode, oldDoc: oldDoc, newDoc: newDoc)
            if rename != nil { facts.insert("rename") }

            var counts: [String: Int] = [:]
            for t in addedCode { counts[t.text, default: 0] += 1 }
            for t in removedCode { counts[t.text, default: 0] -= 1 }
            let net = counts.filter { $0.value != 0 }.map(\.key)
            let plumbingTokens: Set<String> = [",", ":", "&", ".", "clone", "(", ")", "self", "into", "Arc", "Rc", "<", ">", "{", "}", "::", "mut", "ref", "as_ref", "to_owned", "to_string"]
            let netIsPlumbing = !net.isEmpty && net.allSatisfy { tok in
                plumbingTokens.contains(tok) || (tok.first.map { $0.isLetter || $0 == "_" } == true && !RustTokens.keywords.contains(tok))
            }
            let structuralAdded: Set<String> = ["if", "match", "else", "for", "while", "loop", "return", "=>", "==", "!=", "<=", ">=", "&&", "||", "+", "-", "*", "/", "=", "let", "break", "continue"]
            let structuralRemoved: Set<String> = ["if", "match", "else", "for", "while", "loop", "return", "=>", "==", "!=", "&&", "||", "=", "let", "break", "continue"]
            let structural = addedCode.contains { structuralAdded.contains($0.text) } || removedCode.contains { structuralRemoved.contains($0.text) }
            if structural { facts.insert("structural") }
            if netIsPlumbing && !structural && max(hunk.addedCount, hunk.removedCount) <= 12 { facts.insert("plumbing") }
        }
        if hunk.removedCount == 0 && hunk.addedCount > 0 { facts.insert("additions-only") }
        if hunk.addedCount == 0 && hunk.removedCount > 0 { facts.insert("deletions-only") }

        let newLines = Set(hunk.added.compactMap(\.newLine))
        let oldLines = Set(hunk.removed.compactMap(\.oldLine))
        return HunkFacts(
            path: path, langs: langs, langDisplay: GrammarRegistry.shared.grammar(forPath: path)?.spec.displayName ?? lang.displayName,
            fileKinds: kinds, facts: facts,
            addedCode: compact(addedCode), removedCode: compact(removedCode),
            changedComments: (addedComments + removedComments).joined(separator: "\n"),
            changedText: addedText + "\n" + removedText,
            commentWords: commentWords, changedLines: hunk.addedCount + hunk.removedCount,
            publicName: publicName, rename: rename,
            tsMatches: { query in
                tsMatch(query, doc: newDoc, lines: newLines) || tsMatch(query, doc: oldDoc, lines: oldLines)
            })
    }

    /// Whether any match of `query` overlaps the changed lines of `doc`.
    static func tsMatch(_ query: String, doc: SourceDocument?, lines: Set<Int>) -> Bool {
        guard let doc, let first = lines.min(), let last = lines.max(), let parsed = doc.parsed, let root = parsed.tree.rootNode,
              let q = QueryCache.shared.query(query, language: parsed.language, key: parsed.key) else { return false }
        let start = doc.lines.lineRange(first).location
        let end = NSMaxRange(doc.lines.lineRange(last))
        let cursor = q.execute(node: root, in: parsed.tree)
        cursor.setRange(NSRange(location: start, length: max(0, end - start)))
        for match in cursor.resolve(with: SwiftTreeSitter.Predicate.Context(string: doc.text)) {
            for c in match.captures {
                let s = doc.lines.position(of: c.range.location).line
                let e = doc.lines.position(of: NSMaxRange(c.range)).line
                if lines.contains(where: { $0 >= s && $0 <= e }) { return true }
            }
        }
        return false
    }

    private static func touchesPublicSignature(_ doc: SourceDocument?, _ lines: [Int]) -> String? {
        guard let doc else { return nil }
        for l in lines {
            for item in doc.syntax.flatOutline where item.isPublic && item.kind != .impl && item.kind != .module
                && l >= item.range.start.line && l <= item.headerEndLine {
                return item.name
            }
            if let item = doc.syntax.enclosingItem(line: l, includeContainers: false), item.kind == .trait { return item.name }
        }
        return nil
    }

    /// Size of the multiset difference between the words of two comment sets.
    static func wordDelta(_ a: [String], _ b: [String]) -> Int {
        func words(_ xs: [String]) -> [String: Int] {
            var m: [String: Int] = [:]
            for x in xs {
                for w in x.split(whereSeparator: { !$0.isLetter && !$0.isNumber && $0 != "_" }) where !w.isEmpty { m[w.lowercased(), default: 0] += 1 }
            }
            return m
        }
        let wa = words(a), wb = words(b)
        return Set(wa.keys).union(wb.keys).reduce(0) { $0 + abs((wa[$1] ?? 0) - (wb[$1] ?? 0)) }
    }


    /// Compact code from tokens: comments are already gone and string contents are blanked, so prose
    /// cannot trigger code rules. Spaces only separate adjacent word tokens, so `x.unwrap()` stays intact.
    static func compact(_ toks: [RustTokens.Tok]) -> String {
        var code = ""
        var prevWord = false
        for t in toks {
            let word = t.isIdent || t.text.first?.isNumber == true
            if word && prevWord { code += " " }
            code += t.text.hasPrefix("\"") ? "\"\"" : t.text
            prevWord = word
        }
        return code
    }

    /// Same token stream modulo a consistent substitution of local-looking identifiers. A substitution
    /// counts as a rename only when it is complete: with file contents, the old name is gone from the new
    /// file and the new name was absent from the old file; without them, the hunk must contain a binding
    /// site (`let`, `fn`, parameter) for the renamed name.
    static func consistentRename(_ old: [RustTokens.Tok], _ new: [RustTokens.Tok], oldDoc: SourceDocument? = nil, newDoc: SourceDocument? = nil) -> String? {
        guard old.count == new.count, !old.isEmpty else { return nil }
        var map: [String: String] = [:]
        for (a, b) in zip(old, new) where a.text != b.text {
            guard a.isIdent, b.isIdent, isLocalName(a.text), isLocalName(b.text) else { return nil }
            if let m = map[a.text], m != b.text { return nil }
            map[a.text] = b.text
        }
        guard !map.isEmpty else { return nil }
        if let oldDoc, let newDoc {
            for (from, to) in map {
                if containsWord(newDoc.text, from) || containsWord(oldDoc.text, to) { return nil }
            }
        } else {
            let hasBinding = new.enumerated().contains { i, t in
                guard map.values.contains(t.text) else { return false }
                let prev = i > 0 ? new[i - 1].text : ""
                let next = i + 1 < new.count ? new[i + 1].text : ""
                return prev == "let" || prev == "fn" || prev == "mut" || (next == ":" && prev != ":")
            }
            if !hasBinding { return nil }
        }
        let shown = map.prefix(2).map { "\($0.key) → \($0.value)" }.joined(separator: ", ")
        return "rename \(shown)\(map.count > 2 ? " +\(map.count - 2)" : "")"
    }

    private static let primitives: Set<String> = ["u8", "u16", "u32", "u64", "u128", "usize", "i8", "i16", "i32", "i64", "i128", "isize",
        "f32", "f64", "bool", "char", "str", "self", "Self"]

    private static func isLocalName(_ s: String) -> Bool {
        guard let f = s.first, f.isLowercase || f == "_" else { return false }
        return !RustTokens.keywords.contains(s) && !primitives.contains(s)
    }

    private static func containsWord(_ text: String, _ word: String) -> Bool {
        text.range(of: "\\b\(NSRegularExpression.escapedPattern(for: word))\\b", options: .regularExpression) != nil
    }
}
