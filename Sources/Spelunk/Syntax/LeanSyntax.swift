import Foundation

/// Highlighting and outline for Lean 4 from a hand-written lexer. An installed tree-sitter grammar
/// for `.lean` takes precedence.
enum LeanSyntax {
    static let keywords: Set<String> = [
        "def", "theorem", "lemma", "abbrev", "instance", "structure", "class", "inductive", "coinductive", "where",
        "extends", "deriving", "namespace", "section", "end", "open", "import", "export", "variable", "universe",
        "axiom", "opaque", "noncomputable", "partial", "unsafe", "private", "protected", "public", "nonrec", "mutual",
        "example", "fun", "let", "have", "show", "from", "by", "do", "if", "then", "else", "match", "with", "at",
        "calc", "return", "for", "in", "unless", "mut", "termination_by", "decreasing_by", "local", "scoped",
        "macro", "syntax", "macro_rules", "notation", "infix", "infixl", "infixr", "prefix", "postfix", "elab",
        "set_option", "attribute", "suffices", "obtain", "using", "nomatch", "nofun", "forall", "exists", "try",
        "catch", "finally", "break", "continue", "initialize", "builtin_initialize", "omit", "include",
    ]

    static let tactics: Set<String> = [
        "simp", "simp_all", "dsimp", "simpa", "rw", "rwa", "erw", "exact", "exact?", "apply", "refine", "intro",
        "intros", "rintro", "cases", "rcases", "induction", "constructor", "omega", "decide", "native_decide", "rfl",
        "unfold", "split", "contradiction", "exfalso", "assumption", "trivial", "linarith", "nlinarith", "norm_num",
        "ring", "aesop", "subst", "injection", "specialize", "generalize", "revert", "clear", "exists", "use",
        "left", "right", "funext", "ext", "congr", "calc", "conv", "show_term", "sorry", "admit", "next", "case",
        "all_goals", "any_goals", "first", "repeat", "iterate", "focus", "refine'", "change", "replace", "symm",
        "trans", "absurd", "by_cases", "by_contra", "push_neg", "positivity", "gcongr", "bv_decide", "grind",
    ]

    static let constants: Set<String> = ["true", "false", "True", "False"]
    static let sorts: Set<String> = ["Type", "Prop", "Sort"]

    /// Commands that declare a named item, with the item's outline kind.
    static let declarations: [String: OutlineKind] = [
        "def": .function, "abbrev": .function, "opaque": .constant, "theorem": .theorem, "lemma": .theorem,
        "axiom": .theorem, "structure": .structItem, "class": .classItem, "inductive": .enumItem,
        "coinductive": .enumItem, "instance": .impl,
    ]
    static let modifiers: Set<String> = ["private", "protected", "public", "noncomputable", "partial", "unsafe", "nonrec", "scoped", "local"]
    /// Words that begin a command; one at or left of an open declaration's column ends it.
    static let commands: Set<String> = Set(declarations.keys).union(modifiers).union([
        "namespace", "section", "end", "open", "import", "export", "variable", "universe", "set_option", "attribute",
        "example", "mutual", "macro", "syntax", "macro_rules", "notation", "infix", "infixl", "infixr", "prefix",
        "postfix", "elab", "initialize", "builtin_initialize", "omit", "include",
    ])

    private struct Lexeme {
        enum Kind { case word, doc, attribute, punct, literal }
        var kind: Kind
        var range: NSRange
        var text: String
    }

    static func analyze(_ text: String) -> SyntaxInfo {
        let ns = text as NSString
        let n = ns.length
        var buf = [unichar](repeating: 0, count: n)
        ns.getCharacters(&buf, range: NSRange(location: 0, length: n))
        func at(_ i: Int) -> unichar { i < n ? buf[i] : 0 }

        var tokens: [Token] = []
        var lexemes: [Lexeme] = []
        var i = 0
        while i < n {
            let c = buf[i]
            let start = i
            if c == 32 || c == 9 || c == 10 || c == 13 { i += 1; continue }
            // Line comment.
            if c == 0x2D, at(i + 1) == 0x2D {
                while i < n, buf[i] != 10 { i += 1 }
                tokens.append(Token(range: NSRange(location: start, length: i - start), kind: .comment))
                continue
            }
            // Block comments nest; `/--` and `/-!` are documentation.
            if c == 0x2F, at(i + 1) == 0x2D {
                let doc = (at(i + 2) == 0x2D || at(i + 2) == 0x21) && at(i + 3) != 0x2F
                var depth = 1
                i += 2
                while i < n, depth > 0 {
                    if buf[i] == 0x2F, at(i + 1) == 0x2D { depth += 1; i += 2 }
                    else if buf[i] == 0x2D, at(i + 1) == 0x2F { depth -= 1; i += 2 }
                    else { i += 1 }
                }
                let r = NSRange(location: start, length: i - start)
                tokens.append(Token(range: r, kind: doc ? .docComment : .comment))
                if doc { lexemes.append(Lexeme(kind: .doc, range: r, text: "")) }
                continue
            }
            if c == 0x22 {
                i += 1
                while i < n, buf[i] != 0x22 { i += buf[i] == 0x5C ? 2 : 1 }
                i = min(i + 1, n)
                let r = NSRange(location: start, length: i - start)
                tokens.append(Token(range: r, kind: .string))
                lexemes.append(Lexeme(kind: .literal, range: r, text: ""))
                continue
            }
            // A character literal, told apart from a primed name such as `h'`.
            if c == 0x27, !(start > 0 && isIdentRest(buf[start - 1])) {
                var j = i + 1
                if at(j) == 0x5C { j += 2; while j < n, j < i + 12, buf[j] != 0x27 { j += 1 } } else { j += 1 }
                if at(j) == 0x27 {
                    i = j + 1
                    tokens.append(Token(range: NSRange(location: start, length: i - start), kind: .string))
                    continue
                }
            }
            if isDigit(c) {
                i += 1
                while i < n, isDigit(buf[i]) || isASCIILetter(buf[i]) || buf[i] == 0x5F || (buf[i] == 0x2E && isDigit(at(i + 1))) { i += 1 }
                let r = NSRange(location: start, length: i - start)
                tokens.append(Token(range: r, kind: .number))
                lexemes.append(Lexeme(kind: .literal, range: r, text: ""))
                continue
            }
            // `@[attr, ...]`, brackets balanced.
            if c == 0x40, at(i + 1) == 0x5B {
                var depth = 0
                while i < n {
                    if buf[i] == 0x5B { depth += 1 } else if buf[i] == 0x5D { depth -= 1; if depth == 0 { i += 1; break } }
                    i += 1
                }
                let r = NSRange(location: start, length: i - start)
                tokens.append(Token(range: r, kind: .attribute))
                lexemes.append(Lexeme(kind: .attribute, range: r, text: ""))
                continue
            }
            // `#check`, `#eval` and the other hash commands.
            if c == 0x23, isASCIILetter(at(i + 1)) {
                i += 1
                while i < n, isIdentRest(buf[i]) { i += 1 }
                let r = NSRange(location: start, length: i - start)
                tokens.append(Token(range: r, kind: .keyword))
                lexemes.append(Lexeme(kind: .word, range: r, text: ns.substring(with: r)))
                continue
            }
            if isIdentStart(c) || c == 0xAB {
                // A dotted name, each part plain or «quoted».
                var lastPart = i
                while i < n {
                    lastPart = i
                    if buf[i] == 0xAB {
                        while i < n, buf[i] != 0xBB { i += 1 }
                        i = min(i + 1, n)
                    } else {
                        i += 1
                        while i < n, isIdentRest(buf[i]) { i += 1 }
                    }
                    guard at(i) == 0x2E, isIdentStart(at(i + 1)) || at(i + 1) == 0xAB else { break }
                    i += 1
                }
                let r = NSRange(location: start, length: i - start)
                let word = ns.substring(with: r)
                let prev = lexemes.last.flatMap { $0.kind == .word ? $0.text : nil }
                let kind: TokenKind?
                if keywords.contains(word) {
                    kind = .keyword
                } else if let prev, let k = declarations[prev] {
                    kind = [.structItem, .classItem, .enumItem].contains(k) ? .type : .function
                } else if prev == "namespace" || prev == "open" || prev == "import" || prev == "end" {
                    kind = .module
                } else if tactics.contains(word) {
                    kind = .macro
                } else if constants.contains(word) {
                    kind = .constant
                } else if sorts.contains(word) || isUppercase(buf[lastPart] == 0xAB ? at(lastPart + 1) : buf[lastPart]) {
                    kind = .type
                } else {
                    kind = nil
                }
                if let kind { tokens.append(Token(range: r, kind: kind)) }
                lexemes.append(Lexeme(kind: .word, range: r, text: word))
                continue
            }
            // Binders written as symbols.
            if c == 0x3BB || c == 0x2200 || c == 0x2203 || c == 0x3A0 || c == 0x3A3 {
                i += 1
                tokens.append(Token(range: NSRange(location: start, length: 1), kind: .keyword))
                lexemes.append(Lexeme(kind: .word, range: NSRange(location: start, length: 1), text: String(utf16CodeUnits: [c], count: 1)))
                continue
            }
            if c == 0x3A, at(i + 1) == 0x3D {
                i += 2
                let r = NSRange(location: start, length: 2)
                tokens.append(Token(range: r, kind: .operatorToken))
                lexemes.append(Lexeme(kind: .punct, range: r, text: ":="))
                continue
            }
            if c == 0x3D, at(i + 1) == 0x3E {
                i += 2
                tokens.append(Token(range: NSRange(location: start, length: 2), kind: .operatorToken))
                lexemes.append(Lexeme(kind: .punct, range: NSRange(location: start, length: 2), text: "=>"))
                continue
            }
            i += 1
            if [0x2192, 0x2190, 0x2194, 0x2227, 0x2228, 0xAC, 0x2264, 0x2265, 0x2260, 0x2208, 0x2209, 0x2286, 0x222A, 0x2229, 0xD7, 0x2218].contains(c) {
                tokens.append(Token(range: NSRange(location: start, length: 1), kind: .operatorToken))
            }
            lexemes.append(Lexeme(kind: .punct, range: NSRange(location: start, length: 1), text: String(utf16CodeUnits: [c], count: 1)))
        }

        var info = SyntaxInfo()
        info.tokens = tokens
        info.outline = outline(lexemes, ns: ns)
        return info
    }

    /// Declarations end where the next command starts at or left of their column, or at `end`.
    /// `namespace` and `section` hold the declarations up to their `end`.
    private static func outline(_ lexemes: [Lexeme], ns: NSString) -> [OutlineItem] {
        let index = LineIndex(ns)
        func pos(_ offset: Int) -> SourcePos { index.position(of: offset) }
        func srange(_ r: NSRange) -> SourceRange { SourceRange(start: pos(r.location), end: pos(NSMaxRange(r))) }

        final class Container { var item: OutlineItem?; var children: [OutlineItem] = []; init(_ item: OutlineItem?) { self.item = item } }
        let roots = Container(nil)
        var containers: [Container] = []
        var open: (item: OutlineItem, column: Int, headerFound: Bool)?
        var pendingStart: SourcePos?
        var pendingPrivate = false
        var lastLine = 0
        var previousLine = -1

        func current() -> Container { containers.last ?? roots }
        func closeDeclaration() {
            guard let o = open else { return }
            o.item.range.end = SourcePos(line: max(lastLine, o.item.range.start.line), col: 0)
            if !o.headerFound { o.item.headerEndLine = o.item.range.end.line }
            current().children.append(o.item)
            open = nil
        }
        func closeContainer(at line: Int) {
            guard let c = containers.popLast() else { return }
            if let item = c.item {
                item.range.end = SourcePos(line: line, col: 0)
                item.children = c.children
                for child in c.children { child.parent = item }
                current().children.append(item)
            } else {
                current().children.append(contentsOf: c.children)
            }
        }

        var k = 0
        while k < lexemes.count {
            let lx = lexemes[k]
            let start = pos(lx.range.location)
            let isHead = start.line != previousLine
            previousLine = start.line
            defer { lastLine = pos(max(NSMaxRange(lx.range) - 1, lx.range.location)).line; k += 1 }

            if let o = open, !o.headerFound, lx.kind == .punct ? (lx.text == ":=" || lx.text == "|") : lx.text == "where" {
                open!.headerFound = true
                o.item.headerEndLine = start.line
            }
            let prevWord = k > 0 && lexemes[k - 1].kind == .word ? lexemes[k - 1].text : nil
            let afterModifier = k > 0 && (lexemes[k - 1].kind == .attribute || prevWord.map(modifiers.contains) == true)
            let startsCommand = lx.kind == .doc || lx.kind == .attribute || (lx.kind == .word && (commands.contains(lx.text) || lx.text.hasPrefix("#")))
            guard isHead && startsCommand && (open == nil || start.col <= open!.column) || afterModifier && lx.kind == .word && (declarations[lx.text] != nil || modifiers.contains(lx.text)) else { continue }

            if isHead { closeDeclaration(); pendingStart = nil; pendingPrivate = false }
            if lx.kind == .attribute || (lx.kind == .word && modifiers.contains(lx.text)) {
                if pendingStart == nil { pendingStart = start }
                if lx.text == "private" { pendingPrivate = true }
                continue
            }
            guard lx.kind == .word else { continue }
            switch lx.text {
            case "namespace", "section":
                let next = k + 1 < lexemes.count && lexemes[k + 1].kind == .word && pos(lexemes[k + 1].range.location).line == start.line ? lexemes[k + 1] : nil
                let name = next?.text ?? lx.text
                let nameRange = next.map { srange($0.range) } ?? srange(lx.range)
                containers.append(Container(OutlineItem(name: name, kind: .module, range: SourceRange(start: start, end: start), nameRange: nameRange,
                                                        headerEndLine: start.line, detail: "\(lx.text) \(name)", isTest: false, isPublic: true)))
            case "mutual":
                containers.append(Container(nil))
            case "end":
                closeContainer(at: start.line)
            default:
                guard var kind = declarations[lx.text] else { continue }
                var nameIndex = k + 1
                if lx.text == "class", nameIndex < lexemes.count, ["inductive", "abbrev"].contains(lexemes[nameIndex].text) {
                    kind = lexemes[nameIndex].text == "inductive" ? .enumItem : .classItem
                    nameIndex += 1
                }
                let declStart = pendingStart ?? start
                let line = ns.substring(with: index.lineRange(start.line)).trimmingCharacters(in: .whitespacesAndNewlines)
                var name: String
                var nameRange: SourceRange
                if nameIndex < lexemes.count, lexemes[nameIndex].kind == .word, !keywords.contains(lexemes[nameIndex].text) {
                    name = lexemes[nameIndex].text
                    nameRange = srange(lexemes[nameIndex].range)
                } else {
                    // An anonymous instance is named by the class it implements.
                    let from = NSMaxRange(lexemes[nameIndex - 1].range)
                    var to = from
                    var j = nameIndex
                    while j < lexemes.count, lexemes[j].text != ":=", lexemes[j].text != "where", pos(lexemes[j].range.location).line == start.line {
                        to = NSMaxRange(lexemes[j].range); j += 1
                    }
                    name = ns.substring(with: NSRange(location: from, length: to - from))
                        .trimmingCharacters(in: CharacterSet.whitespaces.union(CharacterSet(charactersIn: ":")))
                        .components(separatedBy: .whitespaces).filter { !$0.isEmpty }.joined(separator: " ")
                    if name.isEmpty { name = lx.text }
                    nameRange = srange(lx.range)
                }
                let item = OutlineItem(name: name, kind: kind, range: SourceRange(start: declStart, end: declStart), nameRange: nameRange,
                                       headerEndLine: start.line, detail: line, isTest: false, isPublic: !pendingPrivate)
                open = (item, leadingSpaces(ns, index.lineRange(declStart.line)), false)
                pendingStart = nil
                pendingPrivate = false
            }
        }
        closeDeclaration()
        while !containers.isEmpty { closeContainer(at: lastLine) }
        return roots.children
    }

    private static func leadingSpaces(_ ns: NSString, _ r: NSRange) -> Int {
        var i = r.location
        while i < NSMaxRange(r), ns.character(at: i) == 32 || ns.character(at: i) == 9 { i += 1 }
        return i - r.location
    }

    private static func isDigit(_ c: unichar) -> Bool { c >= 0x30 && c <= 0x39 }
    private static func isASCIILetter(_ c: unichar) -> Bool { (c >= 0x41 && c <= 0x5A) || (c >= 0x61 && c <= 0x7A) }
    private static func isUppercase(_ c: unichar) -> Bool {
        (c >= 0x41 && c <= 0x5A) || (c >= 0x80 && UnicodeScalar(c).map { CharacterSet.uppercaseLetters.contains($0) } == true)
    }

    private static func isIdentStart(_ c: unichar) -> Bool {
        if isASCIILetter(c) || c == 0x5F { return true }
        guard c >= 0x80 else { return false }
        // λ, Π and Σ are binders, not letters, in Lean.
        if c == 0x3BB || c == 0x3A0 || c == 0x3A3 { return false }
        if UTF16.isLeadSurrogate(c) || UTF16.isTrailSurrogate(c) { return true }
        return UnicodeScalar(c).map { CharacterSet.letters.contains($0) } == true
    }

    private static func isIdentRest(_ c: unichar) -> Bool {
        isIdentStart(c) || isDigit(c) || c == 0x27 || c == 0x21 || c == 0x3F
            || (c >= 0x2080 && c <= 0x209C) || (c >= 0x1D62 && c <= 0x1D6A)
    }
}
