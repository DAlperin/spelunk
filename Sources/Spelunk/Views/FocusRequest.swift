import AppKit
import SwiftUI

/// Makes the editable text field it sits behind the first responder when it first appears and each
/// time `request` changes. A request made while the view is out of the window waits until it is back.
struct FocusRequest: NSViewRepresentable {
    let request: Int

    final class Anchor: NSView {
        var request: Int?
        var pending = true

        override func viewDidMoveToWindow() {
            super.viewDidMoveToWindow()
            if pending { DispatchQueue.main.async { self.focus() } }
        }

        func focus() {
            guard pending, let window else { return }
            let rect = convert(bounds, to: nil)
            var root: NSView = self
            while let s = root.superview { root = s }
            guard let field = Self.field(in: root, overlapping: rect) else { return }
            pending = false
            if field.currentEditor() == nil { window.makeFirstResponder(field) }
        }

        private static func field(in v: NSView, overlapping rect: NSRect) -> NSTextField? {
            if let f = v as? NSTextField, f.isEditable, !f.isHiddenOrHasHiddenAncestor,
               f.convert(f.bounds, to: nil).intersects(rect) { return f }
            for s in v.subviews { if let f = field(in: s, overlapping: rect) { return f } }
            return nil
        }
    }

    func makeNSView(context: Context) -> Anchor {
        let a = Anchor()
        a.request = request
        return a
    }

    func updateNSView(_ a: Anchor, context: Context) {
        guard a.request != request else { return }
        a.request = request
        a.pending = true
        DispatchQueue.main.async { a.focus() }
    }
}
