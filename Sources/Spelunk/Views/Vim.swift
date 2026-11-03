import AppKit

/// Vim-style navigation for the read-only code view: motions with counts, search, visual selection
/// and yank. In a review, `J` and `K` move between hunks and `c` drafts a comment, since editing
/// commands do not exist and the text never changes; `gh` shows the hover card (`K` too outside a
/// review). Bracket and leader bindings cover the other review commands.
@MainActor
final class VimController {
    enum Mode: Equatable { case normal, visual(anchor: Int), visualLine(anchor: Int) }

    weak var textView: SourceTextView?
    private(set) var mode: Mode = .normal
    private var count = ""
    /// Keys waiting for the rest of a command (`g`, `z`, `]`, `[`, space, or `f`/`t` for a target).
    private var pending = ""
    /// The column `j` and `k` aim for, kept across short lines.
    private var goalColumn: Int?
    private var lastFind: (kind: Character, char: Character)?

    static var enabled: Bool { Prefs.vim }

    init(textView: SourceTextView) { self.textView = textView }

    private var ws: Workspace? { textView?.coordinator?.ws }
    private var ns: NSString { (textView?.string ?? "") as NSString }

    /// The status-bar description: mode plus any keys typed so far.
    var status: String {
        let m: String = switch mode {
        case .normal: "NORMAL"
        case .visual: "VISUAL"
        case .visualLine: "VISUAL LINE"
        }
        let keys = count + pending
        return keys.isEmpty ? m : "\(m)  \(keys)"
    }

    var isNormal: Bool { mode == .normal }

    private func publish() { ws?.vimStatus = Self.enabled ? status : nil }

    /// Handles a key press; false lets the text view or the app have it.
    func handle(_ event: NSEvent) -> Bool {
        guard Self.enabled, let tv = textView else { return false }
        let mods = event.modifierFlags.intersection([.command, .option, .control])
        if mods.contains(.command) || mods.contains(.option) { return false }
        let ctrl = mods.contains(.control)
        guard let chars = event.charactersIgnoringModifiers, let c = chars.first else { return false }
        defer { publish() }

        if event.keyCode == 53 { // Escape
            if mode != .normal { exitVisual(); return true }
            if !pending.isEmpty || !count.isEmpty { pending = ""; count = ""; return true }
            return false
        }
        if ctrl { return control(c, tv) }
        // Arrow keys keep working as motions in every mode.
        if let arrow = arrowMotion(event.keyCode) { move(arrow, count: takeCount()); return true }

        if !pending.isEmpty { return continuePending(c, tv) }
        if c.isNumber, c != "0" || !count.isEmpty { count.append(c); return true }

        let n = takeCount()
        switch c {
        case "h": move(.left, count: n)
        case "l": move(.right, count: n)
        case "j": move(.down, count: n)
        case "k": move(.up, count: n)
        case "w": move(.wordForward(big: false), count: n)
        case "W": move(.wordForward(big: true), count: n)
        case "b": move(.wordBackward(big: false), count: n)
        case "B": move(.wordBackward(big: true), count: n)
        case "e": move(.wordEnd(big: false), count: n)
        case "E": move(.wordEnd(big: true), count: n)
        case "0": move(.lineStart, count: 1)
        case "^": move(.firstNonBlank, count: 1)
        case "$": move(.lineEnd, count: 1)
        case "G": move(n > 1 || !lastCountWasEmpty ? .line(n) : .documentEnd, count: 1)
        case "H": move(.screen(0), count: 1)
        case "M": move(.screen(1), count: 1)
        case "L": move(.screen(2), count: 1)
        case "{": move(.paragraphBack, count: n)
        case "}": move(.paragraphForward, count: n)
        case "%": move(.matchBracket, count: 1)
        case ";": if let f = lastFind { move(.find(f.kind, f.char), count: n) }
        case ",": if let f = lastFind { move(.find(Self.reverse(f.kind), f.char), count: n) }
        case "*": searchWord(forward: true)
        case "#": searchWord(forward: false)
        case "/": finder(.showFindInterface)
        case "n": finder(.nextMatch)
        case "N": finder(.previousMatch)
        case "v": toggleVisual(line: false)
        case "V": toggleVisual(line: true)
        case "y": yank()
        case "J": if ws?.review != nil { for _ in 0..<n { ReviewNav.next(ws!) } }
        case "K": if let ws, ws.review != nil { for _ in 0..<n { ReviewNav.previous(ws) } } else { showHover() }
        case "c", "C": comment()
        case "g", "z", "]", "[", " ", "f", "F", "t", "T": pending = String(c); pendingCount = n
        default: break
        }
        return true
    }

    private var pendingCount = 1
    private var lastCountWasEmpty = true

    private func takeCount() -> Int {
        lastCountWasEmpty = count.isEmpty
        let n = Int(count) ?? 1
        count = ""
        return max(1, n)
    }

    private func continuePending(_ c: Character, _ tv: SourceTextView) -> Bool {
        let p = pending + String(c)
        let n = pendingCount
        pending = ""
        switch p.first {
        case "f", "F", "t", "T":
            lastFind = (p.first!, c)
            move(.find(p.first!, c), count: n)
            return true
        default: break
        }
        guard let ws else { return true }
        switch p {
        case "gg": move(lastCountWasEmpty ? .documentStart : .line(n), count: 1)
        case "gd": if let pos = realCaret() { ws.goToDefinition(at: pos) }
        case "gh": showHover()
        case "za": ws.toggleFold()
        case "zo": ws.setFold(false)
        case "zc": ws.setFold(true)
        case "zR": ws.foldAll(false)
        case "zM": ws.foldAll(true)
        case "zz": scrollCaret(0.5)
        case "zt": scrollCaret(0.0)
        case "zb": scrollCaret(1.0)
        case "]h", "]c": for _ in 0..<n { ReviewNav.next(ws) }
        case "[h", "[c": for _ in 0..<n { ReviewNav.previous(ws) }
        case "]u": ReviewNav.nextImportant(ws)
        case "]t": ws.moveThread(n)
        case "[t": ws.moveThread(-n)
        case " v":
            if let id = ws.selectedHunkID { ws.review?.toggleViewed(id); ReviewNav.nextImportant(ws) }
        case " c": comment()
        case " r": ws.resolveCurrentThread()
        case " a": ws.openAsk()
        case " p": ws.addCurrentToTrace()
        default: NSSound.beep()
        }
        return true
    }

    private func control(_ c: Character, _ tv: SourceTextView) -> Bool {
        let n = takeCount()
        let page = max(1, visibleLineCount())
        switch c {
        case "d": move(.down, count: page / 2 * n)
        case "u": move(.up, count: page / 2 * n)
        case "f": move(.down, count: page * n)
        case "b": move(.up, count: page * n)
        case "o": ws?.goBack()
        case "i", "\t": ws?.goForward()
        default: return false
        }
        return true
    }

    private func arrowMotion(_ code: UInt16) -> Motion? {
        switch code {
        case 123: .left
        case 124: .right
        case 125: .down
        case 126: .up
        default: nil
        }
    }

    // MARK: Motions

    enum Motion {
        case left, right, up, down
        case wordForward(big: Bool), wordBackward(big: Bool), wordEnd(big: Bool)
        case lineStart, firstNonBlank, lineEnd
        case documentStart, documentEnd, line(Int)
        case screen(Int)
        case paragraphForward, paragraphBack
        case matchBracket
        case find(Character, Character)
    }

    /// The moving end of a visual selection.
    private var visualCaret = 0

    /// The caret: the selection's position in normal mode, the moving end in visual modes.
    private var caret: Int {
        guard let tv = textView else { return 0 }
        return mode == .normal ? tv.selectedRange().location : visualCaret
    }

    /// Where vim last put the caret; a different caret means something else moved it.
    private var lastPlaced: Int?

    private func move(_ m: Motion, count: Int) {
        var o = caret
        if o != lastPlaced { goalColumn = nil }
        let vertical: Bool
        switch m { case .up, .down: vertical = true; default: vertical = false }
        if !vertical { goalColumn = nil }
        for _ in 0..<max(1, count) {
            let next = target(m, from: o)
            if next == o { break }
            o = next
        }
        setCaret(o)
    }

    private func target(_ m: Motion, from o: Int) -> Int {
        let s = ns, len = s.length
        func line(_ i: Int) -> NSRange { s.lineRange(for: NSRange(location: min(i, len), length: 0)) }
        func contentEnd(_ r: NSRange) -> Int {
            var e = NSMaxRange(r)
            while e > r.location, let ch = UnicodeScalar(s.character(at: e - 1)), CharacterSet.newlines.contains(ch) { e -= 1 }
            return e
        }
        func lastCol(_ r: NSRange) -> Int { max(r.location, contentEnd(r) - 1) }
        switch m {
        case .left:
            return o > line(o).location ? o - 1 : o
        case .right:
            let r = line(o)
            return o < lastCol(r) ? o + 1 : o
        case .down, .up:
            let r = line(o)
            if goalColumn == nil { goalColumn = o - r.location }
            let next: NSRange
            if case .down = m {
                guard NSMaxRange(r) < len else { return o }
                next = line(NSMaxRange(r))
            } else {
                guard r.location > 0 else { return o }
                next = line(r.location - 1)
            }
            return min(next.location + (goalColumn ?? 0), lastCol(next))
        case .wordForward(let big):
            var i = o
            let start = cls(i, big)
            while i < len, cls(i, big) == start, start != 0 { i += 1 }
            while i < len, cls(i, big) == 0 { i += 1 }
            return min(i, max(0, len - 1))
        case .wordEnd(let big):
            var i = min(o + 1, len - 1)
            while i < len - 1, cls(i, big) == 0 { i += 1 }
            let k = cls(i, big)
            while i < len - 1, cls(i + 1, big) == k { i += 1 }
            return i
        case .wordBackward(let big):
            var i = max(0, o - 1)
            while i > 0, cls(i, big) == 0 { i -= 1 }
            let k = cls(i, big)
            while i > 0, cls(i - 1, big) == k { i -= 1 }
            return i
        case .lineStart:
            return line(o).location
        case .firstNonBlank:
            let r = line(o)
            var i = r.location
            while i < contentEnd(r), s.character(at: i) == 32 || s.character(at: i) == 9 { i += 1 }
            return i
        case .lineEnd:
            return lastCol(line(o))
        case .documentStart:
            return 0
        case .documentEnd:
            return line(max(0, len - 1)).location
        case .line(let n):
            guard let d = textView?.coordinator?.display else { return o }
            return d.displayOffset(SourcePos(line: max(0, n - 1), col: 0))
        case .screen(let which):
            guard let tv = textView, let lm = tv.layoutManager, let tc = tv.textContainer else { return o }
            let v = tv.visibleRect
            let y: CGFloat = which == 0 ? v.minY + 4 : which == 1 ? v.midY : v.maxY - 8
            let g = lm.glyphIndex(for: NSPoint(x: 0, y: y - tv.textContainerInset.height), in: tc)
            return line(lm.characterIndexForGlyph(at: g)).location
        case .paragraphForward, .paragraphBack:
            let forward: Bool = { if case .paragraphForward = m { return true }; return false }()
            var r = line(o)
            func blank(_ r: NSRange) -> Bool { s.substring(with: r).trimmingCharacters(in: .whitespacesAndNewlines).isEmpty }
            // Leave the current blank run, then stop at the next blank line.
            while true {
                if forward { guard NSMaxRange(r) < len else { return lastCol(r) }; r = line(NSMaxRange(r)) }
                else { guard r.location > 0 else { return 0 }; r = line(r.location - 1) }
                if blank(r) { return r.location }
            }
        case .matchBracket:
            let pairs: [UInt16: (UInt16, Bool)] = [40: (41, true), 91: (93, true), 123: (125, true), 41: (40, false), 93: (91, false), 125: (123, false)]
            let r = line(o)
            var i = o
            while i < contentEnd(r), pairs[s.character(at: i)] == nil { i += 1 }
            guard i < contentEnd(r), let (other, forward) = pairs[s.character(at: i)] else { return o }
            let open = s.character(at: i)
            var depth = 0
            var j = i
            while j >= 0 && j < len {
                let ch = s.character(at: j)
                if ch == open { depth += 1 } else if ch == other { depth -= 1; if depth == 0 { return j } }
                j += forward ? 1 : -1
            }
            return o
        case .find(let kind, let target):
            let r = line(o)
            let want = String(target).utf16.first ?? 0
            let forward = kind == "f" || kind == "t"
            var i = o + (forward ? 1 : -1)
            // Repeating a t/T from just before its target would not move; look one further.
            if kind == "t" { i += 1 } else if kind == "T" { i -= 1 }
            while i >= r.location && i < contentEnd(r) {
                if s.character(at: i) == want {
                    switch kind {
                    case "t": return i - 1
                    case "T": return i + 1
                    default: return i
                    }
                }
                i += forward ? 1 : -1
            }
            return o
        }
    }

    static func reverse(_ k: Character) -> Character {
        switch k { case "f": "F"; case "F": "f"; case "t": "T"; default: "t" }
    }

    /// 0 whitespace, 1 word characters, 2 punctuation; with `big`, anything not whitespace is 1.
    private func cls(_ i: Int, _ big: Bool) -> Int {
        let s = ns
        guard i >= 0, i < s.length, let u = UnicodeScalar(s.character(at: i)) else { return 0 }
        if CharacterSet.whitespacesAndNewlines.contains(u) { return 0 }
        if big { return 1 }
        return CharacterSet.alphanumerics.contains(u) || u == "_" ? 1 : 2
    }

    // MARK: Caret and selection

    private func setCaret(_ o: Int) {
        guard let tv = textView else { return }
        let len = (tv.string as NSString).length
        let c = max(0, min(o, max(0, len - 1)))
        visualCaret = c
        lastPlaced = c
        switch mode {
        case .normal:
            tv.setSelectedRange(NSRange(location: c, length: 0))
        case .visual(let a):
            let lo = min(a, c), hi = max(a, c)
            tv.setSelectedRange(NSRange(location: lo, length: min(len, hi + 1) - lo))
        case .visualLine(let a):
            let s = tv.string as NSString
            let r = s.lineRange(for: NSRange(location: min(a, c), length: abs(c - a) + 1))
            tv.setSelectedRange(r)
        }
        tv.scrollRangeToVisible(NSRange(location: c, length: 0))
    }

    private func toggleVisual(line: Bool) {
        let c = caret
        switch (mode, line) {
        case (.visual, false), (.visualLine, true): exitVisual(); return
        default: mode = line ? .visualLine(anchor: c) : .visual(anchor: c)
        }
        setCaret(c)
    }

    private func exitVisual() {
        let c = caret
        mode = .normal
        setCaret(c)
        textView?.needsDisplay = true
    }

    private func yank() {
        guard let tv = textView else { return }
        let r = tv.selectedRange()
        guard r.length > 0 else { return }
        NSPasteboard.general.clearContents()
        NSPasteboard.general.setString((tv.string as NSString).substring(with: r), forType: .string)
        let start = r.location
        goalColumn = nil
        mode = .normal
        setCaret(start)
        ws?.statusMessage = "Yanked \(r.length) characters"
    }

    // MARK: Search, scrolling, code intelligence

    private func finder(_ action: NSTextFinder.Action) {
        guard let tv = textView else { return }
        let item = NSMenuItem()
        item.tag = action.rawValue
        tv.performTextFinderAction(item)
    }

    private func searchWord(forward: Bool) {
        guard let tv = textView, let range = (tv.string as NSString).identifierRange(at: caret) else { return }
        let s = tv.string as NSString
        let word = s.substring(with: range)
        guard let re = try? NSRegularExpression(pattern: "\\b\(NSRegularExpression.escapedPattern(for: word))\\b") else { return }
        let all = re.matches(in: tv.string, range: NSRange(location: 0, length: s.length)).map(\.range.location)
        guard !all.isEmpty else { return }
        let next = forward ? (all.first { $0 > range.location } ?? all[0]) : (all.last { $0 < range.location } ?? all[all.count - 1])
        setCaret(next)
        ws?.statusMessage = "/\\<\(word)\\>"
    }

    private func scrollCaret(_ fraction: CGFloat) {
        guard let tv = textView, let lm = tv.layoutManager, let clip = tv.enclosingScrollView?.contentView else { return }
        let g = lm.glyphIndexForCharacter(at: min(caret, max(0, (tv.string as NSString).length - 1)))
        let rect = lm.lineFragmentRect(forGlyphAt: g, effectiveRange: nil)
        let y = rect.minY + tv.textContainerInset.height - clip.bounds.height * fraction + rect.height * fraction
        let maxY = max(0, tv.frame.height - clip.bounds.height)
        clip.setBoundsOrigin(NSPoint(x: clip.bounds.origin.x, y: min(maxY, max(0, y))))
        tv.enclosingScrollView?.reflectScrolledClipView(clip)
    }

    private func visibleLineCount() -> Int {
        guard let tv = textView, let lm = tv.layoutManager, lm.numberOfGlyphs > 0 else { return 40 }
        let h = lm.lineFragmentRect(forGlyphAt: 0, effectiveRange: nil).height
        return Int(tv.visibleRect.height / max(1, h))
    }

    private func realCaret() -> SourcePos? {
        guard let d = textView?.coordinator?.display else { return nil }
        return d.realPos(d.lines.position(of: caret))
    }

    private func showHover() {
        guard let tv = textView, let lm = tv.layoutManager, let tc = tv.textContainer else { return }
        let g = lm.glyphIndexForCharacter(at: caret)
        var r = lm.boundingRect(forGlyphRange: NSRange(location: g, length: 1), in: tc)
        r.origin.x += tv.textContainerInset.width
        r.origin.y += tv.textContainerInset.height
        // The glyph's leading edge, so the insertion index resolves to this character, not the next.
        tv.coordinator?.hover.showNow(at: NSPoint(x: r.minX + 1, y: r.midY))
    }

    /// A review comment on the caret's line, or on the selected lines in visual mode.
    private func comment() {
        guard let ws, let tv = textView, let d = tv.coordinator?.display else { return }
        var lines: ClosedRange<Int>?
        if mode != .normal {
            let sel = tv.selectedRange()
            let a = d.realPos(d.lines.position(of: sel.location))
            let b = d.realPos(d.lines.position(of: max(sel.location, NSMaxRange(sel) - 1)))
            if let a, let b { lines = (a.line + 1)...(b.line + 1) }
            exitVisual()
        }
        ws.draftComment(lines: lines)
    }
}
