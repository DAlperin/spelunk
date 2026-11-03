import AppKit
import SwiftUI

/// What the hover popover shows for a symbol.
struct HoverInfo {
    var name: String
    var details: SymbolDetails
}

extension Workspace {
    /// Details for the symbol at a position in a document, asked of code intelligence at the
    /// equivalent working-copy position. Cached per document, symbol and line.
    func hoverInfo(in d: SourceDocument, at p: SourcePos) async -> HoverInfo? {
        guard let (name, range) = d.word(at: p), name.first?.isLetter == true || name.first == "_" else { return nil }
        // Keywords get the language's own documentation, which is noise while reading.
        let off = d.lines.offset(of: range.start)
        if let t = d.syntax.tokens.first(where: { NSLocationInRange(off, $0.range) }), t.kind == .keyword || t.kind == .selfKeyword { return nil }
        let key = "\(d.id)|\(name)|\(range.start.line)|\(range.start.col)"
        if let hit = hoverCache[key] { return hit }
        let target = intelTarget(d, name: name, range: range)
        var details = await target.hub.details(path: d.path, at: target.pos, name: name)
        details.definition = details.definition.map { Self.tagged($0, target.version) }
        guard details.signature != nil || details.docs != nil || details.definition != nil else { return nil }
        let info = HoverInfo(name: name, details: details)
        if hoverCache.count > 200 { hoverCache.removeAll() }
        hoverCache[key] = info
        return info
    }
}

/// The popover's content, laid out at a fixed width so its height can be measured exactly.
struct HoverCard: View {
    static let width: CGFloat = 460
    let info: HoverInfo
    let open: (CodeLocation) -> Void

    /// Doc comments arrive with the source's hard line breaks; join lines within a paragraph, keep
    /// blank lines, list items and code blocks.
    static func reflow(_ docs: String) -> String {
        var out: [String] = []
        var inCode = false
        for raw in docs.components(separatedBy: "\n") {
            let line = raw.trimmingCharacters(in: .whitespaces)
            if line.hasPrefix("```") { inCode.toggle(); out.append(raw); continue }
            let structural = line.isEmpty || line.hasPrefix("- ") || line.hasPrefix("* ") || line.hasPrefix("#") || line.first?.isNumber == true && line.contains(". ")
            if inCode || structural || out.isEmpty || out.last?.trimmingCharacters(in: .whitespaces).isEmpty == true || out.last?.hasPrefix("```") == true {
                out.append(inCode ? raw : line)
            } else {
                out[out.count - 1] += " " + line
            }
        }
        return out.joined(separator: "\n").trimmingCharacters(in: .whitespacesAndNewlines)
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack(spacing: 6) {
                Text(info.details.kindLabel.lowercased()).font(.system(size: 9, weight: .semibold))
                    .padding(.horizontal, 5).padding(.vertical, 1)
                    .background(Color.accentColor.opacity(0.18), in: RoundedRectangle(cornerRadius: 3))
                Text(info.name).font(.system(size: 12, weight: .semibold, design: .monospaced)).lineLimit(1)
                Spacer(minLength: 8)
                WeakSourceTag(source: info.details.source)
            }
            if let sig = info.details.signature?.trimmingCharacters(in: .whitespacesAndNewlines), !sig.isEmpty {
                Text(sig).font(.system(size: 11, design: .monospaced)).textSelection(.enabled)
                    .lineLimit(8)
                    .fixedSize(horizontal: false, vertical: true)
                    .padding(.horizontal, 8).padding(.vertical, 6)
                    .frame(width: Self.width - 20, alignment: .leading)
                    .background(Color.secondary.opacity(0.08), in: RoundedRectangle(cornerRadius: 4))
            }
            if let docs = info.details.docs.map(Self.reflow), !docs.isEmpty {
                RustdocView(markdown: docs)
                    .lineLimit(14)
                    .fixedSize(horizontal: false, vertical: true)
                    .frame(width: Self.width - 20, alignment: .leading)
            }
            if let def = info.details.definition {
                Button { open(def) } label: {
                    Label(def.shortDescription, systemImage: "arrow.right.circle").font(.caption)
                }
                .buttonStyle(.link)
                .help("Go to definition (⌘-click)")
            }
        }
        .padding(10)
        .frame(width: Self.width, alignment: .leading)
        .fixedSize(horizontal: false, vertical: true)
    }
}

/// Shows the hover card after the pointer rests on a symbol. The card stays while the pointer is on
/// the symbol or the card, so its links can be clicked, and closes once the pointer has been away
/// from both briefly, or on a scroll or click in the text.
@MainActor
final class HoverController: NSObject, NSPopoverDelegate {
    weak var textView: SourceTextView?
    private var timer: Timer?
    private var watcher: Timer?
    private var pending: Task<Void, Never>?
    private var popover: NSPopover?
    private var shownRange: NSRange?
    /// The symbol's rectangle in screen coordinates while its card is shown.
    private var symbolRect: NSRect = .zero
    private var awaySince: Date?

    /// Seconds the pointer must rest before the card appears.
    static var delay: TimeInterval { Prefs.hoverDelay }
    static var enabled: Bool { Prefs.hoverEnabled }
    /// How long the pointer may be away from both the symbol and the card before the card closes.
    static let grace: TimeInterval = 0.35

    func mouseMoved(at point: NSPoint) {
        guard Self.enabled, let tv = textView else { return }
        // Nothing for code under the palette or another overlay, or while a sheet is up.
        if tv.coordinator?.ws.palette != nil || tv.window?.attachedSheet != nil { hide(); return }
        // While a card is up, the watcher decides when it goes.
        if popover != nil { return }
        let idx = tv.characterIndexForInsertion(at: point)
        if let shown = shownRange, NSLocationInRange(idx, shown) { return }
        timer?.invalidate()
        timer = Timer.scheduledTimer(withTimeInterval: Self.delay, repeats: false) { [weak self] _ in
            MainActor.assumeIsolated { self?.show(at: point) }
        }
    }

    /// The pointer left the text view: a pending card is cancelled, a shown one is left to the watcher.
    func pointerLeft() {
        if popover == nil { hide() }
    }

    /// Shows the card for the character at a point now, from the keyboard (vim `K`). It stays until
    /// the next key or click rather than following the pointer.
    func showNow(at point: NSPoint) {
        hide()
        fromKeyboard = true
        show(at: point)
    }

    private var fromKeyboard = false

    func hide() {
        fromKeyboard = false
        timer?.invalidate()
        watcher?.invalidate()
        watcher = nil
        pending?.cancel()
        popover?.close()
        popover = nil
        shownRange = nil
        awaySince = nil
    }

    private var pointerIsOnCardOrSymbol: Bool {
        let m = NSEvent.mouseLocation
        if symbolRect.insetBy(dx: -4, dy: -4).contains(m) { return true }
        if let w = popover?.contentViewController?.view.window, w.frame.insetBy(dx: -6, dy: -14).contains(m) { return true }
        return false
    }

    private func watch() {
        watcher?.invalidate()
        watcher = Timer.scheduledTimer(withTimeInterval: 0.1, repeats: true) { [weak self] _ in
            MainActor.assumeIsolated {
                guard let self else { return }
                if self.pointerIsOnCardOrSymbol {
                    self.awaySince = nil
                } else if let since = self.awaySince {
                    if Date().timeIntervalSince(since) > Self.grace { self.hide() }
                } else {
                    self.awaySince = Date()
                }
            }
        }
    }

    private func show(at point: NSPoint) {
        guard let tv = textView, let c = tv.coordinator, let display = c.display, let doc = c.document,
              let pos = c.position(at: point), let (_, range) = doc.word(at: pos) else { return }
        let ws = c.ws
        pending?.cancel()
        pending = Task { [weak self] in
            let info = await ws.hoverInfo(in: doc, at: pos)
            guard let info, !Task.isCancelled, let self, let tv = self.textView,
                  let lm = tv.layoutManager, let tc = tv.textContainer, let window = tv.window else { return }
            let r = display.displayRange(range)
            guard NSMaxRange(r) <= (tv.textStorage?.length ?? 0) else { return }
            var rect = lm.boundingRect(forGlyphRange: lm.glyphRange(forCharacterRange: r, actualCharacterRange: nil), in: tc)
            rect.origin.x += tv.textContainerInset.width
            rect.origin.y += tv.textContainerInset.height
            guard tv.visibleRect.intersects(rect) else { return }
            // Still on the symbol after the lookup?
            let now = tv.convert(window.convertPoint(fromScreen: NSEvent.mouseLocation), from: nil)
            guard self.fromKeyboard || rect.insetBy(dx: -4, dy: -4).contains(now) else { return }
            let p = NSPopover()
            p.behavior = .applicationDefined
            p.animates = false
            p.delegate = self
            let host = NSHostingController(rootView: HoverCard(info: info) { [weak self] loc in
                self?.hide()
                ws.open(loc, edge: .definition, title: info.name, source: info.details.source, reason: .definition)
            })
            // Measure at the card's width before positioning, so the popover fits its content and
            // sits against the symbol.
            let size = host.sizeThatFits(in: CGSize(width: HoverCard.width, height: 2000))
            host.sizingOptions = []
            p.contentViewController = host
            p.contentSize = NSSize(width: HoverCard.width, height: ceil(size.height))
            p.show(relativeTo: rect, of: tv, preferredEdge: .maxY)
            self.popover = p
            self.shownRange = r
            self.symbolRect = window.convertToScreen(tv.convert(rect, to: nil))
            if !self.fromKeyboard { self.watch() }
        }
    }

    nonisolated func popoverDidClose(_ notification: Notification) {
        MainActor.assumeIsolated {
            watcher?.invalidate()
            watcher = nil
            popover = nil
            shownRange = nil
        }
    }
}
