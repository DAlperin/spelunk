import AppKit
import SwiftUI

/// The repository tree as an AppKit outline: rows exist only for expanded folders and are reused as
/// they scroll, so a tree of thousands of files opens, follows the open file and redraws cheaply.
struct FileOutline: NSViewRepresentable {
    let root: FileNode
    let expanded: Set<String>
    let selectedPath: String?
    /// Review tier of each changed file and of each folder holding changed files.
    let tiers: [String: ChangeTier]
    /// Step numbers (1-based) of the active code path, by file.
    let steps: [String: [Int]]
    let currentStep: Int?
    /// Expand to the selected file and scroll it into view whenever it changes.
    let follow: Bool
    /// A one-off request to reveal the selected file, follow or not.
    let revealRequested: Bool
    let setExpanded: (String, Bool) -> Void
    let open: (String) -> Void
    let didReveal: () -> Void

    func makeCoordinator() -> Coordinator { Coordinator() }

    func makeNSView(context: Context) -> NSScrollView {
        let outline = NSOutlineView()
        let column = NSTableColumn(identifier: .init("name"))
        column.resizingMask = .autoresizingMask
        outline.addTableColumn(column)
        outline.outlineTableColumn = column
        outline.headerView = nil
        outline.style = .sourceList
        outline.rowSizeStyle = .default
        outline.columnAutoresizingStyle = .uniformColumnAutoresizingStyle
        outline.allowsEmptySelection = true
        outline.autosaveExpandedItems = false
        outline.indentationPerLevel = 13
        outline.dataSource = context.coordinator
        outline.delegate = context.coordinator
        outline.target = context.coordinator
        outline.action = #selector(Coordinator.clicked(_:))
        let scroll = NSScrollView()
        scroll.documentView = outline
        scroll.hasVerticalScroller = true
        scroll.autohidesScrollers = true
        scroll.drawsBackground = false
        context.coordinator.outline = outline
        return scroll
    }

    func updateNSView(_ scroll: NSScrollView, context: Context) {
        let c = context.coordinator
        c.parent = self
        guard let outline = c.outline else { return }
        c.syncing = true
        defer { c.syncing = false }
        if c.root !== root {
            c.root = root
            c.index = [:]
            func walk(_ n: FileNode) { c.index[n.path] = n; n.children?.forEach(walk) }
            walk(root)
            outline.reloadData()
            c.applied = []
        }
        // Expand parents before children; collapsing a folder hides its descendants with it.
        for path in expanded.subtracting(c.applied).sorted(by: { $0.count < $1.count }) {
            if let n = c.index[path] { outline.expandItem(n) }
        }
        for path in c.applied.subtracting(expanded) {
            if let n = c.index[path] { outline.collapseItem(n) }
        }
        c.applied = expanded
        let decoration = DecorationKey(tiers: tiers, steps: steps, currentStep: currentStep)
        if c.decoration != decoration {
            c.decoration = decoration
            let visible = outline.rows(in: outline.visibleRect)
            if visible.length > 0 {
                outline.reloadData(forRowIndexes: IndexSet(integersIn: visible.location..<NSMaxRange(visible)), columnIndexes: [0])
            }
        }
        if follow != c.following { c.following = follow; if follow { c.revealed = nil } }
        if revealRequested || (follow && selectedPath != c.revealed) {
            c.reveal(selectedPath)
            if revealRequested { DispatchQueue.main.async { didReveal() } }
        }
        c.select(selectedPath)
    }

    struct DecorationKey: Equatable {
        var tiers: [String: ChangeTier]
        var steps: [String: [Int]]
        var currentStep: Int?
    }

    @MainActor
    final class Coordinator: NSObject, NSOutlineViewDataSource, NSOutlineViewDelegate {
        var parent: FileOutline?
        weak var outline: NSOutlineView?
        var root: FileNode?
        var index: [String: FileNode] = [:]
        /// Folder paths expanded in the outline, as last synced from the workspace.
        var applied: Set<String> = []
        var decoration: DecorationKey?
        var following = false
        /// The file last scrolled to, or clicked in the tree, which is therefore already in view.
        var revealed: String?
        /// Set while the outline is being changed to match the workspace, whose callbacks are not the user's.
        var syncing = false

        func outlineView(_ outlineView: NSOutlineView, numberOfChildrenOfItem item: Any?) -> Int {
            ((item as? FileNode) ?? root)?.children?.count ?? 0
        }

        func outlineView(_ outlineView: NSOutlineView, child index: Int, ofItem item: Any?) -> Any {
            ((item as? FileNode) ?? root)!.children![index]
        }

        func outlineView(_ outlineView: NSOutlineView, isItemExpandable item: Any) -> Bool {
            (item as? FileNode)?.isDirectory ?? false
        }

        func outlineView(_ outlineView: NSOutlineView, viewFor tableColumn: NSTableColumn?, item: Any) -> NSView? {
            guard let node = item as? FileNode, let p = parent else { return nil }
            let cell = outlineView.makeView(withIdentifier: FileCell.identifier, owner: nil) as? FileCell ?? FileCell()
            cell.show(node, tier: p.tiers[node.path], steps: node.isDirectory ? [] : (p.steps[node.path] ?? []), current: p.currentStep)
            return cell
        }

        func outlineViewItemDidExpand(_ notification: Notification) {
            guard !syncing, let n = notification.userInfo?["NSObject"] as? FileNode else { return }
            applied.insert(n.path)
            parent?.setExpanded(n.path, true)
            // Folders inside that were open when this one closed open again with it.
            syncing = true
            defer { syncing = false }
            for child in n.children ?? [] where child.isDirectory && applied.contains(child.path) { outline?.expandItem(child) }
        }

        func outlineViewItemDidCollapse(_ notification: Notification) {
            guard !syncing, let n = notification.userInfo?["NSObject"] as? FileNode else { return }
            applied.remove(n.path)
            parent?.setExpanded(n.path, false)
        }

        /// A click on a file opens it; a click on a folder opens or closes the folder.
        @objc func clicked(_ sender: NSOutlineView) {
            guard sender.clickedRow >= 0, let n = sender.item(atRow: sender.clickedRow) as? FileNode else { return }
            if n.isDirectory {
                if sender.isItemExpanded(n) { sender.animator().collapseItem(n) } else { sender.animator().expandItem(n) }
            }
        }

        func outlineViewSelectionDidChange(_ notification: Notification) {
            guard !syncing, let outline, let n = outline.item(atRow: outline.selectedRow) as? FileNode, !n.isDirectory else { return }
            revealed = n.path
            parent?.open(n.path)
        }

        /// Expands the folders above `path` and scrolls its row to the middle of the view.
        func reveal(_ path: String?) {
            revealed = path
            guard let outline, let path, let node = index[path] else { return }
            var folders: [FileNode] = []
            var p = (path as NSString).deletingLastPathComponent
            while !p.isEmpty, let f = index[p] { folders.insert(f, at: 0); p = (p as NSString).deletingLastPathComponent }
            let opened = folders.filter { !outline.isItemExpanded($0) }
            for f in opened {
                outline.expandItem(f)
                applied.insert(f.path)
            }
            if !opened.isEmpty, let setExpanded = parent?.setExpanded {
                // The workspace hears of it after this update, which is still drawing from its state.
                DispatchQueue.main.async { opened.forEach { setExpanded($0.path, true) } }
            }
            let row = outline.row(forItem: node)
            guard row >= 0, let clip = outline.enclosingScrollView?.contentView else { return }
            let rect = outline.rect(ofRow: row)
            if clip.documentVisibleRect.insetBy(dx: 0, dy: rect.height).contains(rect) { return }
            let y = max(0, min(rect.midY - clip.bounds.height / 2, outline.frame.height - clip.bounds.height))
            clip.scroll(to: NSPoint(x: clip.bounds.origin.x, y: y))
            outline.enclosingScrollView?.reflectScrolledClipView(clip)
        }

        func select(_ path: String?) {
            guard let outline else { return }
            let row = path.flatMap { index[$0] }.map { outline.row(forItem: $0) } ?? -1
            guard row != outline.selectedRow else { return }
            if row >= 0 { outline.selectRowIndexes([row], byExtendingSelection: false) } else { outline.deselectAll(nil) }
        }
    }
}

/// One row of the tree: icon, name, then the code path's step badges and the review tier's dot.
final class FileCell: NSTableCellView {
    static let identifier = NSUserInterfaceItemIdentifier("FileCell")
    private let icon = NSImageView()
    private let name = NSTextField(labelWithString: "")
    private let badges = StepBadgeView()
    private let dot = NSView()

    init() {
        super.init(frame: .zero)
        identifier = Self.identifier
        imageView = icon
        textField = name
        name.lineBreakMode = .byTruncatingTail
        name.setContentCompressionResistancePriority(.defaultLow, for: .horizontal)
        dot.wantsLayer = true
        dot.layer?.cornerRadius = 3
        let stack = NSStackView(views: [icon, name, NSView(), badges, dot])
        stack.spacing = 5
        stack.translatesAutoresizingMaskIntoConstraints = false
        addSubview(stack)
        NSLayoutConstraint.activate([
            stack.leadingAnchor.constraint(equalTo: leadingAnchor),
            stack.trailingAnchor.constraint(equalTo: trailingAnchor, constant: -4),
            stack.centerYAnchor.constraint(equalTo: centerYAnchor),
            icon.widthAnchor.constraint(equalToConstant: 16),
            dot.widthAnchor.constraint(equalToConstant: 6),
            dot.heightAnchor.constraint(equalToConstant: 6),
        ])
    }

    required init?(coder: NSCoder) { fatalError() }

    func show(_ node: FileNode, tier: ChangeTier?, steps: [Int], current: Int?) {
        name.stringValue = node.name
        icon.image = NSImage(systemSymbolName: node.isDirectory ? "folder" : Self.symbol(node.name.pathExtension), accessibilityDescription: nil)
        icon.contentTintColor = node.isDirectory ? .controlAccentColor : .secondaryLabelColor
        dot.isHidden = tier == nil
        dot.layer?.backgroundColor = tier.map { NSColor($0.color).cgColor }
        badges.steps = Array(steps.prefix(6))
        badges.current = current
        badges.isHidden = steps.isEmpty
    }

    static func symbol(_ ext: String) -> String {
        switch ext {
        case "rs": "doc.text"
        case "toml", "lock": "gearshape"
        case "md": "doc.richtext"
        default: "doc"
        }
    }
}

/// Numbered purple circles for the code path's steps in a file; the current step is filled.
final class StepBadgeView: NSView {
    var steps: [Int] = [] { didSet { invalidateIntrinsicContentSize(); needsDisplay = true } }
    var current: Int? { didSet { needsDisplay = true } }
    private let size: CGFloat = 14

    override var intrinsicContentSize: NSSize { NSSize(width: CGFloat(steps.count) * (size + 2), height: size) }

    override func draw(_ dirtyRect: NSRect) {
        let font = NSFont.systemFont(ofSize: 8.5, weight: .bold)
        for (i, n) in steps.enumerated() {
            let r = NSRect(x: CGFloat(i) * (size + 2), y: (bounds.height - size) / 2, width: size, height: size).insetBy(dx: 0.5, dy: 0.5)
            let circle = NSBezierPath(ovalIn: r)
            if n == current { NSColor.systemPurple.setFill(); circle.fill() }
            NSColor.systemPurple.setStroke()
            circle.stroke()
            let s = NSAttributedString(string: String(n), attributes: [.font: font, .foregroundColor: n == current ? NSColor.white : NSColor.systemPurple])
            let sz = s.size()
            s.draw(at: NSPoint(x: r.midX - sz.width / 2, y: r.midY - sz.height / 2))
        }
    }
}
