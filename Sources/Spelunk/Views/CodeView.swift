import AppKit
import SwiftUI

/// Read-only source view on TextKit 1 with a line-number / diff / marker gutter.
struct CodeView: NSViewRepresentable {
    let ws: Workspace
    let document: SourceDocument
    /// The split view's old-side pane: shows `document` as given, follows the main editor's scrolling,
    /// and does not drive navigation.
    var secondary = false

    func makeCoordinator() -> Coordinator { Coordinator(ws: ws, secondary: secondary) }

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
        // Wide lines still scroll with the trackpad; an overlay horizontal scroller would cover the last line.
        scroll.hasHorizontalScroller = false
        scroll.autohidesScrollers = true
        scroll.drawsBackground = true
        scroll.backgroundColor = Theme.background
        scroll.automaticallyAdjustsContentInsets = false
        scroll.contentInsets = NSEdgeInsets()
        let gutter = GutterView(textView: tv, coordinator: context.coordinator)
        scroll.contentInsets = NSEdgeInsets(top: 0, left: gutter.thickness, bottom: 0, right: 0)
        let host = NSView()
        host.clipsToBounds = true
        for o in [NSLayoutConstraint.Orientation.horizontal, .vertical] {
            host.setContentHuggingPriority(.defaultLow, for: o)
            host.setContentCompressionResistancePriority(.defaultLow, for: o)
        }
        scroll.translatesAutoresizingMaskIntoConstraints = false
        gutter.translatesAutoresizingMaskIntoConstraints = false
        host.addSubview(scroll)
        host.addSubview(gutter)
        let minimap = MinimapView(textView: tv, coordinator: context.coordinator)
        minimap.translatesAutoresizingMaskIntoConstraints = false
        host.addSubview(minimap)
        let mapWidth = minimap.widthAnchor.constraint(equalToConstant: secondary || !Prefs.minimap ? 0 : CGFloat(Prefs.minimapWidth))
        context.coordinator.minimapWidth = mapWidth
        NSLayoutConstraint.activate([
            minimap.trailingAnchor.constraint(equalTo: host.trailingAnchor),
            minimap.topAnchor.constraint(equalTo: host.topAnchor),
            minimap.bottomAnchor.constraint(equalTo: host.bottomAnchor),
            mapWidth,
            scroll.leadingAnchor.constraint(equalTo: host.leadingAnchor),
            scroll.trailingAnchor.constraint(equalTo: minimap.leadingAnchor),
            scroll.topAnchor.constraint(equalTo: host.topAnchor),
            scroll.bottomAnchor.constraint(equalTo: host.bottomAnchor),
            gutter.leadingAnchor.constraint(equalTo: host.leadingAnchor),
            gutter.topAnchor.constraint(equalTo: host.topAnchor),
            gutter.bottomAnchor.constraint(equalTo: host.bottomAnchor),
            gutter.widthAnchor.constraint(equalToConstant: gutter.thickness),
        ])
        scroll.contentView.postsBoundsChangedNotifications = true
        NotificationCenter.default.addObserver(gutter, selector: #selector(GutterView.redraw), name: NSView.boundsDidChangeNotification, object: scroll.contentView)
        NotificationCenter.default.addObserver(minimap, selector: #selector(MinimapView.redraw), name: NSView.boundsDidChangeNotification, object: scroll.contentView)
        context.coordinator.minimap = minimap
        context.coordinator.textView = tv
        context.coordinator.hover.textView = tv
        context.coordinator.gutter = gutter
        context.coordinator.observeScrolling(scroll.contentView)
        return host
    }

    func updateNSView(_ container: NSView, context: Context) {
        let c = context.coordinator
        c.ws = ws
        // Read the document from the workspace: SwiftUI may call this with a stale struct when only
        // workspace state (such as the reveal counter) changed.
        let document = secondary ? self.document : (ws.document ?? self.document)
        guard let tv = c.textView else { return }
        let phantoms = secondary ? [:] : ws.phantomLines(for: document)
        let specs = secondary ? [] : ws.inlineBlocks(for: document)
        c.blockSpecs = specs
        let display = DisplayDoc(doc: document, phantoms: phantoms, blocks: c.blocks(for: specs))
        if c.documentID != document.id {
            c.documentID = document.id
            c.document = document
            c.display = display
            c.load(display, into: tv, keepScroll: false)
        } else if c.display?.fingerprint != display.fingerprint {
            // Same file, different inline diff (live refresh or toggled): keep the scroll position.
            c.display = display
            c.load(display, into: tv, keepScroll: true)
        }
        c.diffMarkers = ws.diffMarkers(for: document)
        c.diagnostics = !secondary && document.isWorkingCopy ? (ws.clippy.byFile[document.path] ?? []) : []
        let markers = secondary ? (badges: [Int: Int](), pills: [Int: Int]()) : ws.pathMarkers(for: document)
        c.stepBadges = markers.badges
        c.stepPills = markers.pills
        c.currentStepLine = ws.traces.currentStep.flatMap { i in ws.traces.active?.steps[safe: i] }.flatMap { $0.location.path == document.path ? $0.location.line : nil }
        tv.needsDisplay = true
        c.traceLines = secondary ? [] : Set((ws.traces.active?.steps ?? []).filter { $0.location.path == document.path }.map(\.location.line))
        c.bookmarkedLines = secondary ? [] : Set(ws.bookmarks.items.filter { $0.location.path == document.path }.map(\.location.line))
        c.commentLines = secondary ? [:] : ws.commentLines(for: document)
        if secondary {
            c.applyBackgrounds(selection: nil, highlights: [])
            if c.revealToken != ws.splitRevealRequest {
                c.revealToken = ws.splitRevealRequest
                c.reveal(SourceRange(line: ws.splitRevealLine))
            }
        } else {
            c.applyBackgrounds(selection: ws.selection, highlights: ws.highlightRanges)
            if c.revealToken != ws.revealRequest {
                c.revealToken = ws.revealRequest
                if let sel = ws.selection { c.reveal(sel) }
            }
        }
        c.layoutBlocks()
        if !secondary, let display = c.display, let r = ws.review {
            // Regions change with the display, the selection and the tiers.
            let key = "\(document.id)|\(display.fingerprint)|\(ws.selectedHunkID ?? "")|\(r.files.count)|\(r.llm.count)|\(r.analyses.count)"
            if c.hunkRegionsKey != key {
                c.hunkRegionsKey = key
                c.hunkRegions = c.computeHunkRegions(ws: ws, document: document, display: display)
            }
        } else {
            c.hunkRegions = []
            c.hunkRegionsKey = ""
        }
        let width: CGFloat = secondary || !Prefs.minimap ? 0 : CGFloat(Prefs.minimapWidth)
        if c.minimapWidth?.constant != width { c.minimapWidth?.constant = width }
        c.gutter?.needsDisplay = true
        c.minimap?.needsDisplay = true
    }

    @MainActor
    final class Coordinator {
        /// Embedded views (threads, composer) and the display lines reserved for each.
        var blockSpecs: [(id: String, afterLine: Int)] = []
        private var blockHeights: [String: Int] = [:]
        private var hosts: [String: NSHostingController<InlineBlockView>] = [:]
        static let blockWidth: CGFloat = 680

        func blocks(for specs: [(id: String, afterLine: Int)]) -> [DisplayDoc.Block] {
            specs.map { DisplayDoc.Block(id: $0.id, afterLine: $0.afterLine, lines: blockHeights[$0.id] ?? 3) }
        }

        private var lineHeight: CGFloat {
            guard let tv = textView, let lm = tv.layoutManager, lm.numberOfGlyphs > 0 else { return 18 }
            return lm.lineFragmentRect(forGlyphAt: 0, effectiveRange: nil).height
        }

        /// Places a hosting view over each block's reserved lines; if a view needs a different
        /// number of lines than reserved, reserves again and reloads (keeping the scroll position).
        func layoutBlocks() {
            guard let tv = textView, let lm = tv.layoutManager, let display, let doc = document else { return }
            let ids = Set(blockSpecs.map(\.id))
            for (id, h) in hosts where !ids.contains(id) { h.view.removeFromSuperview(); hosts[id] = nil }
            let lh = lineHeight
            var changed = false
            for spec in blockSpecs {
                let host = hosts[spec.id] ?? {
                    let h = NSHostingController(rootView: InlineBlockView(ws: ws, id: spec.id))
                    h.sizingOptions = []
                    hosts[spec.id] = h
                    tv.addSubview(h.view)
                    return h
                }()
                host.rootView = InlineBlockView(ws: ws, id: spec.id)
                let size = host.sizeThatFits(in: CGSize(width: Self.blockWidth, height: 2000))
                let needed = max(1, Int(ceil((size.height + 8) / lh)))
                if blockHeights[spec.id] != needed { blockHeights[spec.id] = needed; changed = true }
                guard let range = display.blockLines[spec.id], range.lowerBound < display.lines.lineCount else { host.view.isHidden = true; continue }
                let off = display.lines.starts[range.lowerBound]
                let g = lm.glyphIndexForCharacter(at: min(off, max(0, display.ns.length - 1)))
                let rect = lm.lineFragmentRect(forGlyphAt: g, effectiveRange: nil)
                host.view.isHidden = false
                host.view.frame = NSRect(x: tv.textContainerInset.width + 28, y: rect.minY + tv.textContainerInset.height + 3,
                                         width: Self.blockWidth, height: CGFloat(range.count) * lh - 6)
            }
            if changed {
                let rebuilt = DisplayDoc(doc: doc, phantoms: secondary ? [:] : ws.phantomLines(for: doc), blocks: blocks(for: blockSpecs))
                self.display = rebuilt
                load(rebuilt, into: tv, keepScroll: true)
                DispatchQueue.main.async { [weak self] in self?.layoutBlocks() }
            }
        }

        var ws: Workspace
        weak var textView: SourceTextView?
        weak var gutter: GutterView?
        weak var minimap: MinimapView?
        let hover = HoverController()
        /// Follows the minimap preferences while the editor is open.
        var minimapWidth: NSLayoutConstraint?
        var hunkRegions: [HunkRegion] = []
        var hunkRegionsKey = ""
        var minimapWidths: [LineShape] = []
        var documentID: UUID?
        var document: SourceDocument?
        var display: DisplayDoc?
        var revealToken = -1
        var diffMarkers: [Int: DiffLineKind] = [:]
        var diagnostics: [Diagnostic] = []
        var traceLines: Set<Int> = []
        var bookmarkedLines: Set<Int> = []
        /// Line -> step number for steps of the active code path in this file.
        var stepBadges: [Int: Int] = [:]
        /// Line -> step number a call site on that line leads to.
        var stepPills: [Int: Int] = [:]
        var currentStepLine: Int?
        /// Zero-based line -> true when an unresolved thread or pending comment sits there.
        var commentLines: [Int: Bool] = [:]
        private var lastBackgroundKey = ""

        let secondary: Bool
        private var syncing = false

        init(ws: Workspace, secondary: Bool) {
            self.ws = ws
            self.secondary = secondary
        }

        /// Split view: the main pane reports its top line; the old-side pane scrolls to match.
        func observeScrolling(_ clip: NSClipView) {
            if secondary {
                ws.splitScroller = { [weak self] oldLine in self?.scrollTop(toRealLine: oldLine) }
                return
            }
            NotificationCenter.default.addObserver(forName: NSView.boundsDidChangeNotification, object: clip, queue: .main) { [weak self] _ in
                MainActor.assumeIsolated { self?.reportTopLine() }
            }
        }

        private func reportTopLine() {
            guard !syncing, ws.diffMode == .split, let scroller = ws.splitScroller, let tv = textView, let lm = tv.layoutManager,
                  let tc = tv.textContainer, let display, let doc = document else { return }
            let visible = tv.visibleRect
            let g = lm.glyphIndex(for: NSPoint(x: 0, y: visible.minY + 4), in: tc)
            let idx = lm.characterIndexForGlyph(at: g)
            let dline = display.lines.position(of: min(idx, display.ns.length)).line
            let real: Int
            switch display.entry(dline) {
            case .real(let l): real = l
            default: real = (display.realPos(SourcePos(line: dline + 1, col: 0))?.line) ?? 0
            }
            scroller(ws.oldLine(forNew: real, path: doc.path))
        }

        func scrollTop(toRealLine line: Int) {
            guard let tv = textView, let lm = tv.layoutManager, let display, let clip = tv.enclosingScrollView?.contentView,
                  display.ns.length > 0 else { return }
            let off = display.lines.offset(of: SourcePos(line: display.displayLine(line), col: 0))
            let g = lm.glyphIndexForCharacter(at: min(off, display.ns.length - 1))
            let rect = lm.lineFragmentRect(forGlyphAt: g, effectiveRange: nil)
            syncing = true
            clip.setBoundsOrigin(NSPoint(x: clip.bounds.origin.x, y: max(0, rect.minY + tv.textContainerInset.height - 4)))
            tv.enclosingScrollView?.reflectScrolledClipView(clip)
            syncing = false
            gutter?.needsDisplay = true
        }

        func load(_ display: DisplayDoc, into tv: NSTextView, keepScroll: Bool) {
            let doc = display.doc
            let font = Theme.codeFont
            let italic = NSFontManager.shared.convert(font, toHaveTrait: .italicFontMask)
            let para = NSMutableParagraphStyle()
            para.lineHeightMultiple = Prefs.lineSpacing
            para.tabStops = []
            para.defaultTabInterval = font.advancement(forGlyph: font.glyph(withName: "space")).width * CGFloat(Prefs.tabWidth)
            let attr = NSMutableAttributedString(string: display.text, attributes: [
                .font: font, .foregroundColor: Theme.text, .paragraphStyle: para,
            ])
            attr.beginEditing()
            let len = attr.length
            func paint(_ range: NSRange, _ kind: TokenKind) {
                guard range.length > 0, NSMaxRange(range) <= len else { return }
                attr.addAttribute(.foregroundColor, value: Theme.color(kind), range: range)
                if kind == .docComment || kind == .comment { attr.addAttribute(.font, value: italic, range: range) }
            }
            for t in doc.syntax.tokens {
                let a = display.displayOffset(realOffset: t.range.location)
                let b = display.displayOffset(realOffset: NSMaxRange(t.range))
                paint(NSRange(location: a, length: b - a), t.kind)
            }
            for (i, e) in display.entries.enumerated() {
                guard case .phantom(let p) = e else { continue }
                let start = display.lines.starts[i]
                for t in p.tokens { paint(NSRange(location: start + t.range.location, length: t.range.length), t.kind) }
            }
            attr.endEditing()
            let origin = tv.enclosingScrollView?.contentView.bounds.origin
            tv.textStorage?.setAttributedString(attr)
            minimapWidths = Self.shapes(display)
            if let lm = tv.layoutManager, let tc = tv.textContainer {
                lm.ensureLayout(for: tc)
                tv.sizeToFit()
            }
            tv.setSelectedRange(NSRange(location: 0, length: 0))
            lastBackgroundKey = ""
            gutter?.invalidateLineCache()
            if keepScroll, let origin, let clip = tv.enclosingScrollView?.contentView {
                clip.setBoundsOrigin(origin)
                tv.enclosingScrollView?.reflectScrolledClipView(clip)
            } else {
                tv.scroll(.zero)
            }
        }

        func applyBackgrounds(selection: SourceRange?, highlights: [SourceRange]) {
            guard let tv = textView, let lm = tv.layoutManager, let doc = document, let display else { return }
            let key = "\(documentID?.uuidString ?? "")|\(display.fingerprint)|\(String(describing: selection))|\(highlights.count)|\(highlights.first.map { "\($0)" } ?? "")|\(diffMarkers.count)|\(traceLines.sorted())"
            if key == lastBackgroundKey { return }
            lastBackgroundKey = key
            let full = NSRange(location: 0, length: tv.textStorage?.length ?? 0)
            lm.removeTemporaryAttribute(.backgroundColor, forCharacterRange: full)
            func displayLineRange(_ dl: Int) -> NSRange {
                let r = display.lines.lineRange(dl)
                return NSRange(location: r.location, length: min(r.length + 1, full.length - r.location))
            }
            func lineRange(_ real: Int) -> NSRange { displayLineRange(display.displayLine(real)) }
            for r in doc.syntax.testLineRanges {
                let a = lineRange(r.lowerBound).location
                let b = NSMaxRange(display.lines.lineRange(display.displayLine(r.upperBound)))
                lm.addTemporaryAttribute(.backgroundColor, value: Theme.testRegion, forCharacterRange: NSRange(location: a, length: max(0, b - a)))
            }
            for (line, kind) in diffMarkers where line < doc.lines.lineCount {
                lm.addTemporaryAttribute(.backgroundColor, value: kind == .added ? Theme.added : Theme.removed, forCharacterRange: lineRange(line))
            }
            for (i, e) in display.entries.enumerated() {
                guard case .phantom(let p) = e else { continue }
                lm.addTemporaryAttribute(.backgroundColor, value: p.kind == .added ? Theme.added : Theme.removed, forCharacterRange: displayLineRange(i))
            }
            for line in traceLines where line < doc.lines.lineCount && diffMarkers[line] == nil {
                lm.addTemporaryAttribute(.backgroundColor, value: Theme.traceLine, forCharacterRange: lineRange(line))
            }
            for h in highlights {
                let r = display.displayRange(h)
                if NSMaxRange(r) <= full.length { lm.addTemporaryAttribute(.backgroundColor, value: Theme.occurrence, forCharacterRange: r) }
            }
            if let sel = selection {
                lm.addTemporaryAttribute(.backgroundColor, value: Theme.currentLine, forCharacterRange: lineRange(sel.start.line))
                let r = display.displayRange(sel)
                if r.length > 0, NSMaxRange(r) <= full.length { lm.addTemporaryAttribute(.backgroundColor, value: Theme.target, forCharacterRange: r) }
            }
        }

        func reveal(_ range: SourceRange) {
            guard let display else { return }
            let r = display.displayRange(range)
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

        /// Real document position under a point; nil over a phantom (other-side) line.
        func position(at point: NSPoint) -> SourcePos? {
            guard let tv = textView, let display else { return nil }
            let idx = tv.characterIndexForInsertion(at: point)
            guard idx <= display.ns.length else { return nil }
            return display.realPos(display.lines.position(of: idx))
        }

        func click(at p: SourcePos, command: Bool) {
            guard !secondary else { return }
            if command { ws.goToDefinition(at: p) } else { ws.didClick(at: p) }
        }

        func menu(at p: SourcePos) -> NSMenu {
            guard !secondary else { return NSMenu() }
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
            item("Ask Claude About This…") { [ws] in ws.openAsk() }
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

    /// "→ step N" pills after call sites that lead to another step of the active code path.
    override func draw(_ dirtyRect: NSRect) {
        super.draw(dirtyRect)
        drawHunkBoundary(dirtyRect)
        let (pills, display) = (coordinator?.stepPills ?? [:], coordinator?.display)
        guard !pills.isEmpty, let display, let lm = layoutManager, display.ns.length > 0 else { return }
        let font = NSFont.systemFont(ofSize: 9.5, weight: .semibold)
        for (line, step) in pills {
            let dl = display.displayLine(line)
            let r = display.lines.lineRange(dl)
            let glyphs = lm.glyphRange(forCharacterRange: NSRange(location: r.location, length: max(1, r.length)), actualCharacterRange: nil)
            guard glyphs.location < lm.numberOfGlyphs else { continue }
            var used = lm.lineFragmentUsedRect(forGlyphAt: glyphs.location, effectiveRange: nil)
            used.origin.y += textContainerInset.height
            used.origin.x += textContainerInset.width
            if r.length > 0, let tc = textContainer {
                let end = lm.boundingRect(forGlyphRange: NSRange(location: max(glyphs.location, NSMaxRange(glyphs) - 1), length: 1), in: tc)
                used.size.width = end.maxX
            }
            guard used.intersects(dirtyRect.insetBy(dx: -400, dy: -20)) else { continue }
            let label = NSAttributedString(string: "→ step \(step)", attributes: [.font: font, .foregroundColor: NSColor.systemPurple])
            let sz = label.size()
            let box = NSRect(x: used.maxX + 12, y: used.midY - sz.height / 2 - 2, width: sz.width + 10, height: sz.height + 4)
            NSColor.systemPurple.withAlphaComponent(0.16).setFill()
            NSBezierPath(roundedRect: box, xRadius: 4, yRadius: 4).fill()
            label.draw(at: NSPoint(x: box.minX + 5, y: box.minY + 2))
        }
    }

    /// The selected review hunk: a tier-colored bar down its left edge and hairlines above and below.
    private func drawHunkBoundary(_ dirtyRect: NSRect) {
        guard Prefs.hunkBoundary else { return }
        let (region, display) = (coordinator?.hunkRegions.first(where: \.selected), coordinator?.display)
        guard let region, let display, let lm = layoutManager, display.ns.length > 0 else { return }
        func fragment(_ dl: Int) -> NSRect {
            let off = display.lines.starts[min(dl, display.lines.lineCount - 1)]
            let g = lm.glyphIndexForCharacter(at: min(off, display.ns.length - 1))
            var r = lm.lineFragmentRect(forGlyphAt: g, effectiveRange: nil, withoutAdditionalLayout: true)
            r.origin.y += textContainerInset.height
            return r
        }
        let top = fragment(region.lines.lowerBound).minY, bottom = fragment(region.lines.upperBound).maxY
        let box = NSRect(x: 0, y: top, width: bounds.width, height: bottom - top)
        guard box.insetBy(dx: 0, dy: -30).intersects(dirtyRect) else { return }
        let vis = visibleRect
        region.color.withAlphaComponent(0.9).setFill()
        NSRect(x: vis.minX + 1, y: top, width: 3, height: bottom - top).fill()
        region.color.withAlphaComponent(0.55).setStroke()
        for yy in [top + 0.5, bottom - 0.5] {
            let p = NSBezierPath()
            p.move(to: NSPoint(x: vis.minX, y: yy))
            p.line(to: NSPoint(x: vis.maxX, y: yy))
            p.lineWidth = 1
            p.setLineDash([4, 3], count: 2, phase: 0)
            p.stroke()
        }
    }

    private var hoverArea: NSTrackingArea?

    override func updateTrackingAreas() {
        super.updateTrackingAreas()
        if let a = hoverArea { removeTrackingArea(a) }
        let a = NSTrackingArea(rect: .zero, options: [.mouseMoved, .mouseEnteredAndExited, .activeInKeyWindow, .inVisibleRect], owner: self)
        addTrackingArea(a)
        hoverArea = a
    }

    override func mouseMoved(with event: NSEvent) {
        super.mouseMoved(with: event)
        let p = convert(event.locationInWindow, from: nil)
        MainActor.assumeIsolated { coordinator?.hover.mouseMoved(at: p) }
    }

    override func mouseExited(with event: NSEvent) {
        super.mouseExited(with: event)
        MainActor.assumeIsolated { coordinator?.hover.pointerLeft() }
    }

    override func scrollWheel(with event: NSEvent) {
        MainActor.assumeIsolated { coordinator?.hover.hide() }
        super.scrollWheel(with: event)
    }

    override func mouseDown(with event: NSEvent) {
        MainActor.assumeIsolated { coordinator?.hover.hide() }
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
        guard let pos = coordinator?.position(at: p) else { return super.menu(for: event) }
        return coordinator?.menu(at: pos)
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
        let (diff, diags, trace, marks, display, selLine, comments) =
            (coordinator?.diffMarkers ?? [:], coordinator?.diagnostics ?? [], coordinator?.traceLines ?? [],
             coordinator?.bookmarkedLines ?? [], coordinator?.display, coordinator?.ws.cursor?.line, coordinator?.commentLines ?? [:])
        let (badges, currentStep) = (coordinator?.stepBadges ?? [:], coordinator?.currentStepLine)
        guard let display, display.ns.length > 0 else { return }
        let visible = tv.visibleRect
        let glyphRange = lm.glyphRange(forBoundingRect: visible, in: tc)
        let charRange = lm.characterRange(forGlyphRange: glyphRange, actualGlyphRange: nil)
        let font = NSFont.monospacedDigitSystemFont(ofSize: max(9, Theme.codeFont.pointSize - 2), weight: .regular)
        let attrs: [NSAttributedString.Key: Any] = [.font: font, .foregroundColor: Theme.gutterText]
        let boldAttrs: [NSAttributedString.Key: Any] = [.font: NSFont.monospacedDigitSystemFont(ofSize: font.pointSize, weight: .bold), .foregroundColor: Theme.text]
        let diagLines = Dictionary(grouping: diags, by: { $0.location.line })
        var dline = display.lines.position(of: charRange.location).line
        let inset = tv.textContainerInset.height
        while dline < display.lines.lineCount {
            let start = display.lines.starts[dline]
            if start > NSMaxRange(charRange) { break }
            let g = lm.glyphIndexForCharacter(at: min(start, display.ns.length - 1))
            var lineRect = lm.lineFragmentRect(forGlyphAt: g, effectiveRange: nil, withoutAdditionalLayout: true)
            if start >= display.ns.length { lineRect = lm.extraLineFragmentRect }
            let y = convert(NSPoint(x: 0, y: lineRect.minY + inset), from: tv).y
            let h = lineRect.height
            switch display.entry(dline) {
            case .phantom(let p):
                // Other-side line: its own line number, tinted, with a +/- sign.
                let color = p.kind == .added ? Theme.addedMarker : Theme.removedMarker
                color.setFill()
                NSRect(x: thickness - 3, y: y, width: 3, height: h).fill()
                let str = NSAttributedString(string: "\(p.kind == .added ? "+" : "−")\(p.otherLine + 1)", attributes: [.font: font, .foregroundColor: color])
                let size = str.size()
                str.draw(at: NSPoint(x: thickness - size.width - 8, y: y + (h - size.height) / 2))
            case .real(let line):
                if let k = diff[line] {
                    (k == .added ? Theme.addedMarker : Theme.removedMarker).setFill()
                    NSRect(x: thickness - 3, y: y, width: 3, height: h).fill()
                }
                if let open = comments[line] {
                    let img = NSImage(systemSymbolName: open ? "bubble.left.fill" : "bubble.left", accessibilityDescription: nil)
                    let tinted = img?.withSymbolConfiguration(.init(paletteColors: [open ? .systemOrange : .secondaryLabelColor]))
                    tinted?.draw(in: NSRect(x: 3, y: y + h / 2 - 5, width: 11, height: 10))
                }
                if let d = diagLines[line]?.first {
                    (d.level == .error ? NSColor.systemRed : NSColor.systemYellow).setFill()
                    NSBezierPath(ovalIn: NSRect(x: 17, y: y + h / 2 - 3, width: 6, height: 6)).fill()
                }
                if let n = badges[line] {
                    let r = NSRect(x: 17, y: y + h / 2 - 7, width: 14, height: 14)
                    let path = NSBezierPath(ovalIn: r)
                    if line == currentStep { NSColor.systemPurple.setFill(); path.fill() }
                    else { NSColor.systemPurple.setStroke(); path.lineWidth = 1.2; path.stroke() }
                    let num = NSAttributedString(string: String(n), attributes: [.font: NSFont.systemFont(ofSize: 8.5, weight: .bold),
                                                                                 .foregroundColor: line == currentStep ? NSColor.white : NSColor.systemPurple])
                    let sz = num.size()
                    num.draw(at: NSPoint(x: r.midX - sz.width / 2, y: r.midY - sz.height / 2))
                } else if trace.contains(line) {
                    NSColor.systemPurple.setFill()
                    NSBezierPath(roundedRect: NSRect(x: 25, y: y + h / 2 - 3, width: 6, height: 6), xRadius: 1, yRadius: 1).fill()
                }
                if marks.contains(line) {
                    NSColor.systemBlue.setFill()
                    NSRect(x: 33, y: y + 2, width: 3, height: h - 4).fill()
                }
                let str = NSAttributedString(string: "\(line + 1)", attributes: line == selLine ? boldAttrs : attrs)
                let size = str.size()
                str.draw(at: NSPoint(x: thickness - size.width - 8, y: y + (h - size.height) / 2))
            case .block, nil:
                break
            }
            dline += 1
        }
    }

    override func mouseDown(with event: NSEvent) {
        guard let tv = textView, let lm = tv.layoutManager, let tc = tv.textContainer else { return }
        let p = tv.convert(event.locationInWindow, from: nil)
        let idx = lm.characterIndex(for: NSPoint(x: 0, y: p.y - tv.textContainerInset.height), in: tc, fractionOfDistanceBetweenInsertionPoints: nil)
        MainActor.assumeIsolated {
            guard let c = coordinator, let display = c.display,
                  let line = display.realPos(display.lines.position(of: idx))?.line else { return }
            c.ws.cursor = SourcePos(line: line, col: 0)
            if event.clickCount == 2 { c.ws.toggleBookmark() }
            needsDisplay = true
        }
    }
}
