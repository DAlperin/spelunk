import Foundation

/// A line from the other side of a diff, shown inline but not part of the file.
struct PhantomLine: Hashable, Sendable {
    var kind: DiffLineKind
    /// Zero-based line number in the other side's file.
    var otherLine: Int
    var text: String
    /// Highlighting from the other side's parse, relative to the line start.
    var tokens: [Token]

    static func == (a: PhantomLine, b: PhantomLine) -> Bool { a.kind == b.kind && a.otherLine == b.otherLine && a.text == b.text }
    func hash(into h: inout Hasher) { h.combine(kind); h.combine(otherLine); h.combine(text) }
}

extension Token: Equatable {
    static func == (a: Token, b: Token) -> Bool { a.range == b.range && a.kind == b.kind }
}

/// What the editor shows: the document with phantom lines interleaved, plus the mapping between
/// display positions and positions in the real document. Without phantoms it is the identity.
final class DisplayDoc {
    enum Entry {
        case real(Int)
        case phantom(PhantomLine)
        /// Blank space reserved for an embedded view (a review thread or comment composer).
        case block(id: String, index: Int)
    }

    /// An embedded view after a real line, `lines` display lines tall.
    struct Block: Hashable {
        var id: String
        /// The zero-based line the block follows: a real line, or with `otherSide` the other version's
        /// line shown inline as a phantom.
        var afterLine: Int
        var lines: Int
        var otherSide = false
    }

    let doc: SourceDocument
    let text: String
    let ns: NSString
    let lines: LineIndex
    let entries: [Entry]
    /// Display line of each real line.
    let realToDisplay: [Int]
    let hasPhantoms: Bool
    let fingerprint: Int

    /// Display line ranges of blocks, by id.
    let blockLines: [String: Range<Int>]

    init(doc: SourceDocument, phantoms: [Int: [PhantomLine]], blocks: [Block] = []) {
        self.doc = doc
        hasPhantoms = !phantoms.isEmpty || !blocks.isEmpty
        guard hasPhantoms else {
            text = doc.text
            ns = doc.ns
            lines = doc.lines
            entries = (0..<doc.lines.lineCount).map { .real($0) }
            realToDisplay = Array(0..<doc.lines.lineCount)
            fingerprint = 0
            blockLines = [:]
            return
        }
        let blocksAfter = Dictionary(grouping: blocks.filter { !$0.otherSide }, by: \.afterLine)
        let blocksAfterOther = Dictionary(grouping: blocks.filter(\.otherSide), by: \.afterLine)
        var blockRanges: [String: Range<Int>] = [:]
        var out: [String] = []
        var entries: [Entry] = []
        var map: [Int] = []
        func emit(_ bs: [Block]?) {
            for b in bs ?? [] {
                let start = entries.count
                for i in 0..<max(1, b.lines) {
                    out.append("")
                    entries.append(.block(id: b.id, index: i))
                }
                blockRanges[b.id] = start..<entries.count
            }
        }
        let count = doc.lines.lineCount
        for line in 0...count {
            for p in phantoms[line] ?? [] {
                out.append(p.text)
                entries.append(.phantom(p))
                emit(blocksAfterOther[p.otherLine])
            }
            guard line < count else { break }
            map.append(entries.count)
            out.append(doc.lineText(line))
            entries.append(.real(line))
            emit(blocksAfter[line])
        }
        text = out.joined(separator: "\n")
        ns = text as NSString
        lines = LineIndex(ns)
        self.entries = entries
        realToDisplay = map
        var h = Hasher()
        for k in phantoms.keys.sorted() { h.combine(k); h.combine(phantoms[k]!) }
        for b in blocks.sorted(by: { $0.id < $1.id }) { h.combine(b) }
        fingerprint = h.finalize()
        blockLines = blockRanges
    }

    func displayLine(_ real: Int) -> Int { realToDisplay.isEmpty ? 0 : realToDisplay[max(0, min(real, realToDisplay.count - 1))] }

    func displayOffset(_ p: SourcePos) -> Int { lines.offset(of: SourcePos(line: displayLine(p.line), col: p.col)) }

    func displayRange(_ r: SourceRange) -> NSRange {
        let a = displayOffset(r.start), b = displayOffset(r.end)
        return NSRange(location: a, length: max(0, b - a))
    }

    /// Display offset of a character offset in the real document.
    func displayOffset(realOffset: Int) -> Int {
        guard hasPhantoms else { return realOffset }
        return displayOffset(doc.lines.position(of: realOffset))
    }

    /// The real position under a display position; nil on a phantom line.
    func realPos(_ display: SourcePos) -> SourcePos? {
        guard display.line < entries.count else { return nil }
        if case .real(let l) = entries[display.line] { return SourcePos(line: l, col: display.col) }
        return nil
    }

    func entry(_ displayLine: Int) -> Entry? { displayLine < entries.count ? entries[displayLine] : nil }
}
