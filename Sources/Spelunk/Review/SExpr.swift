import Foundation

/// One value read from rule text: a symbol, string, integer, `/regex/flags` or parenthesized list,
/// with the line it starts on and its span in the source.
struct SExpr: Sendable {
    enum Kind: Sendable {
        case symbol(String)
        case string(String)
        case number(Int)
        case regex(pattern: String, flags: String)
        case list([SExpr])
    }

    var kind: Kind
    var line: Int
    var range: Range<String.Index>

    var symbol: String? { if case .symbol(let s) = kind { s } else { nil } }
    var string: String? { if case .string(let s) = kind { s } else { nil } }
    var list: [SExpr]? { if case .list(let l) = kind { l } else { nil } }

    /// How the value reads in an error message.
    var describe: String {
        switch kind {
        case .symbol(let s): "`\(s)`"
        case .string(let s): "\"\(s)\""
        case .number(let n): "`\(n)`"
        case .regex(let p, let f): "/\(p)/\(f)"
        case .list(let l): l.first?.symbol.map { "`(\($0) …)`" } ?? "a list"
        }
    }

    struct ReadError: Error, LocalizedError {
        var line: Int
        var message: String
        var errorDescription: String? { message }
    }

    /// Reads every top-level value. `;` starts a comment that runs to the end of the line. Strings
    /// take `\"`, `\\`, `\n` and `\t`; any other backslash is kept. A regex runs from `/` to the next
    /// unescaped `/`, then any flag letters.
    static func read(_ text: String) throws -> [SExpr] {
        var out: [SExpr] = []
        var stack: [(items: [SExpr], line: Int, start: String.Index)] = []
        var i = text.startIndex
        var line = 1

        func emit(_ e: SExpr) {
            if stack.isEmpty { out.append(e) } else { stack[stack.count - 1].items.append(e) }
        }
        func isDelimiter(_ c: Character) -> Bool { c.isWhitespace || c == "(" || c == ")" || c == "\"" || c == ";" }

        while i < text.endIndex {
            let c = text[i]
            if c == "\n" { line += 1; i = text.index(after: i); continue }
            if c.isWhitespace { i = text.index(after: i); continue }
            if c == ";" {
                while i < text.endIndex, text[i] != "\n" { i = text.index(after: i) }
                continue
            }
            let start = i
            switch c {
            case "(":
                stack.append(([], line, start))
                i = text.index(after: i)
            case ")":
                guard let open = stack.popLast() else { throw ReadError(line: line, message: "unexpected `)`") }
                i = text.index(after: i)
                emit(SExpr(kind: .list(open.items), line: open.line, range: open.start..<i))
            case "\"":
                let startLine = line
                var s = ""
                i = text.index(after: i)
                var closed = false
                while i < text.endIndex {
                    let ch = text[i]
                    if ch == "\"" { closed = true; i = text.index(after: i); break }
                    if ch == "\n" { line += 1 }
                    if ch == "\\", text.index(after: i) < text.endIndex {
                        let next = text[text.index(after: i)]
                        switch next {
                        case "\"": s.append("\"")
                        case "\\": s.append("\\")
                        case "n": s.append("\n")
                        case "t": s.append("\t")
                        default: s.append("\\"); s.append(next)
                        }
                        i = text.index(i, offsetBy: 2)
                        continue
                    }
                    s.append(ch)
                    i = text.index(after: i)
                }
                guard closed else { throw ReadError(line: startLine, message: "unterminated string") }
                emit(SExpr(kind: .string(s), line: startLine, range: start..<i))
            case "/":
                var p = ""
                i = text.index(after: i)
                var closed = false
                while i < text.endIndex {
                    let ch = text[i]
                    if ch == "\n" { break }
                    if ch == "/" { closed = true; i = text.index(after: i); break }
                    if ch == "\\", text.index(after: i) < text.endIndex, text[text.index(after: i)] != "\n" {
                        p.append(ch); p.append(text[text.index(after: i)])
                        i = text.index(i, offsetBy: 2)
                        continue
                    }
                    p.append(ch)
                    i = text.index(after: i)
                }
                guard closed else { throw ReadError(line: line, message: "unterminated regex; write it /like this/ on one line") }
                var flags = ""
                while i < text.endIndex, text[i].isLetter { flags.append(text[i]); i = text.index(after: i) }
                emit(SExpr(kind: .regex(pattern: p, flags: flags), line: line, range: start..<i))
            default:
                var s = ""
                while i < text.endIndex, !isDelimiter(text[i]) { s.append(text[i]); i = text.index(after: i) }
                emit(SExpr(kind: Int(s).map { .number($0) } ?? .symbol(s), line: line, range: start..<i))
            }
        }
        if let open = stack.last { throw ReadError(line: open.line, message: "`(` is never closed") }
        return out
    }
}
