import AppKit
import SwiftUI

/// A review hunk's extent in the editor, in display lines (phantom lines included).
struct HunkRegion {
    var id: String
    var lines: ClosedRange<Int>
    var color: NSColor
    var title: String
    var summary: String
    var selected: Bool
}

extension ChangeTier {
    var nsColor: NSColor { NSColor(color) }
}

extension CodeView.Coordinator {
    /// Regions of the review's hunks in the shown file, mapped through the inline-diff display.
    func computeHunkRegions(ws: Workspace, document: SourceDocument, display: DisplayDoc) -> [HunkRegion] {
        guard let r = ws.review else { return [] }
        let isOld = document.side == .old
        let hunks = r.files.filter { (isOld ? $0.oldPath : $0.newPath) == document.path }.flatMap(\.hunks)
        guard !hunks.isEmpty else { return [] }
        var realToHunk: [Int: Int] = [:]
        var otherToHunk: [Int: Int] = [:]
        for (i, h) in hunks.enumerated() {
            for l in h.lines {
                if isOld {
                    if l.kind == .removed, let o = l.oldLine { realToHunk[o] = i }
                    if l.kind == .added, let n = l.newLine { otherToHunk[n] = i }
                } else {
                    if l.kind == .added, let n = l.newLine { realToHunk[n] = i }
                    if l.kind == .removed, let o = l.oldLine { otherToHunk[o] = i }
                }
            }
        }
        var bounds: [Int: (Int, Int)] = [:]
        for (dl, e) in display.entries.enumerated() {
            let idx: Int?
            switch e {
            case .real(let l): idx = realToHunk[l]
            case .phantom(let p): idx = otherToHunk[p.otherLine]
            case .block: idx = nil
            }
            guard let i = idx else { continue }
            let b = bounds[i] ?? (dl, dl)
            bounds[i] = (min(b.0, dl), max(b.1, dl))
        }
        // A pure deletion shown without phantoms still gets a one-line marker where it happened.
        for (i, h) in hunks.enumerated() where bounds[i] == nil {
            let l = display.displayLine(isOld ? h.anchorOldLine : h.anchorNewLine)
            bounds[i] = (l, l)
        }
        return bounds.map { i, b in
            let h = hunks[i]
            return HunkRegion(id: h.id, lines: b.0...b.1, color: r.tier(of: h).nsColor,
                              title: "\(r.tier(of: h).title) · \(r.analyses[h.id]?.enclosing ?? h.path.lastPathComponent)",
                              summary: r.summary(of: h), selected: h.id == ws.selectedHunkID)
        }
        .sorted { $0.lines.lowerBound < $1.lines.lowerBound }
    }
}

/// The whole file at a glance: line shapes, diff colors, every hunk tinted by tier, the selected hunk
/// outlined and the visible area. Click or drag to scroll; hover a hunk for what it is.
final class MinimapView: NSView {
    weak var textView: NSTextView?
    weak var coordinator: CodeView.Coordinator?
    static let width: CGFloat = 70
    private var tracking: NSTrackingArea?
    private var hoverRegion: String?

    init(textView: NSTextView, coordinator: CodeView.Coordinator) {
        self.textView = textView
        self.coordinator = coordinator
        super.init(frame: .zero)
    }

    required init?(coder: NSCoder) { fatalError() }

    override var isFlipped: Bool { true }

    @objc func redraw() { needsDisplay = true }

    override func updateTrackingAreas() {
        super.updateTrackingAreas()
        if let t = tracking { removeTrackingArea(t) }
        let t = NSTrackingArea(rect: bounds, options: [.mouseMoved, .mouseEnteredAndExited, .activeInKeyWindow, .inVisibleRect], owner: self)
        addTrackingArea(t)
        tracking = t
    }

    private var lineCount: Int { MainActor.assumeIsolated { coordinator?.display?.lines.lineCount ?? 0 } }

    /// Pixels per display line: two when the file fits, compressed to fit otherwise.
    private var scale: CGFloat {
        let n = max(1, lineCount)
        return min(2.5, (bounds.height - 4) / CGFloat(n))
    }

    private func y(_ line: Int) -> CGFloat { 2 + CGFloat(line) * scale }

    private func line(atY y: CGFloat) -> Int { max(0, min(lineCount - 1, Int((y - 2) / max(scale, 0.0001)))) }

    override func draw(_ dirtyRect: NSRect) {
        Theme.gutter.setFill()
        bounds.fill()
        NSColor.separatorColor.withAlphaComponent(0.4).setFill()
        NSRect(x: 0, y: 0, width: 1, height: bounds.height).fill()
        let (display, regions, widths) = (coordinator?.display, coordinator?.hunkRegions ?? [], coordinator?.minimapWidths ?? [])
        guard let display, let tv = textView, display.lines.lineCount > 0 else { return }
        let s = scale
        let barH = max(1, min(2, s - (s > 1.5 ? 0.5 : 0)))
        let maxW = bounds.width - 16
        for (i, e) in display.entries.enumerated() {
            let w = i < widths.count ? widths[i] : CodeView.Coordinator.LineShape(indent: 0, length: 0)
            let color: NSColor
            switch e {
            case .phantom(let p): color = (p.kind == .added ? Theme.addedMarker : Theme.removedMarker).withAlphaComponent(0.8)
            case .real: color = Theme.gutterText.withAlphaComponent(0.45)
            case .block: color = .systemBlue.withAlphaComponent(0.3)
            }
            guard w.length > 0 else { continue }
            color.setFill()
            NSRect(x: 10 + CGFloat(w.indent) * maxW / 120, y: y(i), width: max(2, CGFloat(w.length) * maxW / 120), height: barH).fill()
        }
        for r in regions {
            let top = y(r.lines.lowerBound), bottom = y(r.lines.upperBound) + max(barH, 2)
            r.color.withAlphaComponent(r.selected ? 1 : 0.75).setFill()
            NSRect(x: 2, y: top, width: r.selected ? 5 : 3, height: max(3, bottom - top)).fill()
            if r.selected {
                let box = NSRect(x: 1, y: top - 2, width: bounds.width - 3, height: max(5, bottom - top + 4))
                r.color.withAlphaComponent(0.12).setFill()
                box.fill()
                r.color.withAlphaComponent(0.9).setStroke()
                let p = NSBezierPath(rect: box.insetBy(dx: 0.5, dy: 0.5))
                p.lineWidth = 1
                p.stroke()
            }
        }
        // Visible area.
        if let lm = tv.layoutManager, let tc = tv.textContainer {
            let vis = tv.visibleRect
            let g0 = lm.glyphIndex(for: NSPoint(x: 0, y: vis.minY), in: tc)
            let g1 = lm.glyphIndex(for: NSPoint(x: 0, y: vis.maxY), in: tc)
            let l0 = display.lines.position(of: lm.characterIndexForGlyph(at: g0)).line
            let l1 = display.lines.position(of: lm.characterIndexForGlyph(at: g1)).line
            let rect = NSRect(x: 1, y: y(l0), width: bounds.width - 2, height: max(8, y(l1 + 1) - y(l0)))
            NSColor.labelColor.withAlphaComponent(0.08).setFill()
            rect.fill()
            NSColor.labelColor.withAlphaComponent(0.18).setStroke()
            NSBezierPath(rect: rect.insetBy(dx: 0.5, dy: 0.5)).stroke()
        }
    }

    override func mouseDown(with event: NSEvent) { scrollTo(event) }
    override func mouseDragged(with event: NSEvent) { scrollTo(event) }

    private func scrollTo(_ event: NSEvent) {
        let p = convert(event.locationInWindow, from: nil)
        let l = line(atY: p.y)
        MainActor.assumeIsolated {
            if event.type == .leftMouseDown, event.clickCount == 1, let r = region(at: p.y), let c = coordinator, !c.secondary,
               let h = c.ws.review?.allHunks.first(where: { $0.id == r.id }), h.id != c.ws.selectedHunkID, NSEvent.modifierFlags.contains(.option) {
                c.ws.selectHunk(h)
                return
            }
            coordinator?.centerOn(displayLine: l)
        }
    }

    private func region(at y: CGFloat) -> HunkRegion? {
        let regions = coordinator?.hunkRegions ?? []
        let l = line(atY: y)
        let slack = max(1, Int(3 / max(scale, 0.01)))
        return regions.first { $0.lines.lowerBound - slack <= l && l <= $0.lines.upperBound + slack }
    }

    override func mouseMoved(with event: NSEvent) {
        let p = convert(event.locationInWindow, from: nil)
        let r = region(at: p.y)
        guard r?.id != hoverRegion else { return }
        hoverRegion = r?.id
        toolTip = r.map { "\($0.title)\n\($0.summary)\nClick to scroll · ⌥-click to select this hunk" }
    }

    override func mouseExited(with event: NSEvent) { hoverRegion = nil; toolTip = nil }
}

extension CodeView.Coordinator {
    struct LineShape { var indent: Int; var length: Int }

    /// Leading whitespace and trimmed length of each display line, capped for the minimap.
    static func shapes(_ display: DisplayDoc) -> [LineShape] {
        (0..<display.lines.lineCount).map { i in
            let r = display.lines.lineRange(i)
            guard r.length > 0 else { return LineShape(indent: 0, length: 0) }
            let s = display.ns.substring(with: NSRange(location: r.location, length: min(r.length, 200)))
            let indent = s.prefix { $0 == " " || $0 == "\t" }.reduce(0) { $0 + ($1 == "\t" ? 4 : 1) }
            let len = s.trimmingCharacters(in: .whitespacesAndNewlines).count
            return LineShape(indent: min(indent, 80), length: min(len, 120 - min(indent, 80)))
        }
    }

    func centerOn(displayLine l: Int) {
        guard let tv = textView, let lm = tv.layoutManager, let display, let clip = tv.enclosingScrollView?.contentView, display.ns.length > 0 else { return }
        let off = display.lines.starts[min(l, display.lines.lineCount - 1)]
        let g = lm.glyphIndexForCharacter(at: min(off, display.ns.length - 1))
        let rect = lm.lineFragmentRect(forGlyphAt: g, effectiveRange: nil)
        let maxY = max(0, tv.frame.height - clip.bounds.height)
        let y = min(maxY, max(0, rect.midY + tv.textContainerInset.height - clip.bounds.height / 2))
        clip.setBoundsOrigin(NSPoint(x: clip.bounds.origin.x, y: y))
        tv.enclosingScrollView?.reflectScrolledClipView(clip)
        gutter?.needsDisplay = true
        minimap?.needsDisplay = true
    }
}
