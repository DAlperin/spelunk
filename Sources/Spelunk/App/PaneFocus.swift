import AppKit

/// Vim-style window commands: Ctrl-w, then a key, moves keyboard focus between the window's panes
/// (the sidebar list, the code view and its split partner, the inspector's list), ordered left to right.
@MainActor
enum PaneFocus {
    /// When Ctrl-w was pressed, while waiting for the key after it.
    private static var pendingSince: TimeInterval?
    /// The pane focused before the last move, for Ctrl-w p.
    private static weak var previous: NSView?

    /// Handles Ctrl-w and the key that follows it; true when the event was used.
    static func handle(_ event: NSEvent, window: NSWindow) -> Bool {
        let mods = event.modifierFlags.intersection([.command, .option, .control])
        if let since = pendingSince {
            pendingSince = nil
            guard event.timestamp - since < 2, !mods.contains(.command), !mods.contains(.option) else { return false }
            let shift = event.modifierFlags.contains(.shift)
            switch event.charactersIgnoringModifiers?.lowercased() ?? "" {
            case "h": move(window, by: -1)
            case "l": move(window, by: 1)
            case "w": move(window, by: shift ? -1 : 1, wrap: true)
            case "p": if let p = previous, p.window === window { focus(p, in: window) }
            case "\u{1b}": break
            default: NSSound.beep()
            }
            return true
        }
        if mods == [.control], event.charactersIgnoringModifiers?.lowercased() == "w" {
            pendingSince = event.timestamp
            return true
        }
        return false
    }

    static func focusCodeView(_ window: NSWindow) {
        if let tv = targets(in: window).first(where: { ($0 as? SourceTextView)?.coordinator?.secondary == false }) { focus(tv, in: window) }
    }

    static func focusSidebar(_ window: NSWindow) { if let t = targets(in: window).first, !(t is SourceTextView) { focus(t, in: window) } }

    static func focusInspector(_ window: NSWindow) { if let t = targets(in: window).last, !(t is SourceTextView) { focus(t, in: window) } }

    private static func move(_ window: NSWindow, by step: Int, wrap: Bool = false) {
        let all = targets(in: window)
        guard !all.isEmpty else { return }
        let current = window.firstResponder as? NSView
        let index: Int
        if let current, let i = all.firstIndex(where: { current === $0 || current.isDescendant(of: $0) }) {
            index = i + step
        } else if let current {
            // Focus on something outside every pane: measure from where it is.
            let x = midX(current)
            index = step > 0 ? (all.firstIndex { midX($0) > x } ?? all.count) : ((all.lastIndex { midX($0) < x }) ?? -1)
        } else {
            // Nothing focused: right goes to the code view, left to the sidebar.
            let editor = all.firstIndex { ($0 as? SourceTextView)?.coordinator?.secondary == false }
            index = step > 0 ? (editor ?? 0) : 0
        }
        let target = wrap ? all[(index % all.count + all.count) % all.count] : all[safe: index]
        guard let target else { NSSound.beep(); return }
        focus(target, in: window)
    }

    private static func focus(_ view: NSView, in window: NSWindow) {
        previous = window.firstResponder as? NSView
        window.makeFirstResponder(view)
        if let tv = view as? SourceTextView { tv.scrollRangeToVisible(tv.selectedRange()) }
    }

    /// The views a pane move can land on, left to right: visible lists, and the code views. Of several
    /// lists in one pane, the largest stands for it.
    private static func targets(in window: NSWindow) -> [NSView] {
        guard let root = window.contentView else { return [] }
        var editors: [NSView] = [], lists: [NSView] = []
        func walk(_ v: NSView) {
            if v.isHiddenOrHasHiddenAncestor || v.visibleRect.isEmpty { return }
            if v is SourceTextView { editors.append(v); return }
            if v is NSTableView { lists.append(v); return }
            v.subviews.forEach(walk)
        }
        walk(root)
        guard let left = editors.map({ frame($0).minX }).min(), let right = editors.map({ frame($0).maxX }).max() else {
            return lists.sorted { midX($0) < midX($1) }
        }
        func biggest(_ vs: [NSView]) -> NSView? { vs.max { area($0) < area($1) } }
        let sidebar = biggest(lists.filter { frame($0).maxX <= left + 1 })
        let inspector = biggest(lists.filter { frame($0).minX >= right - 1 })
        return [sidebar].compactMap { $0 } + editors.sorted { midX($0) < midX($1) } + [inspector].compactMap { $0 }
    }

    /// A view's visible part, in window coordinates.
    private static func frame(_ v: NSView) -> NSRect { v.convert(v.visibleRect, to: nil) }
    private static func midX(_ v: NSView) -> CGFloat { frame(v).midX }
    private static func area(_ v: NSView) -> CGFloat { let f = frame(v); return f.width * f.height }
}
