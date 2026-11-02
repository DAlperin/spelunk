import AppKit
import Foundation

/// Scriptable hooks for driving the UI from outside the process, enabled with SPELUNK_DEBUG=1.
/// Post a distributed notification named `dev.spelunk.debug` whose object is a command string.
@MainActor
final class DebugBridge {
    static let shared = DebugBridge()
    weak var model: AppModel?

    func install(_ model: AppModel) {
        guard Log.enabled else { return }
        self.model = model
        DistributedNotificationCenter.default().addObserver(forName: Notification.Name("dev.spelunk.debug"), object: nil, queue: .main) { n in
            let cmd = (n.object as? String) ?? ""
            MainActor.assumeIsolated { DebugBridge.shared.run(cmd) }
        }
        Log.debug("debug bridge installed")
    }

    func run(_ command: String) {
        Log.debug("cmd: \(command)")
        let parts = command.split(separator: " ", maxSplits: 1).map(String.init)
        guard let verb = parts.first else { return }
        let arg = parts.count > 1 ? parts[1] : ""
        guard let ws = model?.workspace else {
            if verb == "snapshot" { snapshot(arg) }
            return
        }
        func pos(_ s: String) -> SourcePos {
            let n = s.split(separator: ":").compactMap { Int($0) }
            return SourcePos(line: max(0, (n.first ?? 1) - 1), col: n.count > 1 ? n[1] - 1 : 0)
        }
        switch verb {
        case "snapshot": snapshot(arg)
        case "snapshotv": snapshot(arg, viaWindowServer: false)
        case "open":
            let p = arg.split(separator: ":")
            let line = p.count > 1 ? (Int(p[1]) ?? 1) - 1 : 0
            ws.open(CodeLocation(path: String(p[0]), range: SourceRange(line: line)), edge: .manual)
        case "click": ws.didClick(at: pos(arg))
        case "def": ws.goToDefinition(at: pos(arg))
        case "back": ws.goBack()
        case "tab": ws.sidebarTab = SidebarTab(rawValue: arg.capitalized) ?? .files
        case "calls":
            if let c = ws.context { c.callDirection = arg == "out" ? .outgoing : .incoming; Task { await ws.loadCalls(c) } }
        case "record": if arg == "off" { ws.traces.isRecording = false } else { ws.traces.startRecording(from: nil) }
        case "step": ws.playStep((Int(arg) ?? 1) - 1)
        case "review":
            let p = arg.split(separator: ":").map(String.init)
            switch p.first {
            case "jj": ws.startReview(.jj(from: p.count > 1 ? p[1] : "@-", to: p.count > 2 ? p[2] : "@"))
            case "git": ws.startReview(.git(base: p.count > 1 ? p[1] : "HEAD", head: p.count > 2 ? p[2] : nil))
            case "pr": ws.startReview(.githubPR(Int(p.count > 1 ? p[1] : "0") ?? 0))
            default: break
            }
        case "hunk": if arg == "prev" { ReviewNav.previous(ws) } else { ReviewNav.next(ws) }
        case "side": ws.setReviewSide(arg == "before" ? .before : .after)
        case "triage": Task { await ws.review?.triageWithClaude() }
        case "trace": ws.generateTrace(arg, includeAnchor: true)
        case "ask": ws.ask(arg, includeAnchor: true)
        case "askclose": ws.showAsk = false
        case "clippy": ws.clippy.run()
        case "scip": ws.scip.generate(revision: ws.vcs.revision, sourceFiles: ws.allFiles)
        case "dump": dump(ws)
        case "geom":
            func walk(_ v: NSView, _ depth: Int) {
                if v is NSScrollView || v is NSClipView || v is NSTextView || v is GutterView || v.superview is NSWindow || depth < 4 {
                    Log.debug(String(repeating: " ", count: depth) + "\(type(of: v)) frame=\(v.frame) bounds=\(v.bounds)")
                }
                for c in v.subviews { walk(c, depth + 1) }
            }
            for w in NSApp.windows { if let cv = w.contentView { walk(cv, 0) } }
        default: Log.debug("unknown command \(verb)")
        }
    }

    private func dump(_ ws: Workspace) {
        var s = "doc=\(ws.document?.path ?? "-") cursor=\(String(describing: ws.cursor)) ra=\(ws.ra.status.label) scip=\(ws.scip.summary)\n"
        if let c = ws.context {
            s += "context \(c.name) kind=\(c.details?.kindLabel ?? "-") def=\(c.details?.definition?.id ?? "-") via=\(c.details?.source.label ?? "-")\n"
            s += "  refs=\(c.references.count) via \(c.referencesSource?.label ?? "-"); calls(\(c.callDirection.rawValue))=\(c.calls.map { "\($0.name)@\($0.location.shortDescription)" })\n"
            s += "  impls=\(c.implementations.map { $0.enclosing ?? $0.location.shortDescription })\n"
        }
        if let t = ws.traces.active { s += "trace '\(t.title)' steps=\(t.steps.map { "\($0.title)[\($0.edge.rawValue)]@\($0.location.shortDescription)\($0.verified ? "" : "?")" })\n" }
        if let r = ws.review {
            s += "review \(r.title) state=\(r.state) files=\(r.files.count) hunks=\(r.allHunks.count)\n"
            for t in ChangeTier.allCases {
                let hs = r.hunks(in: t)
                if hs.isEmpty { continue }
                s += "  \(t.rawValue): " + hs.map { "\($0.path.lastPathComponent)[\(r.analyses[$0.id]?.enclosing ?? "-")]: \(r.reasons(of: $0).joined(separator: ","))" }.joined(separator: " | ") + "\n"
            }
            if let o = r.overview { s += "  overview: \(o)\n" }
            if let ts = r.triageState { s += "  triage: \(ts)\n" }
        }
        for e in ws.askEntries { s += "ask: \(e.question) running=\(e.running) answer=\(e.answer.prefix(600)) err=\(e.error ?? "-")\n" }
        if let m = ws.statusMessage { s += "status: \(m)\n" }
        Log.debug("DUMP\n" + s)
    }

    private func snapshot(_ path: String, viaWindowServer: Bool = true) {
        guard let window = NSApp.windows.first(where: { $0.isVisible && $0.frame.width > 400 }) else { return }
        // CGWindowListCreateImage is marked unavailable in the SDK but still works for a process's own
        // windows without screen-recording permission; resolve it dynamically.
        typealias Fn = @convention(c) (CGRect, UInt32, UInt32, UInt32) -> Unmanaged<CGImage>?
        if viaWindowServer, let h = dlopen(nil, RTLD_NOW), let sym = dlsym(h, "CGWindowListCreateImage") {
            let fn = unsafeBitCast(sym, to: Fn.self)
            // kCGWindowListOptionIncludingWindow = 1 << 3, kCGWindowImageBoundsIgnoreFraming = 1 << 0
            if let img = fn(.null, 1 << 3, UInt32(window.windowNumber), 1)?.takeRetainedValue() {
                let rep = NSBitmapImageRep(cgImage: img)
                if let data = rep.representation(using: .png, properties: [:]) {
                    try? data.write(to: URL(fileURLWithPath: path))
                    Log.debug("snapshot(cg) \(path) \(img.width)x\(img.height)")
                    return
                }
            }
        }
        guard let view = window.contentView?.superview ?? window.contentView,
              let rep = view.bitmapImageRepForCachingDisplay(in: view.bounds) else { return }
        view.cacheDisplay(in: view.bounds, to: rep)
        if let data = rep.representation(using: .png, properties: [:]) {
            try? data.write(to: URL(fileURLWithPath: path))
            Log.debug("snapshot \(path) \(Int(view.bounds.width))x\(Int(view.bounds.height))")
        }
    }
}
