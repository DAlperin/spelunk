import Foundation
import SwiftTreeSitter
import TreeSitterRust

enum TokenKind: String, Sendable, CaseIterable {
    case keyword, type, function, macro, string, number, comment, docComment, attribute, lifetime,
         field, constant, module, selfKeyword, operatorToken, plain
}

struct Token: Sendable {
    var range: NSRange
    var kind: TokenKind
}

enum OutlineKind: String, Codable, Sendable {
    case function, method, theorem, structItem, enumItem, union, trait, impl, module, macro, constant, staticItem, typeAlias, classItem, interface

    var symbolGlyph: String {
        switch self {
        case .function, .method: "f(x)"
        case .theorem: "⊢"
        case .structItem, .union: "S"
        case .enumItem: "E"
        case .trait: "T"
        case .impl: "I"
        case .module: "M"
        case .macro: "!"
        case .constant, .staticItem: "C"
        case .typeAlias: "τ"
        case .classItem: "C"
        case .interface: "I"
        }
    }

    var label: String {
        switch self {
        case .function: "Function"
        case .method: "Method"
        case .theorem: "Theorem"
        case .structItem: "Struct"
        case .union: "Union"
        case .enumItem: "Enum"
        case .trait: "Trait"
        case .impl: "Impl"
        case .module: "Module"
        case .macro: "Macro"
        case .constant: "Constant"
        case .staticItem: "Static"
        case .typeAlias: "Type Alias"
        case .classItem: "Class"
        case .interface: "Interface"
        }
    }
}

final class OutlineItem: Identifiable, @unchecked Sendable {
    let id = UUID()
    var name: String
    var kind: OutlineKind
    var range: SourceRange
    var nameRange: SourceRange
    /// End of the item's signature: the line before the body opens, or the whole item when it has no body.
    var headerEndLine: Int
    var detail: String
    var isTest: Bool
    var isPublic: Bool
    var children: [OutlineItem] = []
    weak var parent: OutlineItem?

    init(name: String, kind: OutlineKind, range: SourceRange, nameRange: SourceRange, headerEndLine: Int,
         detail: String, isTest: Bool, isPublic: Bool) {
        self.name = name; self.kind = kind; self.range = range; self.nameRange = nameRange
        self.headerEndLine = headerEndLine; self.detail = detail; self.isTest = isTest; self.isPublic = isPublic
    }

    var lineCount: Int { range.end.line - range.start.line + 1 }

    /// `Type::method` for methods, the bare name otherwise.
    var qualifiedName: String {
        if kind == .method, let p = parent, p.kind == .impl || p.kind == .trait {
            return "\(p.selfTypeName)::\(name)"
        }
        return name
    }

    /// For impls, the implementing type; otherwise the name.
    var selfTypeName: String { kind == .impl ? name : name }
}

struct SyntaxInfo: Sendable {
    var tokens: [Token] = []
    var outline: [OutlineItem] = [] {
        didSet {
            var out: [OutlineItem] = []
            func walk(_ items: [OutlineItem]) { for i in items { out.append(i); walk(i.children) } }
            walk(outline)
            flatOutline = out
        }
    }
    var testLineRanges: [ClosedRange<Int>] = []
    var errorCount: Int = 0
    var parsedWithTreeSitter = false

    /// Every outline item, parents before their children.
    private(set) var flatOutline: [OutlineItem] = []

    /// Innermost item (excluding impls/modules unless nothing else matches) containing `line`.
    func enclosingItem(line: Int, strict: Bool) -> OutlineItem? {
        guard strict else { return enclosingItem(line: line) }
        var best: OutlineItem?
        func walk(_ items: [OutlineItem]) {
            for i in items where i.range.start.line <= line && line <= i.range.end.line {
                if i.kind != .impl && i.kind != .module { best = i }
                walk(i.children)
            }
        }
        walk(outline)
        return best
    }

    func enclosingItem(line: Int, includeContainers: Bool = false) -> OutlineItem? {
        var best: OutlineItem?
        func walk(_ items: [OutlineItem]) {
            for i in items where i.range.start.line <= line && line <= i.range.end.line {
                if includeContainers || (i.kind != .impl && i.kind != .module) { best = i }
                walk(i.children)
            }
        }
        walk(outline)
        if best == nil && !includeContainers { return enclosingItem(line: line, includeContainers: true) }
        return best
    }

    func isTestLine(_ line: Int) -> Bool { testLineRanges.contains { $0.contains(line) } }

    func commentOrWhitespaceOnly(lineRange: NSRange, in text: NSString) -> Bool {
        let commentRanges = tokens.filter { $0.kind == .comment || $0.kind == .docComment }.map(\.range)
        var i = lineRange.location
        let end = NSMaxRange(lineRange)
        while i < end {
            let c = text.character(at: i)
            if c == 32 || c == 9 || c == 10 || c == 13 { i += 1; continue }
            if let r = commentRanges.first(where: { NSLocationInRange(i, $0) }) { i = NSMaxRange(r); continue }
            return false
        }
        return true
    }
}

struct ParsedTree {
    var tree: MutableTree
    var language: SwiftTreeSitter.Language
    /// Grammar identity, for caching compiled queries per language.
    var key: String
}

enum SyntaxAnalyzer {
    static func parseTree(_ text: String, language: SourceLanguage, path: String) -> ParsedTree? {
        let lang: SwiftTreeSitter.Language
        let key: String
        if language == .rust {
            lang = SwiftTreeSitter.Language(language: tree_sitter_rust())
            key = "rust"
        } else if let g = GrammarRegistry.shared.grammar(forPath: path), let l = g.language {
            lang = l
            key = g.spec.name
        } else {
            return nil
        }
        let parser = Parser()
        parser.timeout = GrammarProbe.parseTimeout
        guard (try? parser.setLanguage(lang)) != nil, let tree = parser.parse(text) else { return nil }
        return ParsedTree(tree: tree, language: lang, key: key)
    }

    /// Rust uses the built-in grammar; other languages use an installed grammar when one claims the
    /// file's extension, and the regex lexer otherwise.
    static func analyze(_ text: String, language: SourceLanguage, path: String) -> SyntaxInfo {
        if language != .rust, let g = GrammarRegistry.shared.grammar(forPath: path),
           let info = DynamicSyntax.analyze(text, grammar: g) {
            return info
        }
        return analyze(text, language: language)
    }

    static func analyze(_ text: String, language: SourceLanguage) -> SyntaxInfo {
        switch language {
        case .rust: return RustSyntax.analyze(text)
        case .lean: return LeanSyntax.analyze(text)
        default: return GenericLexer.analyze(text, language: language)
        }
    }
}

enum RustSyntax {
    private static let keywords: Set<String> = [
        "as", "async", "await", "break", "const", "continue", "crate", "dyn", "else", "enum", "extern", "false",
        "fn", "for", "if", "impl", "in", "let", "loop", "match", "mod", "move", "mut", "pub", "ref", "return",
        "static", "struct", "super", "trait", "true", "type", "union", "unsafe", "use", "where", "while", "yield",
        "default", "gen", "macro_rules!",
    ]

    static func analyze(_ text: String) -> SyntaxInfo {
        let parser = Parser()
        guard (try? parser.setLanguage(Language(language: tree_sitter_rust()))) != nil,
              let tree = parser.parse(text), let root = tree.rootNode else {
            return GenericLexer.analyze(text, language: .rust)
        }
        let ns = text as NSString
        let index = LineIndex(ns)
        var info = SyntaxInfo()
        info.parsedWithTreeSitter = true
        var tokens: [Token] = []
        tokens.reserveCapacity(ns.length / 4)

        func str(_ n: Node) -> String { ns.substring(with: n.range) }
        func pos(_ offset: Int) -> SourcePos { index.position(of: offset) }
        func srange(_ r: NSRange) -> SourceRange { SourceRange(start: pos(r.location), end: pos(NSMaxRange(r))) }

        let cursor = root.treeCursor
        var errors = 0
        // Iterative pre-order walk with a cursor: far cheaper than recursing through Node wrappers.
        // The cursor's ancestors, so classifying needs no parent lookups, which tree-sitter answers by
        // descending from the root again.
        var ancestors: [Node?] = []
        var done = false
        while !done {
            let n = cursor.currentNode
            if let n {
                classify(n, parent: ancestors.last ?? nil, grandparent: ancestors.dropLast().last ?? nil, ns: ns, into: &tokens)
                if n.nodeType == "ERROR" || n.isMissing { errors += 1 }
            }
            if cursor.goToFirstChild() {
                ancestors.append(n)
                continue
            }
            while !cursor.gotoNextSibling() {
                if !cursor.gotoParent() { done = true; break }
                _ = ancestors.popLast()
            }
        }
        info.tokens = tokens
        info.errorCount = errors

        var testRanges: [ClosedRange<Int>] = []
        func attrsBefore(_ n: Node) -> [String] {
            var out: [String] = []
            var p = n.previousNamedSibling
            while let s = p, s.nodeType == "attribute_item" || s.nodeType == "line_comment" || s.nodeType == "block_comment" {
                if s.nodeType == "attribute_item" { out.append(str(s)) }
                p = s.previousNamedSibling
            }
            return out
        }
        func isPub(_ n: Node) -> Bool {
            for i in 0..<n.namedChildCount { if n.namedChild(at: i)?.nodeType == "visibility_modifier" { return true } }
            return false
        }

        func build(_ node: Node, parent: OutlineItem?, inTest: Bool) -> [OutlineItem] {
            var items: [OutlineItem] = []
            for i in 0..<node.namedChildCount {
                guard let c = node.namedChild(at: i), let type = c.nodeType else { continue }
                var kind: OutlineKind?
                var name = ""
                var nameNode: Node? = c.child(byFieldName: "name")
                var detail = ""
                switch type {
                case "function_item", "function_signature_item":
                    kind = (parent?.kind == .impl || parent?.kind == .trait) ? .method : .function
                case "struct_item": kind = .structItem
                case "enum_item": kind = .enumItem
                case "union_item": kind = .union
                case "trait_item": kind = .trait
                case "mod_item": kind = .module
                case "macro_definition": kind = .macro
                case "const_item": kind = .constant
                case "static_item": kind = .staticItem
                case "type_item": kind = .typeAlias
                case "impl_item":
                    kind = .impl
                    let ty = c.child(byFieldName: "type")
                    let tr = c.child(byFieldName: "trait")
                    nameNode = ty
                    let tyName = ty.map(str) ?? "?"
                    name = baseTypeName(tyName)
                    detail = tr.map { "impl \(str($0)) for \(tyName)" } ?? "impl \(tyName)"
                default: break
                }
                guard let kind else { continue }
                if name.isEmpty { name = nameNode.map(str) ?? type }
                let attrs = attrsBefore(c)
                let attrIsTest = attrs.contains { a in
                    a.contains("cfg(test)") || a.range(of: #"^#\[(\w+::)*test\b"#, options: .regularExpression) != nil
                        || a.contains("::test(") || a.hasSuffix("::test]") || a.contains("proptest")
                }
                let test = inTest || attrIsTest
                var startOffset = c.range.location
                if let firstAttr = attrsStart(c) { startOffset = firstAttr }
                let full = srange(NSRange(location: startOffset, length: NSMaxRange(c.range) - startOffset))
                let body = c.child(byFieldName: "body")
                let headerEnd = body.map { pos($0.range.location).line } ?? full.end.line
                if kind == .function || kind == .method, detail.isEmpty {
                    let sigEnd = body?.range.location ?? NSMaxRange(c.range)
                    detail = ns.substring(with: NSRange(location: c.range.location, length: sigEnd - c.range.location))
                        .replacingOccurrences(of: #"\s+"#, with: " ", options: .regularExpression)
                        .trimmingCharacters(in: .whitespaces)
                }
                let item = OutlineItem(
                    name: name, kind: kind, range: full,
                    nameRange: nameNode.map { srange($0.range) } ?? full,
                    headerEndLine: headerEnd, detail: detail, isTest: test, isPublic: isPub(c))
                item.parent = parent
                if attrIsTest && !inTest { testRanges.append(full.start.line...full.end.line) }
                if let body, kind == .impl || kind == .trait || kind == .module {
                    item.children = build(body, parent: item, inTest: test)
                }
                items.append(item)
            }
            return items
        }
        func attrsStart(_ n: Node) -> Int? {
            var first: Int?
            var p = n.previousNamedSibling
            while let s = p, s.nodeType == "attribute_item" { first = s.range.location; p = s.previousNamedSibling }
            return first
        }
        info.outline = build(root, parent: nil, inTest: false)
        info.testLineRanges = testRanges
        return info
    }

    static func baseTypeName(_ s: String) -> String {
        var t = s
        if let lt = t.firstIndex(of: "<") { t = String(t[..<lt]) }
        if let c = t.range(of: "::", options: .backwards) { t = String(t[c.upperBound...]) }
        return t.trimmingCharacters(in: CharacterSet(charactersIn: "&* ")).replacingOccurrences(of: "mut ", with: "")
    }

    private static func classify(_ n: Node, parent: Node?, grandparent: Node?, ns: NSString, into tokens: inout [Token]) {
        guard let type = n.nodeType else { return }
        let r = n.range
        func add(_ k: TokenKind) { tokens.append(Token(range: r, kind: k)) }
        switch type {
        case "line_comment", "block_comment":
            let s = ns.substring(with: NSRange(location: r.location, length: min(3, r.length)))
            add(s == "///" || s == "//!" || s == "/**" || s == "/*!" ? .docComment : .comment)
        case "string_literal", "raw_string_literal", "char_literal": add(.string)
        case "integer_literal", "float_literal": add(.number)
        case "boolean_literal": add(.constant)
        case "primitive_type", "type_identifier": add(.type)
        case "lifetime": add(.lifetime)
        case "attribute_item", "inner_attribute_item": add(.attribute)
        case "field_identifier", "shorthand_field_identifier": add(.field)
        case "self": add(.selfKeyword)
        case "mutable_specifier": add(.keyword)
        case "crate", "super": add(.keyword)
        case "macro_invocation":
            if let m = n.child(byFieldName: "macro") {
                tokens.append(Token(range: NSRange(location: m.range.location, length: m.range.length + 1), kind: .macro))
            }
        case "identifier":
            guard let p = parent, let pt = p.nodeType else { return }
            switch pt {
            case "function_item", "function_signature_item":
                if p.child(byFieldName: "name")?.range == r { add(.function) }
            case "call_expression":
                if p.child(byFieldName: "function")?.range == r { add(.function) }
            case "scoped_identifier":
                if p.child(byFieldName: "name")?.range == r, let gp = grandparent, gp.nodeType == "call_expression" {
                    add(.function)
                } else if p.child(byFieldName: "path")?.range == r {
                    let s = ns.substring(with: r)
                    if let f = s.first, f.isUppercase { add(.type) } else { add(.module) }
                }
            case "generic_function":
                add(.function)
            case "macro_definition": add(.macro)
            case "mod_item": add(.module)
            case "scoped_use_list", "use_declaration", "use_list":
                break
            default:
                let s = ns.substring(with: r)
                if s.count > 1, s == s.uppercased(), s.first?.isLetter == true { add(.constant) }
                else if let f = s.first, f.isUppercase { add(.type) }
            }
        case "field_expression":
            if let gp = parent, gp.nodeType == "call_expression", let f = n.child(byFieldName: "field") {
                tokens.append(Token(range: f.range, kind: .function))
            }
        default:
            if !n.isNamed, keywords.contains(type) { add(.keyword) }
        }
    }
}

/// Regex lexer for languages without a bundled grammar. Strings, comments, numbers and keywords only.
enum GenericLexer {
    static let keywordSets: [SourceLanguage: Set<String>] = [
        .rust: ["fn", "let", "mut", "pub", "impl", "struct", "enum", "trait", "use", "mod", "match", "if", "else", "for",
                "while", "loop", "return", "self", "Self", "async", "await", "move", "where", "type", "const", "static",
                "unsafe", "dyn", "crate", "super", "as", "in", "ref", "true", "false"],
        .swift: ["func", "let", "var", "class", "struct", "enum", "protocol", "extension", "import", "return", "if", "else",
                 "guard", "for", "while", "switch", "case", "default", "self", "init", "private", "public", "static",
                 "async", "await", "throws", "try", "true", "false", "nil"],
        .go: ["func", "package", "import", "var", "const", "type", "struct", "interface", "return", "if", "else", "for",
              "range", "switch", "case", "default", "go", "defer", "chan", "map", "nil", "true", "false"],
        .python: ["def", "class", "import", "from", "return", "if", "elif", "else", "for", "while", "in", "not", "and",
                  "or", "with", "as", "try", "except", "raise", "None", "True", "False", "lambda", "yield", "async", "await"],
        .c: ["int", "char", "void", "struct", "return", "if", "else", "for", "while", "switch", "case", "static", "const",
             "unsigned", "typedef", "enum", "sizeof", "inline", "bool", "#include", "#define", "#ifdef", "#endif"],
        .toml: ["true", "false"],
        .sql: ["select", "from", "where", "create", "table", "view", "materialized", "insert", "into", "values", "join",
               "on", "group", "by", "order", "as", "and", "or", "not", "null", "index", "cluster", "SELECT", "FROM",
               "WHERE", "CREATE", "TABLE", "VIEW", "MATERIALIZED", "INSERT", "INTO", "JOIN", "ON", "GROUP", "BY", "AS"],
        .shell: ["if", "then", "else", "fi", "for", "do", "done", "while", "case", "esac", "function", "export", "local", "return"],
    ]

    static func analyze(_ text: String, language: SourceLanguage) -> SyntaxInfo {
        var info = SyntaxInfo()
        let ns = text as NSString
        var tokens: [Token] = []
        let lineComment: String? = switch language {
        case .python, .toml, .yaml, .shell: "#"
        case .sql: "--"
        case .markdown, .json, .plain: nil
        default: "//"
        }
        var patterns: [(String, TokenKind)] = [
            (#""(?:[^"\\\n]|\\.)*""#, .string),
            (#"\b\d[\d_]*(?:\.\d+)?\b"#, .number),
        ]
        if let lc = lineComment { patterns.insert((NSRegularExpression.escapedPattern(for: lc) + ".*$", .comment), at: 0) }
        if language != .python && language != .toml && language != .yaml && language != .shell && language != .markdown {
            patterns.insert((#"/\*[\s\S]*?\*/"#, .comment), at: 0)
        }
        if language == .toml { patterns.append((#"^\s*\[[^\]]*\]"#, .type)); patterns.append((#"^\s*[\w\-\.]+(?=\s*=)"#, .field)) }
        if language == .markdown { patterns = [(#"^#{1,6} .*$"#, .keyword), (#"`[^`\n]+`"#, .string), (#"^```.*$"#, .comment)] }
        var claimed = IndexSet()
        for (p, kind) in patterns {
            guard let re = try? NSRegularExpression(pattern: p, options: [.anchorsMatchLines]) else { continue }
            for m in re.matches(in: text, range: NSRange(location: 0, length: ns.length)) {
                let r = m.range
                if claimed.intersects(integersIn: r.location..<NSMaxRange(r)) { continue }
                claimed.insert(integersIn: r.location..<NSMaxRange(r))
                tokens.append(Token(range: r, kind: kind))
            }
        }
        if let kws = keywordSets[language], let re = try? NSRegularExpression(pattern: #"#?\b[A-Za-z_]+\b"#) {
            for m in re.matches(in: text, range: NSRange(location: 0, length: ns.length)) {
                let r = m.range
                if claimed.contains(r.location) { continue }
                if kws.contains(ns.substring(with: r)) { tokens.append(Token(range: r, kind: .keyword)) }
            }
        }
        info.tokens = tokens
        if language == .rust { info.outline = regexRustOutline(ns) }
        return info
    }

    private static func regexRustOutline(_ ns: NSString) -> [OutlineItem] {
        guard let re = try? NSRegularExpression(
            pattern: #"^\s*(pub(?:\([^)]*\))?\s+)?(?:async\s+|unsafe\s+|const\s+)*(fn|struct|enum|trait|mod)\s+([A-Za-z_]\w*)"#,
            options: [.anchorsMatchLines]) else { return [] }
        let index = LineIndex(ns)
        return re.matches(in: ns as String, range: NSRange(location: 0, length: ns.length)).map { m in
            let kw = ns.substring(with: m.range(at: 2))
            let kind: OutlineKind = ["fn": .function, "struct": .structItem, "enum": .enumItem, "trait": .trait, "mod": .module][kw] ?? .function
            let p = index.position(of: m.range(at: 3).location)
            let name = ns.substring(with: m.range(at: 3))
            return OutlineItem(name: name, kind: kind, range: SourceRange(start: p, end: p),
                               nameRange: SourceRange(start: p, end: SourcePos(line: p.line, col: p.col + name.utf16.count)),
                               headerEndLine: p.line, detail: "", isTest: false, isPublic: m.range(at: 1).location != NSNotFound)
        }
    }
}
