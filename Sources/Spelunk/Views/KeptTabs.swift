import AppKit
import SwiftUI

/// Shows the selected tab's view and keeps the others alive out of the window, so switching back
/// reuses their lists, scroll positions and state instead of building them again. Each tab is its
/// own hosting view, made the first time it is shown.
struct KeptTabs<Tab: Hashable>: NSViewRepresentable {
    let selection: Tab
    /// Identifies what the tabs show; when it changes, every kept tab is dropped and built afresh.
    let owner: AnyObject
    let model: AppModel
    let content: (Tab) -> AnyView

    final class Coordinator {
        var owner: ObjectIdentifier?
        var hosts: [Tab: NSHostingView<AnyView>] = [:]
    }

    func makeCoordinator() -> Coordinator { Coordinator() }

    func makeNSView(context: Context) -> NSView { NSView() }

    func updateNSView(_ container: NSView, context: Context) {
        let c = context.coordinator
        if c.owner != ObjectIdentifier(owner) {
            c.owner = ObjectIdentifier(owner)
            c.hosts.values.forEach { $0.removeFromSuperview() }
            c.hosts = [:]
        }
        let host = c.hosts[selection] ?? {
            let h = NSHostingView(rootView: AnyView(content(selection).environment(model)))
            h.sizingOptions = []
            h.translatesAutoresizingMaskIntoConstraints = false
            c.hosts[selection] = h
            return h
        }()
        guard host.superview !== container else { return }
        // Hidden tabs leave the window rather than staying hidden in it, so they skip its updates.
        container.subviews.forEach { $0.removeFromSuperview() }
        container.addSubview(host)
        NSLayoutConstraint.activate([
            host.leadingAnchor.constraint(equalTo: container.leadingAnchor),
            host.trailingAnchor.constraint(equalTo: container.trailingAnchor),
            host.topAnchor.constraint(equalTo: container.topAnchor),
            host.bottomAnchor.constraint(equalTo: container.bottomAnchor),
        ])
    }
}
