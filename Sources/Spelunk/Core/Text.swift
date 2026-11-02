import Foundation

/// Zero-based line and UTF-16 column. UTF-16 matches NSString, tree-sitter's UTF-16 parse, and
/// the LSP default encoding, so it is the canonical coordinate system across providers.
struct SourcePos: Hashable, Codable, Comparable, Sendable {
    var line: Int
    var col: Int
    static func < (a: SourcePos, b: SourcePos) -> Bool { a.line != b.line ? a.line < b.line : a.col < b.col }
}

struct SourceRange: Hashable, Codable, Sendable {
    var start: SourcePos
    var end: SourcePos
    init(start: SourcePos, end: SourcePos) { self.start = start; self.end = end }
    init(line: Int, col: Int = 0, endCol: Int? = nil) {
        start = SourcePos(line: line, col: col)
        end = SourcePos(line: line, col: endCol ?? col)
    }
    func contains(_ p: SourcePos) -> Bool { start <= p && p <= end }
}

/// A position inside the repository. `path` is relative to the workspace root.
struct CodeLocation: Hashable, Codable, Identifiable, Sendable {
    var path: String
    var range: SourceRange
    var id: String { "\(path):\(range.start.line):\(range.start.col)" }
    var line: Int { range.start.line }
    var displayLine: Int { range.start.line + 1 }
    var shortDescription: String { "\(path.lastPathComponent):\(displayLine)" }
}

/// Line-start table for a text buffer in UTF-16 units.
struct LineIndex: Sendable {
    let starts: [Int]
    let length: Int

    init(_ text: NSString) {
        var s = [0]
        let len = text.length
        s.reserveCapacity(len / 30)
        var buf = [unichar](repeating: 0, count: len)
        text.getCharacters(&buf, range: NSRange(location: 0, length: len))
        for i in 0..<len where buf[i] == 10 { s.append(i + 1) }
        starts = s
        length = len
    }

    var lineCount: Int { starts.count }

    func offset(of p: SourcePos) -> Int {
        guard p.line < starts.count else { return length }
        return min(starts[max(0, p.line)] + p.col, lineEnd(p.line))
    }

    func lineEnd(_ line: Int) -> Int {
        guard line + 1 < starts.count else { return length }
        return starts[line + 1] - 1
    }

    func lineRange(_ line: Int) -> NSRange {
        let l = max(0, min(line, starts.count - 1))
        return NSRange(location: starts[l], length: lineEnd(l) - starts[l])
    }

    func position(of offset: Int) -> SourcePos {
        var lo = 0, hi = starts.count - 1
        while lo < hi {
            let mid = (lo + hi + 1) / 2
            if starts[mid] <= offset { lo = mid } else { hi = mid - 1 }
        }
        return SourcePos(line: lo, col: offset - starts[lo])
    }

    func nsRange(_ r: SourceRange) -> NSRange {
        let a = offset(of: r.start), b = offset(of: r.end)
        return NSRange(location: a, length: max(0, b - a))
    }
}

extension NSString {
    func line(_ index: LineIndex, _ n: Int) -> String {
        guard n >= 0 && n < index.lineCount else { return "" }
        return substring(with: index.lineRange(n))
    }

    func identifierRange(at offset: Int) -> NSRange? {
        guard length > 0 else { return nil }
        func isIdent(_ c: unichar) -> Bool {
            (c >= 48 && c <= 57) || (c >= 65 && c <= 90) || (c >= 97 && c <= 122) || c == 95
        }
        var o = min(offset, length - 1)
        if !isIdent(character(at: o)) {
            if o > 0 && isIdent(character(at: o - 1)) { o -= 1 } else { return nil }
        }
        var s = o, e = o
        while s > 0 && isIdent(character(at: s - 1)) { s -= 1 }
        while e < length && isIdent(character(at: e)) { e += 1 }
        return NSRange(location: s, length: e - s)
    }
}

/// Converts a column in a different code-unit encoding to UTF-16 for one line of text.
enum ColumnEncoding {
    static func utf8ToUTF16(_ line: String, _ col: Int) -> Int {
        let utf8 = Array(line.utf8)
        let prefix = utf8.prefix(min(col, utf8.count))
        return String(decoding: prefix, as: UTF8.self).utf16.count
    }

    static func utf32ToUTF16(_ line: String, _ col: Int) -> Int {
        String(line.unicodeScalars.prefix(col)).utf16.count
    }
}

enum SourceLanguage: String, Codable, Sendable {
    case rust, toml, markdown, swift, c, cpp, go, python, javascript, typescript, json, yaml, shell, protobuf, sql, plain

    static func from(path: String) -> SourceLanguage {
        switch path.pathExtension.lowercased() {
        case "rs": return .rust
        case "toml": return .toml
        case "md", "markdown": return .markdown
        case "swift": return .swift
        case "c", "h": return .c
        case "cc", "cpp", "hpp", "cxx": return .cpp
        case "go": return .go
        case "py": return .python
        case "js", "mjs", "jsx": return .javascript
        case "ts", "tsx": return .typescript
        case "json": return .json
        case "yml", "yaml": return .yaml
        case "sh", "bash", "zsh": return .shell
        case "proto": return .protobuf
        case "sql": return .sql
        default:
            if path.lastPathComponent == "Cargo.lock" { return .toml }
            return .plain
        }
    }

    var displayName: String {
        switch self {
        case .rust: "Rust"
        case .toml: "TOML"
        case .markdown: "Markdown"
        case .swift: "Swift"
        case .c: "C"
        case .cpp: "C++"
        case .go: "Go"
        case .python: "Python"
        case .javascript: "JavaScript"
        case .typescript: "TypeScript"
        case .json: "JSON"
        case .yaml: "YAML"
        case .shell: "Shell"
        case .protobuf: "Protobuf"
        case .sql: "SQL"
        case .plain: "Plain Text"
        }
    }

    var lspId: String {
        switch self {
        case .rust: "rust"
        default: rawValue
        }
    }
}

extension Array {
    subscript(safe i: Int) -> Element? { indices.contains(i) ? self[i] : nil }
}
