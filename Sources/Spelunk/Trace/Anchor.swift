import CryptoKit
import Foundation

/// What a saved location points at beyond its line number, so it can be found again after the file
/// changes: the enclosing item, the line's text and its neighbours, and a hash of the whole file.
struct CodeAnchor: Codable, Hashable, Sendable {
    /// Qualified name of the innermost enclosing item, when there is one.
    var symbol: String?
    /// Lines from the symbol's name line to the location.
    var offset: Int
    /// The location's line and its neighbours, with whitespace collapsed.
    var line: String
    var before: String
    var after: String
    var fileHash: String

    static func make(_ loc: CodeLocation, in doc: SourceDocument) -> CodeAnchor {
        let l = min(loc.line, max(0, doc.lines.lineCount - 1))
        let item = doc.syntax.enclosingItem(line: l, strict: true)
        return CodeAnchor(symbol: item?.qualifiedName, offset: item.map { l - $0.nameRange.start.line } ?? 0,
                          line: Self.normalized(doc, l), before: Self.normalized(doc, l - 1), after: Self.normalized(doc, l + 1),
                          fileHash: Self.hash(doc.text))
    }

    static func hash(_ text: String) -> String {
        SHA256.hash(data: Data(text.utf8)).prefix(12).map { String(format: "%02x", $0) }.joined()
    }

    static func normalized(_ doc: SourceDocument, _ line: Int) -> String {
        guard line >= 0, line < doc.lines.lineCount else { return "" }
        return doc.lineText(line).split(whereSeparator: \.isWhitespace).joined(separator: " ")
    }

    enum Resolution: Equatable {
        /// The saved line still holds what was saved.
        case unchanged
        case moved(toLine: Int)
        /// Nothing in the file matches; the saved line is all there is.
        case lost
    }

    /// Finds the saved location in the current text of its file. An unchanged file, or an unchanged
    /// line where it was, keeps the location. Otherwise the enclosing symbol is looked up again and
    /// the line searched for inside it; without a symbol the whole file is searched, and a line that
    /// matches in several places goes to the one whose neighbours also match, then the nearest.
    func resolve(line saved: Int, in doc: SourceDocument) -> Resolution {
        let n = doc.lines.lineCount
        if Self.hash(doc.text) == fileHash { return .unchanged }
        if saved < n, Self.normalized(doc, saved) == line, !line.isEmpty || score(saved, doc) == 3 { return .unchanged }

        func best(in range: ClosedRange<Int>, near target: Int) -> Int? {
            guard !line.isEmpty else { return nil }
            let lo = max(0, range.lowerBound), hi = min(n - 1, range.upperBound)
            guard lo <= hi else { return nil }
            let matches = (lo...hi).filter { Self.normalized(doc, $0) == line }
            return matches.max { a, b in
                let (sa, sb) = (score(a, doc), score(b, doc))
                return sa != sb ? sa < sb : abs(a - target) > abs(b - target)
            }
        }

        if let symbol {
            let bare = symbol.split(separator: ":").last.map(String.init) ?? symbol
            var items = doc.syntax.flatOutline.filter { $0.qualifiedName == symbol }
            if items.isEmpty { items = doc.syntax.flatOutline.filter { $0.name == bare } }
            if let item = items.min(by: { abs($0.nameRange.start.line - saved) < abs($1.nameRange.start.line - saved) }) {
                let expected = item.nameRange.start.line + offset
                if let l = best(in: item.range.start.line...item.range.end.line, near: expected) { return l == saved ? .unchanged : .moved(toLine: l) }
                // The line itself changed: keep the same distance into the item.
                let l = min(max(expected, item.range.start.line), item.range.end.line)
                return l == saved ? .unchanged : .moved(toLine: l)
            }
        }
        if let l = best(in: 0...max(0, n - 1), near: saved) { return l == saved ? .unchanged : .moved(toLine: l) }
        return .lost
    }

    /// How many of the line and its two neighbours match what was saved.
    private func score(_ l: Int, _ doc: SourceDocument) -> Int {
        (Self.normalized(doc, l) == line ? 1 : 0) + (Self.normalized(doc, l - 1) == before ? 1 : 0) + (Self.normalized(doc, l + 1) == after ? 1 : 0)
    }
}

extension CodeLocation {
    /// The same location moved to another line, keeping its columns and extent.
    func onLine(_ line: Int) -> CodeLocation {
        var c = self
        let delta = line - range.start.line
        c.range = SourceRange(start: SourcePos(line: line, col: range.start.col),
                              end: SourcePos(line: range.end.line + delta, col: range.end.col))
        return c
    }
}
