import Foundation

enum ChangeTier: String, Codable, CaseIterable, Identifiable, Comparable, Sendable {
    case critical, behavior, supporting, docs, tests, mechanical

    var id: String { rawValue }
    var rank: Int { ChangeTier.allCases.firstIndex(of: self)! }
    static func < (a: ChangeTier, b: ChangeTier) -> Bool { a.rank < b.rank }

    var title: String {
        switch self {
        case .critical: "Needs attention"
        case .behavior: "Behavior changes"
        case .supporting: "Supporting plumbing"
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

    var isLowSignal: Bool { self == .tests || self == .mechanical }
}

struct HunkAnalysis: Sendable {
    var tier: ChangeTier
    var reasons: [String]
    var enclosing: String?
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

/// Heuristic, Rust-aware classification of diff hunks. Uses full old/new file syntax when available.
enum ChangeClassifier {
    static func classify(file: FileDiff, hunk: Hunk, oldDoc: SourceDocument?, newDoc: SourceDocument?) -> HunkAnalysis {
        let path = file.path
        // Name the hunk after the first changed line that sits inside an item, so a hunk that starts
        // with import churn is still titled by the item it actually touches.
        let enclosing = hunk.added.lazy.compactMap { $0.newLine }.compactMap { newDoc?.syntax.enclosingItem(line: $0, strict: true)?.qualifiedName }.first
            ?? hunk.removed.lazy.compactMap { $0.oldLine }.compactMap { oldDoc?.syntax.enclosingItem(line: $0, strict: true)?.qualifiedName }.first
            ?? hunk.added.first?.newLine.flatMap { newDoc?.syntax.enclosingItem(line: $0)?.qualifiedName }
            ?? (FileClassifier.isGenerated(file.path) || hunk.header.isEmpty ? nil : hunk.header)
        func result(_ t: ChangeTier, _ r: String...) -> HunkAnalysis { HunkAnalysis(tier: t, reasons: r, enclosing: enclosing) }

        if FileClassifier.isGenerated(path) {
            return result(.mechanical, path.hasSuffix(".lock") || path.hasSuffix("lock.json") ? "lockfile" : "generated or snapshot")
        }
        let lang = SourceLanguage.from(path: path)
        if lang == .markdown { return result(.docs, file.status == .added ? "new document" : "documentation") }
        if FileClassifier.isTest(path) { return result(.tests, "test file") }
        if path.lastPathComponent == "Cargo.toml" {
            let changed = (hunk.added + hunk.removed).map(\.text).joined(separator: "\n")
            if changed.contains("features") || changed.contains("[dependencies") || changed.range(of: #"^\s*[\w-]+\s*=\s*(\{|")"#, options: .regularExpression) != nil {
                return result(.supporting, "dependency or feature change")
            }
            return result(.supporting, "manifest change")
        }
        guard lang == .rust else {
            return HunkAnalysis(tier: .behavior, reasons: ["\(lang.displayName) change"], enclosing: enclosing)
        }

        let addedText = hunk.added.map(\.text).joined(separator: "\n")
        let removedText = hunk.removed.map(\.text).joined(separator: "\n")
        let addedToks = RustTokens.lex(addedText)
        let removedToks = RustTokens.lex(removedText)
        let addedCode = addedToks.filter { !$0.isComment }
        let removedCode = removedToks.filter { !$0.isComment }

        // Test regions inside the file.
        let addedInTest = hunk.added.allSatisfy { l in l.newLine.map { newDoc?.syntax.isTestLine($0) ?? false } ?? true }
        let removedInTest = hunk.removed.allSatisfy { l in l.oldLine.map { oldDoc?.syntax.isTestLine($0) ?? false } ?? true }
        if (!hunk.added.isEmpty || !hunk.removed.isEmpty) && addedInTest && removedInTest
            && (newDoc != nil || oldDoc != nil) {
            return result(.tests, "inside #[cfg(test)] / #[test]")
        }

        let addedComments = addedToks.filter(\.isComment).map(\.text)
        let removedComments = removedToks.filter(\.isComment).map(\.text)
        let commentWordsChanged = Self.wordDelta(addedComments, removedComments)
        if addedCode.map(\.text) == removedCode.map(\.text) {
            if commentWordsChanged == 0 { return result(.mechanical, "formatting only") }
            if (addedComments + removedComments).contains(where: Self.isInvariantComment) {
                return result(.critical, "safety / invariant comment changed")
            }
            let isDoc = (addedComments + removedComments).contains { $0.hasPrefix("///") || $0.hasPrefix("//!") || $0.hasPrefix("/**") }
            // A few words reworded in existing comments is a typo fix; anything more is content.
            if commentWordsChanged <= 3 && !removedComments.isEmpty && !addedComments.isEmpty {
                return result(.mechanical, "comment wording")
            }
            return result(.docs, isDoc ? "doc comments" : "comments")
        }

        let changedLines = (hunk.added + hunk.removed).map { $0.text.trimmingCharacters(in: .whitespaces) }.filter { !$0.isEmpty }
        let importLike = changedLines.allSatisfy { l in
            l.hasPrefix("use ") || l.hasPrefix("pub use ") || l.hasPrefix("pub(crate) use ") || l.hasPrefix("//")
                || l.range(of: #"^[\w:{}, *]+[,};]*$"#, options: .regularExpression) != nil && !l.contains("(")
        }
        if importLike && changedLines.contains(where: { $0.contains("use ") }) { return result(.mechanical, "imports") }
        if changedLines.allSatisfy({ $0.hasPrefix("mod ") || $0.hasPrefix("pub mod ") || $0.hasPrefix("pub(crate) mod ") }) {
            return result(.supporting, "module declarations")
        }

        var reasons: [String] = []
        var critical = false
        func delta(_ pattern: String) -> Int {
            count(pattern, addedCode, addedText) - count(pattern, removedCode, removedText)
        }
        func touched(_ pattern: String) -> Bool { count(pattern, addedCode, addedText) + count(pattern, removedCode, removedText) > 0 }

        if touched(#"\bunsafe\b"#) { critical = true; reasons.append("unsafe code") }
        if touched(#"Ordering::|Atomic\w+|\bfence\("#) { critical = true; reasons.append("atomics / memory ordering") }
        if touched(#"\bMutex\b|\bRwLock\b|\.lock\(\)|Condvar|\bSemaphore\b"#) { critical = true; reasons.append("locking") }
        if touched(#"\bspawn\w*\(|\bselect!|\bjoin!|mpsc::|oneshot::|broadcast::|watch::"#) { critical = true; reasons.append("concurrency / channels") }
        let panicDelta = delta(#"\.unwrap\(\)|\.expect\(|panic!|unreachable!|todo!|unimplemented!|assert!|\[[^\]]+\]"#)
        if delta(#"\.unwrap\(\)|\.expect\(|panic!|unreachable!|todo!|unimplemented!"#) > 0 { critical = true; reasons.append("adds panic path") }
        else if panicDelta < 0 && delta(#"\?"#) > 0 { reasons.append("panic replaced with error") }
        if delta(#"\?"#) < 0 { reasons.append("error propagation removed") }
        if touched(#"#\[serde|Serialize|Deserialize|\bproto\b|prost::|#\[derive\([^)]*(Serialize|Arbitrary)"#) { critical = true; reasons.append("serialization format") }
        if touched(#"impl\s+Drop\b|unsafe\s+impl\s+(Send|Sync)"#) { critical = true; reasons.append("Drop / Send / Sync") }

        // Public API: the hunk touches the signature lines of a pub item.
        func touchesPublicSignature(_ doc: SourceDocument?, _ lines: [Int]) -> String? {
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
        if let name = touchesPublicSignature(newDoc, hunk.added.compactMap(\.newLine))
            ?? touchesPublicSignature(oldDoc, hunk.removed.compactMap(\.oldLine)) {
            critical = true
            reasons.append("public API: \(name)")
        }
        if commentWordsChanged > 3 { reasons.append("also edits comments") }
        if critical { return HunkAnalysis(tier: .critical, reasons: reasons, enclosing: enclosing) }

        if let rename = consistentRename(removedCode, addedCode, oldDoc: oldDoc, newDoc: newDoc) { return result(.mechanical, rename) }

        // Plumbing: the net token change is only identifiers threaded through calls/struct literals.
        var counts: [String: Int] = [:]
        for t in addedCode { counts[t.text, default: 0] += 1 }
        for t in removedCode { counts[t.text, default: 0] -= 1 }
        let net = counts.filter { $0.value != 0 }.map(\.key)
        let plumbingTokens: Set<String> = [",", ":", "&", ".", "clone", "(", ")", "self", "into", "Arc", "Rc", "<", ">", "{", "}", "::", "mut", "ref", "as_ref", "to_owned", "to_string"]
        let netIsPlumbing = !net.isEmpty && net.allSatisfy { tok in
            plumbingTokens.contains(tok) || (tok.first.map { $0.isLetter || $0 == "_" } == true && !RustTokens.keywords.contains(tok))
        }
        let structural = addedCode.contains { ["if", "match", "else", "for", "while", "loop", "return", "=>", "==", "!=", "<=", ">=", "&&", "||", "+", "-", "*", "/", "=", "let", "break", "continue"].contains($0.text) }
            || removedCode.contains { ["if", "match", "else", "for", "while", "loop", "return", "=>", "==", "!=", "&&", "||", "=", "let", "break", "continue"].contains($0.text) }
        if netIsPlumbing && !structural && max(hunk.addedCount, hunk.removedCount) <= 12 {
            return HunkAnalysis(tier: .supporting, reasons: reasons + ["threads values through"], enclosing: enclosing)
        }
        if structural { reasons.append(hunk.removedCount == 0 ? "new logic" : "control flow / logic") }
        if reasons.isEmpty { reasons.append(hunk.removedCount == 0 ? "added code" : hunk.addedCount == 0 ? "removed code" : "code change") }
        return HunkAnalysis(tier: .behavior, reasons: reasons, enclosing: enclosing)
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

    /// Comments that document an obligation rather than describe code.
    static func isInvariantComment(_ c: String) -> Bool {
        c.range(of: #"SAFETY|INVARIANT|#\s*(Safety|Panics)|\bunsafe\b|\bmust (not|never|always|only)\b|\bnever\b.*\b(called|held|null|empty)"#,
                options: [.regularExpression]) != nil
    }

    private static func count(_ pattern: String, _ toks: [RustTokens.Tok], _ text: String) -> Int {
        // Rebuild compact code from tokens: comments are already gone and string contents are blanked,
        // so prose cannot trigger signals. Spaces only separate adjacent word tokens.
        var code = ""
        var prevWord = false
        for t in toks {
            let word = t.isIdent || t.text.first?.isNumber == true
            if word && prevWord { code += " " }
            code += t.text.hasPrefix("\"") ? "\"\"" : t.text
            prevWord = word
        }
        guard let re = try? NSRegularExpression(pattern: pattern) else { return 0 }
        return re.numberOfMatches(in: code, range: NSRange(location: 0, length: (code as NSString).length))
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
