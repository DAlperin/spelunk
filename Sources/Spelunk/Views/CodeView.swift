import AppKit
import SwiftUI

/// Read-only source view on TextKit 1 with a line-number / diff / marker gutter.
struct CodeView: NSViewRepresentable {
    let ws: Workspace
    let document: SourceDocument

    func makeCoordinator() -> Coordinator { Coordinator(ws: ws) }

    /// Fill whatever space is offered; the Auto Layout fitting size of the scroll view tracks its document.
    func sizeThatFits(_ proposal: ProposedViewSize, nsView: NSView, context: Context) -> CGSize? {
        CGSize(width: proposal.width ?? 400, height: proposal.height ?? 400)
    }

    func makeNSView(context: Context) -> NSView {
        let storage = NSTextStorage()
        let layout = NSLayoutManager()
        storage.addLayoutManager(layout)
        let container = NSTextContainer(size: NSSize(width: CGFloat.greatestFiniteMagnitude, height: .greatestFiniteMagnitude))
        container.widthTracksTextView = false
        layout.addTextContainer(container)
        let tv = SourceTextView(frame: .zero, textContainer: container)
        tv.coordinator = context.coordinator
        tv.isEditable = false
        tv.isSelectable = true
        tv.isRichText = false
        tv.usesFindBar = true
        tv.isIncrementalSearchingEnabled = true
        tv.drawsBackground = true
        tv.backgroundColor = Theme.background
        tv.textContainerInset = NSSize(width: 8, height: 8)
        tv.isHorizontallyResizable = true
        tv.isVerticallyResizable = true
        tv.maxSize = NSSize(width: CGFloat.greatestFiniteMagnitude, height: .greatestFiniteMagnitude)
        tv.autoresizingMask = [.width]
        tv.selectedTextAttributes = [.backgroundColor: NSColor.selectedTextBackgroundColor]
        layout.allowsNonContiguousLayout = false

        let scroll = NSScrollView()
        scroll.documentView = tv
        scroll.hasVerticalScroller = true
        scroll.hasHorizontalScroller = true
        scroll.autohidesScrollers = true
        scroll.drawsBackground = true
        scroll.backgroundColor = Theme.background
        scroll.automaticallyAdjustsContentInsets = false
        scroll.contentInsets = NSEdgeInsets()
        let gutter = GutterView(textView: tv, coordinator: context.coordinator)
        scroll.contentInsets = NSEdgeInsets(top: 0, left: gutter.thickness, bottom: 0, right: 0)
        let host = NSView()
        for o in [NSLayoutConstraint.Orientation.horizontal, .vertical] {
            host.setContentHuggingPriority(.defaultLow, for: o)
            host.setContentCompressionResistancePriority(.defaultLow, for: o)
        }
        scroll.translatesAutoresizingMaskIntoConstraints = false
        gutter.translatesAutoresizingMaskIntoConstraints = false
        host.addSubview(scroll)
        host.addSubview(gutter)
        NSLayoutConstraint.activate([
            scroll.leadingAnchor.constraint(equalTo: host.leadingAnchor),
            scroll.trailingAnchor.constraint(equalTo: host.trailingAnchor),
            scroll.topAnchor.constraint(equalTo: host.topAnchor),
            scroll.bottomAnchor.constraint(equalTo: host.bottomAnchor),
            gutter.leadingAnchor.constraint(equalTo: host.leadingAnchor),
            gutter.topAnchor.constraint(equalTo: host.topAnchor),
            gutter.bottomAnchor.constraint(equalTo: host.bottomAnchor),
            gutter.widthAnchor.constraint(equalToConstant: gutter.thickness),
        ])
        scroll.contentView.postsBoundsChangedNotifications = true
        NotificationCenter.default.addObserver(gutter, selector: #selector(GutterView.redraw), name: NSView.boundsDidChangeNotification, object: scroll.contentView)
        context.coordinator.textView = tv
        context.coordinator.gutter = gutter
        return host
    }

    func updateNSView(_ container: NSView, context: Context) {
        let c = context.coordinator
        c.ws = ws
        // Read the document from the workspace: SwiftUI may call this with a stale struct when only
        // workspace state (such as the reveal counter) changed.
        let document = ws.document ?? self.document
        guard let tv = c.textView else { return }
        if c.documentID != document.id {
            c.documentID = document.id
            c.document = document
            c.load(document, into: tv)
        }
        c.diffMarkers = ws.diffMarkers(for: document)
        c.diagnostics = document.revisionLabel == nil ? (ws.clippy.byFile[document.path] ?? []) : []
        c.traceLines = Set((ws.traces.active?.steps ?? []).filter { $0.location.path == document.path }.map(\.location.line))
        c.bookmarkedLines = Set(ws.bookmarks.items.filter { $0.location.path == document.path }.map(\.location.line))
        c.commentLines = ws.commentLines(for: document)
        c.applyBackgrounds(selection: ws.selection, highlights: ws.highlightRanges)
        if c.revealToken != ws.revealRequest {
            c.revealToken = ws.revealRequest
            if let sel = ws.selection { c.reveal(sel) }
        }
        c.gutter?.needsDisplay = true
    }

    @MainActor
    final class Coordinator {
        var ws: Workspace
        weak var textView: SourceTextView?
        weak var gutter: GutterView?
        var documentID: UUID?
        var document: SourceDocument?
        var revealToken = -1
        var diffMarkers: [Int: DiffLineKind] = [:]
        var diagnostics: [Diagnostic] = []
        var traceLines: Set<Int> = []
        var bookmarkedLines: Set<Int> = []
        /// Zero-based line -> true when an unresolved thread or pending comment sits there.
        var commentLines: [Int: Bool] = [:]
        private var lastBackgroundKey = ""

        init(ws: Workspace) { self.ws = ws }

        func load(_ doc: SourceDocument, into tv: NSTextView) {
            let font = Theme.codeFont
            let para = NSMutableParagraphStyle()
            para.lineHeightMultiple = 1.18
            para.tabStops = []
            para.defaultTabInterval = font.advancement(forGlyph: font.glyph(withName: "space")).width * 4
            let attr = NSMutableAttributedString(string: doc.text, attributes: [
                .font: font, .foregroundColor: Theme.text, .paragraphStyle: para,
            ])
            attr.beginEditing()
            let len = attr.length
            for t in doc.syntax.tokens where NSMaxRange(t.range) <= len {
                attr.addAttribute(.foregroundColor, value: Theme.color(t.kind), range: t.range)
                if t.kind == .docComment || t.kind == .comment {
                    attr.addAttribute(.font, value: NSFontManager.shared.convert(font, toHaveTrait: .italicFontMask), range: t.range)
                }
            }
            attr.endEditing()
            tv.textStorage?.setAttributedString(attr)
            if let lm = tv.layoutManager, let tc = tv.textContainer {
                lm.ensureLayout(for: tc)
                tv.sizeToFit()
            }
            tv.setSelectedRange(NSRange(location: 0, length: 0))
            lastBackgroundKey = ""
            gutter?.invalidateLineCache()
            tv.scroll(.zero)
        }

        func applyBackgrounds(selection: SourceRange?, highlights: [SourceRange]) {
            guard let tv = textView, let lm = tv.layoutManager, let doc = document else { return }
            let key = "\(documentID?.uuidString ?? "")|\(String(describing: selection))|\(highlights.count)|\(highlights.first.map { "\($0)" } ?? "")|\(diffMarkers.count)|\(traceLines.sorted())"
            if key == lastBackgroundKey { return }
            lastBackgroundKey = key
            let full = NSRange(location: 0, length: tv.textStorage?.length ?? 0)
            lm.removeTemporaryAttribute(.backgroundColor, forCharacterRange: full)
            func lineRange(_ l: Int) -> NSRange {
                let r = doc.lines.lineRange(l)
                return NSRange(location: r.location, length: min(r.length + 1, full.length - r.location))
            }
            for r in doc.syntax.testLineRanges {
                let a = doc.lines.lineRange(r.lowerBound).location
                let b = NSMaxRange(doc.lines.lineRange(r.upperBound))
                lm.addTemporaryAttribute(.backgroundColor, value: Theme.testRegion, forCharacterRange: NSRange(location: a, length: b - a))
            }
            for (line, kind) in diffMarkers where line < doc.lines.lineCount {
                lm.addTemporaryAttribute(.backgroundColor, value: kind == .added ? Theme.added : Theme.removed, forCharacterRange: lineRange(line))
            }
            for line in traceLines where line < doc.lines.lineCount && diffMarkers[line] == nil {
                lm.addTemporaryAttribute(.backgroundColor, value: Theme.traceLine, forCharacterRange: lineRange(line))
            }
            for h in highlights {
                let r = doc.lines.nsRange(h)
                if NSMaxRange(r) <= full.length { lm.addTemporaryAttribute(.backgroundColor, value: Theme.occurrence, forCharacterRange: r) }
            }
            if let sel = selection {
                lm.addTemporaryAttribute(.backgroundColor, value: Theme.currentLine, forCharacterRange: lineRange(sel.start.line))
                let r = doc.lines.nsRange(sel)
                if r.length > 0, NSMaxRange(r) <= full.length { lm.addTemporaryAttribute(.backgroundColor, value: Theme.target, forCharacterRange: r) }
            }
        }

        func reveal(_ range: SourceRange) {
            guard let doc = document else { return }
            let r = doc.lines.nsRange(range)
            // Defer one turn so a freshly loaded document has a laid-out frame to scroll within.
            DispatchQueue.main.async { [weak self] in
                guard let self, let tv = self.textView, let lm = tv.layoutManager, let tc = tv.textContainer,
                      let clip = tv.enclosingScrollView?.contentView, NSMaxRange(r) <= (tv.textStorage?.length ?? 0) else { return }
                let glyphs = lm.glyphRange(forCharacterRange: NSRange(location: r.location, length: max(1, min(r.length, (tv.textStorage?.length ?? 1) - r.location))), actualCharacterRange: nil)
                lm.ensureLayout(forGlyphRange: NSRange(location: 0, length: NSMaxRange(glyphs)))
                var rect = lm.boundingRect(forGlyphRange: glyphs, in: tc)
                rect.origin.y += tv.textContainerInset.height
                let visible = clip.bounds
                let maxY = max(0, tv.frame.height - visible.height)
                let y = min(maxY, max(0, rect.midY - visible.height * 0.35))
                let x = rect.maxX + 40 > visible.width - 72 ? max(0, rect.minX - 80) : 0
                let left = tv.enclosingScrollView?.contentInsets.left ?? 0
                clip.setBoundsOrigin(NSPoint(x: x - left, y: y))
                tv.enclosingScrollView?.reflectScrolledClipView(clip)
                self.gutter?.needsDisplay = true
            }
        }

        func position(at point: NSPoint) -> SourcePos? {
            guard let tv = textView, let doc = document else { return nil }
            let idx = tv.characterIndexForInsertion(at: point)
            guard idx <= doc.ns.length else { return nil }
            return doc.lines.position(of: idx)
        }

        func click(at p: SourcePos, command: Bool) {
            if command { ws.goToDefinition(at: p) } else { ws.didClick(at: p) }
        }

        func menu(at p: SourcePos) -> NSMenu {
            ws.didClick(at: p)
            let m = NSMenu()
            let word = document?.word(at: p)?.0
            func item(_ title: String, _ action: @escaping () -> Void) {
                let i = ClosureMenuItem(title: title, action: action)
                m.addItem(i)
            }
            if let word {
                item("Go to Definition of \(word)") { [ws] in ws.goToDefinition(at: p) }
                item("Show Callers") { [ws] in
                    if let c = ws.context { c.callDirection = .incoming; Task { await ws.loadCalls(c) } }
                }
                item("Show Callees") { [ws] in
                    if let c = ws.context { c.callDirection = .outgoing; Task { await ws.loadCalls(c) } }
                }
                m.addItem(.separator())
            }
            item("Add to Code Path") { [ws] in ws.addCurrentToTrace() }
            item("New Code Path from Here") { [ws] in ws.newCodePath(fromCursor: true) }
            item("Toggle Bookmark") { [ws] in ws.toggleBookmark() }
            if ws.review?.pullRequest != nil {
                item("Add Review Comment…") { [ws] in ws.draftComment() }
            }
            m.addItem(.separator())
            item("Ask Claude About This…") { [ws] in ws.showAsk = true }
            if let word {
                item("Generate Code Path for “\(word)” with Claude") { [ws] in
                    ws.generateTrace("How does `\(word)` get invoked, and what does it do end to end?", includeAnchor: true)
                }
            }
            return m
        }
    }
}

final class ClosureMenuItem: NSMenuItem {
    private let closure: () -> Void
    init(title: String, action: @escaping () -> Void) {
        closure = action
        super.init(title: title, action: #selector(fire), keyEquivalent: "")
        target = self
    }
    required init(coder: NSCoder) { fatalError() }
    @objc private func fire() { closure() }
}

final class SourceTextView: NSTextView {
    weak var coordinator: CodeView.Coordinator?

    override func mouseDown(with event: NSEvent) {
        super.mouseDown(with: event)
        guard event.clickCount == 1, selectedRange().length == 0 else { return }
        let p = convert(event.locationInWindow, from: nil)
        let cmd = event.modifierFlags.contains(.command)
        MainActor.assumeIsolated {
            if let pos = coordinator?.position(at: p) { coordinator?.click(at: pos, command: cmd) }
        }
    }

    override func menu(for event: NSEvent) -> NSMenu? {
        let p = convert(event.locationInWindow, from: nil)
        return MainActor.assumeIsolated {
            guard let pos = coordinator?.position(at: p) else { return super.menu(for: event) }
            return coordinator?.menu(at: pos)
        }
    }

    override func flagsChanged(with event: NSEvent) {
        super.flagsChanged(with: event)
        if event.modifierFlags.contains(.command) { NSCursor.pointingHand.set() } else { NSCursor.iBeam.set() }
    }
}

/// Line numbers plus markers: diff (+/-), diagnostics, trace steps and bookmarks. Overlays the left
/// edge of the scroll view, which reserves the space with a content inset.
final class GutterView: NSView {
    weak var textView: NSTextView?
    weak var coordinator: CodeView.Coordinator?
    let thickness: CGFloat = 72

    init(textView: NSTextView, coordinator: CodeView.Coordinator) {
        self.textView = textView
        self.coordinator = coordinator
        super.init(frame: .zero)
    }

    required init?(coder: NSCoder) { fatalError() }

    override var isFlipped: Bool { true }

    @objc func redraw() { needsDisplay = true }

    func invalidateLineCache() { needsDisplay = true }

    override func draw(_ dirtyRect: NSRect) {
        Theme.gutter.setFill()
        bounds.fill()
        guard let tv = textView, let lm = tv.layoutManager, let tc = tv.textContainer else { return }
        let (diff, diags, trace, marks, doc, selLine, comments) = MainActor.assumeIsolated {
            (coordinator?.diffMarkers ?? [:], coordinator?.diagnostics ?? [], coordinator?.traceLines ?? [],
             coordinator?.bookmarkedLines ?? [], coordinator?.document, coordinator?.ws.cursor?.line, coordinator?.commentLines ?? [:])
        }
        guard let doc, doc.ns.length > 0 else { return }
        let visible = tv.visibleRect
        let glyphRange = lm.glyphRange(forBoundingRect: visible, in: tc)
        let charRange = lm.characterRange(forGlyphRange: glyphRange, actualGlyphRange: nil)
        let font = NSFont.monospacedDigitSystemFont(ofSize: max(9, Theme.codeFont.pointSize - 2), weight: .regular)
        let attrs: [NSAttributedString.Key: Any] = [.font: font, .foregroundColor: Theme.gutterText]
        let boldAttrs: [NSAttributedString.Key: Any] = [.font: NSFont.monospacedDigitSystemFont(ofSize: font.pointSize, weight: .bold), .foregroundColor: Theme.text]
        let diagLines = Dictionary(grouping: diags, by: { $0.location.line })
        var line = doc.lines.position(of: charRange.location).line
        let inset = tv.textContainerInset.height
        while line < doc.lines.lineCount {
            let start = doc.lines.starts[line]
            if start > NSMaxRange(charRange) { break }
            let g = lm.glyphIndexForCharacter(at: min(start, doc.ns.length - 1))
            var lineRect = lm.lineFragmentRect(forGlyphAt: g, effectiveRange: nil, withoutAdditionalLayout: true)
            if start >= doc.ns.length { lineRect = lm.extraLineFragmentRect }
            let y = convert(NSPoint(x: 0, y: lineRect.minY + inset), from: tv).y
            let h = lineRect.height
            if let k = diff[line] {
                (k == .added ? Theme.addedMarker : Theme.removedMarker).setFill()
                NSRect(x: thickness - 3, y: y, width: 3, height: h).fill()
            }
            if let d = diagLines[line]?.first {
                (d.level == .error ? NSColor.systemRed : NSColor.systemYellow).setFill()
                NSBezierPath(ovalIn: NSRect(x: 17, y: y + h / 2 - 3, width: 6, height: 6)).fill()
            }
            if trace.contains(line) {
                NSColor.systemPurple.setFill()
                NSBezierPath(roundedRect: NSRect(x: 25, y: y + h / 2 - 3, width: 6, height: 6), xRadius: 1, yRadius: 1).fill()
            }
            if let open = comments[line] {
                let img = NSImage(systemSymbolName: open ? "bubble.left.fill" : "bubble.left", accessibilityDescription: nil)
                let tinted = img?.withSymbolConfiguration(.init(paletteColors: [open ? .systemOrange : .secondaryLabelColor]))
                tinted?.draw(in: NSRect(x: 3, y: y + h / 2 - 5, width: 11, height: 10))
            }
            if marks.contains(line) {
                NSColor.systemBlue.setFill()
                NSRect(x: 33, y: y + 2, width: 3, height: h - 4).fill()
            }
            let str = NSAttributedString(string: "\(line + 1)", attributes: line == selLine ? boldAttrs : attrs)
            let size = str.size()
            str.draw(at: NSPoint(x: thickness - size.width - 8, y: y + (h - size.height) / 2))
            line += 1
        }
    }

    override func mouseDown(with event: NSEvent) {
        guard let tv = textView, let lm = tv.layoutManager, let tc = tv.textContainer else { return }
        let p = tv.convert(event.locationInWindow, from: nil)
        let idx = lm.characterIndex(for: NSPoint(x: 0, y: p.y - tv.textContainerInset.height), in: tc, fractionOfDistanceBetweenInsertionPoints: nil)
        MainActor.assumeIsolated {
            guard let c = coordinator, let doc = c.document else { return }
            let line = doc.lines.position(of: idx).line
            c.ws.cursor = SourcePos(line: line, col: 0)
            if event.clickCount == 2 { c.ws.toggleBookmark() }
            needsDisplay = true
        }
    }
}
