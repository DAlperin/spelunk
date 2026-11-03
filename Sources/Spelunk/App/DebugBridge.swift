import AppKit
import Foundation

/// Scriptable hooks for driving the UI from outside the process. Off unless the app is launched with
/// SPELUNK_BRIDGE=<token>; commands are distributed notifications named `dev.spelunk.debug.<token>`
/// whose object is the command string, so only a sender that knows the launch token can drive it.
/// Files it writes (snapshots, recordings) must be under the temporary directory.
@MainActor
final class DebugBridge {
    static let shared = DebugBridge()
    weak var model: AppModel?

    func install(_ model: AppModel) {
        guard let token = ProcessInfo.processInfo.environment["SPELUNK_BRIDGE"], token.count >= 8 else { return }
        self.model = model
        DistributedNotificationCenter.default().addObserver(forName: Notification.Name("dev.spelunk.debug.\(token)"), object: nil, queue: .main) { n in
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
        switch verb {
        case "openrepo": model?.open(URL(fileURLWithPath: arg)); return
        case "newwindow": model?.newWindow(); return
        case "focus":
            if let w = model?.windows[arg] { w.makeKeyAndOrderFront(nil); model?.activePath = arg }
            return
        case "windows":
            Log.debug("windows: " + NSApp.windows.map { "\($0.title)[\(Int($0.frame.width)) visible=\($0.isVisible)]" }.joined(separator: ", ")
                      + " registered=\((model?.windows ?? [:]).map { "\($0.key.lastPathComponent)#\($0.value.windowNumber)" }.sorted())"
                      + " workspaces=\(model?.workspaces.keys.sorted() ?? []) active=\(model?.activePath ?? "-")"
                      + " " + (model?.workspaces.map { "\($0.key.lastPathComponent): hunk=\($0.value.selectedHunkID.map { String($0.suffix(10)) } ?? "-") line=\($0.value.cursor.map { String($0.line + 1) } ?? "-")" }.sorted().joined(separator: "; ") ?? ""))
            return
        default: break
        }
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
        case "snapshotwin":
            // snapshotwin <title-substring> <path>
            let p = arg.split(separator: " ", maxSplits: 1).map(String.init)
            if p.count == 2, allowed(p[1]), let w = NSApp.windows.first(where: { $0.isVisible && $0.title.localizedCaseInsensitiveContains(p[0]) }) {
                capture(w, to: p[1])
            }
        case "open":
            let p = arg.split(separator: ":")
            let line = p.count > 1 ? (Int(p[1]) ?? 1) - 1 : 0
            ws.open(CodeLocation(path: String(p[0]), range: SourceRange(line: line)), edge: .manual)
        case "click": ws.didClick(at: pos(arg))
        case "def": ws.goToDefinition(at: pos(arg))
        case "back": ws.goBack()
        case "calls":
            if let c = ws.context { c.callDirection = arg == "out" ? .outgoing : .incoming; Task { await ws.loadCalls(c) } }
        case "addstep": ws.addCurrentToTrace()
        case "newpath": ws.newCodePath(fromCursor: true)
        case "step": ws.playStep((Int(arg) ?? 1) - 1)
        case "review":
            let p = arg.split(separator: ":").map(String.init)
            switch p.first {
            case "jj": ws.startReview(.jj(from: p.count > 1 ? p[1] : "@-", to: p.count > 2 ? p[2] : "@"))
            case "git": ws.startReview(.git(base: p.count > 1 ? p[1] : "HEAD", head: p.count > 2 ? p[2] : nil))
            case "pr": ws.startReview(.githubPR(Int(p.count > 1 ? p[1] : "0") ?? 0))
            case "wc":
                ws.activateReview(nil)
            default: break
            }
        case "hunk": if arg == "prev" { ReviewNav.previous(ws) } else { ReviewNav.next(ws) }
        case "side": ws.setReviewSide(arg == "before" ? .before : .after)
        case "triage": Task { await ws.review?.triageWithClaude() }
        case "listmode": if let m = ReviewSession.ListMode(rawValue: arg.capitalized) { ws.review?.listMode = m }
        case "selecthunk":
            if let h = ws.review?.allHunks.first(where: { $0.path.contains(arg) || $0.lines.contains { $0.kind != .context && $0.text.contains(arg) } }) { ws.selectHunk(h) }
        case "runattach":
            if let r = ws.review, let h = r.allHunks.first(where: { $0.id == ws.selectedHunkID }) { r.attachments(for: h).forEach(r.runAttachment) }
        case "pane": if let p = InspectorPane.allCases.first(where: { $0.rawValue.lowercased().hasPrefix(arg.lowercased()) }) { ws.inspectorPane = p }
        case "groupclaude": Task { await ws.review?.groupWithClaude() }
        case "trace": ws.generateTrace(arg, includeAnchor: true)
        case "ask": ws.ask(arg, includeAnchor: true)
        case "askclose": ws.inspectorPane = .context
        case "clippy": ws.clippy.run()
        case "scip": ws.scip.generate(revision: ws.vcs.revision, sourceFiles: ws.allFiles)
        case "dump": dump(ws)
        case "hitchain":
            let n = arg.split(separator: " ").compactMap { Double($0) }
            guard n.count == 2, let w = mainWindow,
                  let root = w.contentView?.superview else { break }
            let p = NSPoint(x: n[0], y: w.frame.height - n[1])
            func walk(_ v: NSView, _ depth: Int) {
                let r = v.convert(v.bounds, to: nil)
                guard r.contains(p), !v.isHidden else { return }
                Log.debug("hitchain " + String(repeating: " ", count: depth) + "\(type(of: v)) win=\(r) hidden=\(v.isHidden) alpha=\(v.alphaValue)")
                for c in v.subviews { walk(c, depth + 1) }
            }
            walk(root, 0)
        case "mode": ws.setDiffMode(DiffMode(rawValue: arg.capitalized) ?? .inline)
        case "key":
            // key <chars>, posted through the event queue so local monitors see it.
            guard let w = mainWindow else { break }
            w.makeKeyAndOrderFront(nil)
            w.makeFirstResponder(w.contentView?.firstSubview(ofType: SourceTextView.self))
            for ch in arg {
                let shift = ch.isUppercase
                if let e = NSEvent.keyEvent(with: .keyDown, location: .zero, modifierFlags: shift ? [.shift] : [], timestamp: ProcessInfo.processInfo.systemUptime,
                                            windowNumber: w.windowNumber, context: nil, characters: String(ch), charactersIgnoringModifiers: String(ch),
                                            isARepeat: false, keyCode: 0) {
                    NSApp.postEvent(e, atStart: false)
                }
            }
        case "clickat":
            // clickat <x> <y> in points from the window's top-left; goes through normal event dispatch.
            let n = arg.split(separator: " ").compactMap { Double($0) }
            guard n.count == 2, let w = mainWindow else { break }
            let p = NSPoint(x: n[0], y: w.frame.height - n[1])
            for type in [NSEvent.EventType.leftMouseDown, .leftMouseUp] {
                if let e = NSEvent.mouseEvent(with: type, location: p, modifierFlags: [], timestamp: ProcessInfo.processInfo.systemUptime,
                                              windowNumber: w.windowNumber, context: nil, eventNumber: 0, clickCount: 1, pressure: 1) {
                    NSApp.postEvent(e, atStart: false)
                }
            }
            if let hit = w.contentView?.superview?.hitTest(p) { Log.debug("clickat hit \(type(of: hit)) \(hit.frame)") }
        case "settings":
            UserDefaults.standard.set(arg.isEmpty ? "general" : arg, forKey: "settings.tab")
            model?.openSettings?()
        case "closesettings":
            NSApp.windows.first { $0.title.contains("Settings") || $0.identifier?.rawValue.contains("Settings") == true }?.close()
        case "askopen": ws.openAsk()
        case "submitclose": ws.showSubmitReview = false
        case "commentclose": ws.commentDraft = nil
        case "palette": ws.palette = arg == "commands" ? .commands : .files
        case "ptype": ws.paletteQuery = arg
        case "pclose": ws.palette = nil
        case "tab": ws.sidebarTab = SidebarTab.allCases.first { $0.rawValue.lowercased() == arg.lowercased() } ?? .files
        case "scmsection": ws.scmSection = arg == "prs" ? .pullRequests : .changes
        case "scmselect":
            if let c = ws.scm.rows.compactMap(\.change).first(where: { $0.changeId.hasPrefix(arg) || $0.commitId.hasPrefix(arg) }) {
                Task { await ws.scm.select(c) }
            }
        case "comment":
            ws.draftComment()
        case "showsubmit": ws.showSubmitReview = true
        case "clearpending":
            for c in ws.review?.pendingComments ?? [] { ws.review?.removePending(c.id) }
        case "addpending":
            if var d = ws.commentDraft { d.body = arg; ws.review?.addPending(d); ws.commentDraft = nil }
        case "record": startRecording(arg)
        case "installgrammar":
            // installgrammar <url> [revision]
            let p = arg.split(separator: " ").map(String.init)
            guard let url = p.first else { break }
            Task {
                do {
                    let specs = try await GrammarRegistry.shared.install(url: url, subdirectory: nil, revision: p.count > 1 ? p[1] : nil) { Log.debug("grammar: \($0)") }
                    Log.debug("grammar installed: \(specs.map(\.name))")
                } catch { Log.debug("grammar install failed: \(error.localizedDescription)") }
            }
        case "hover":
            // hover <line>:<col> in the main editor
            if let tv = mainWindow?.contentView?.firstSubview(ofType: SourceTextView.self), let c = tv.coordinator, let d = c.display,
               let lm = tv.layoutManager, let tc = tv.textContainer {
                let off = d.displayOffset(pos(arg))
                let g = lm.glyphIndexForCharacter(at: min(off, max(0, d.ns.length - 1)))
                let r = lm.boundingRect(forGlyphRange: NSRange(location: g, length: 1), in: tc)
                c.hover.mouseMoved(at: NSPoint(x: r.midX + tv.textContainerInset.width, y: r.midY + tv.textContainerInset.height))
            }
        case "screenpos":
            // screenpos <line>:<col>: the glyph's centre in CoreGraphics screen coordinates (top-left origin)
            if let tv = mainWindow?.contentView?.firstSubview(ofType: SourceTextView.self), let c = tv.coordinator, let d = c.display,
               let lm = tv.layoutManager, let tc = tv.textContainer, let w = tv.window {
                let off = d.displayOffset(pos(arg))
                var r = lm.boundingRect(forGlyphRange: NSRange(location: lm.glyphIndexForCharacter(at: off), length: 1), in: tc)
                r.origin.x += tv.textContainerInset.width; r.origin.y += tv.textContainerInset.height
                let sr = w.convertToScreen(tv.convert(r, to: nil))
                let h = NSScreen.screens.first?.frame.height ?? 0
                Log.debug("screenpos: \(Int(sr.midX)) \(Int(h - sr.midY))")
            }
        case "hovershown":
            let shown = NSApp.windows.contains { $0.isVisible && $0.className.contains("Popover") }
            Log.debug("hovershown: \(shown)")
        case "headintel": Task { await ws.review?.startHeadIntel() }
        case "openjobtrace":
            if let j = ws.jobs.last(where: { $0.kind == .trace && $0.traceID != nil }) { ws.openJobTrace(j.id) }
        case "rulewriter": ws.ruleWriterSeed = arg; ws.showRuleWriter = true
        case "rulewriterclose": ws.showRuleWriter = false
        case "expandgroup":
            if let r = ws.review, let g = r.allGroups.first(where: { $0.title.contains(arg) }) { r.expandedGroups.insert(g.id) }
        case "collapseall": ws.review?.expandedGroups = []
        case "recordstop": Self.recordTimer?.invalidate(); Self.recordTimer = nil
        case "winframe":
            // x y w h in screen points, measured from the top-left of the main screen.
            let n = arg.split(separator: " ").compactMap { Double($0) }
            if n.count == 4, let w = mainWindow, let screen = NSScreen.screens.first {
                w.setFrame(NSRect(x: n[0], y: screen.frame.height - n[1] - n[3], width: n[2], height: n[3]), display: true, animate: false)
            }
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
            s += "review \(r.title) state=\(r.state) files=\(r.files.count) hunks=\(r.allHunks.count) viewed=\(r.progress.viewed)/\(r.progress.total) selected=\(ws.selectedHunkID ?? "-")\n"
            for t in ChangeTier.allCases {
                let hs = r.hunks(in: t)
                if hs.isEmpty { continue }
                s += "  \(t.rawValue): " + hs.map { "\($0.path.lastPathComponent)[\(r.analyses[$0.id]?.enclosing ?? "-")]: \(r.reasons(of: $0).joined(separator: ","))" }.joined(separator: " | ") + "\n"
            }
            if let o = r.overview { s += "  overview: \(o)\n" }
            if let ts = r.triageState { s += "  triage: \(ts)\n" }
            if let cs = r.classifyState { s += "  classify: \(cs)\n" }
        }
        s += "nav: reason=\(ws.navReason) step=\(ws.traces.currentStep.map(String.init) ?? "-") pane=\(ws.inspectorPane.rawValue) hunkContext=\(ws.showsHunkContext) hunk=\(ws.selectedHunkID.map { String($0.suffix(14)) } ?? "-") doc=\(ws.document?.path.lastPathComponent ?? "-")[\(ws.document?.revisionLabel ?? "wc")] line=\(ws.cursor.map { String($0.line + 1) } ?? "-") review=\(ws.review?.shortLabel ?? "-")\n"
        if let h = ws.review?.headIntel { s += "headintel: \(h.server.status.label) root=\(h.root.lastPathComponent)\n" }
        if let c = ws.context { s += "context: \(c.name) version=\(c.version.map { "\($0)" } ?? "wc") def=\(c.details?.definition.map { "\($0.path):\($0.line + 1)" } ?? "-") kind=\(c.details?.kindLabel ?? "-") source=\(c.details?.source.label ?? "-") callers=\(c.callers.count) refs=\(c.references.count) ra=\(ws.ra.status.label)\n" }
        if let cc = ws.changeContext { s += "changecontext: enclosing=\(cc.enclosing ?? "-") callers=\(cc.callers.map(\.name).prefix(4).joined(separator: ",")) loading=\(cc.loading)\n" }
        if let r = ws.review { s += "state: identity=\(r.identity ?? "-") viewed=\(r.viewed.count) drafts=\(r.pendingComments.count) llm=\(r.llm.count)\n" }
        if let r = ws.review { s += "classify: candidates=\(r.classifyCandidates.count) cached=\(r.allHunks.filter { r.llm[$0.contentKey] != nil }.count) hunks=\(r.allHunks.count)\n" }
        for a in ws.review?.attachments ?? [] { s += "attach: \(a.rule.title) [\(a.label)] result=\(ws.review?.attachmentResults[a.key] != nil)\n" }
        if let r = ws.review { for h in r.allHunks where r.analyses[h.id]?.reasons.contains(where: { $0.contains("join rendering") || $0.contains("places") }) == true { s += "semantic: \(h.id) \(r.analyses[h.id]!.reasons)\n" } }
        for g in ws.review?.allGroups ?? [] { s += "group: \(g.title) hunks=\(g.keys.count)\n" }
        for e in ws.jobs { s += "job: \(e.kind.rawValue) \(e.question) running=\(e.running) answer=\(e.answer.prefix(600)) err=\(e.error ?? "-")\n" }
        if let m = ws.statusMessage { s += "status: \(m)\n" }
        s += "scm kind=\(ws.scm.kind) rows=\(ws.scm.rows.count) changes=\(ws.scm.rows.compactMap(\.change).count) wc=\(ws.scm.workingCopy?.changeId ?? "-") wcfiles=\(ws.scm.workingCopyFiles.count) selected=\(ws.scm.selectedID ?? "-") selfiles=\(ws.scm.selectedFiles.map(\.path).prefix(5)) err=\(ws.scm.lastError ?? "-")\n"
        if let pr = ws.review?.pullRequest {
            s += "pr #\(pr.number) \(pr.state) checks=\(pr.checks.count) failing=\(pr.checks.filter(\.isFailure).count) threads=\(pr.threads.count) pending=\(ws.review?.pendingComments.count ?? 0)\n"
        }
        if let d = ws.document { s += "doclang=\(d.languageName) tokens=\(d.syntax.tokens.count) outline=\(d.syntax.flatOutline.prefix(6).map(\.name))\n" }
        Log.debug("DUMP\n" + s)
    }

    /// The active repository's window, else the first main window on screen.
    private var mainWindow: NSWindow? {
        if let p = model?.activePath, let w = model?.windows[p], w.isVisible { return w }
        return NSApp.windows.first { $0.isVisible && $0.frame.width > 400 && !$0.isSheet && !$0.title.contains("Settings") }
    }

    /// Output paths are confined to temporary directories.
    private func allowed(_ path: String) -> Bool {
        let p = URL(fileURLWithPath: path).standardizedFileURL.resolvingSymlinksInPath().path
        let roots = [URL(fileURLWithPath: NSTemporaryDirectory()).resolvingSymlinksInPath().path, "/private/tmp", "/tmp"]
        return roots.contains { p.hasPrefix($0 + "/") }
    }

    private func snapshot(_ path: String, viaWindowServer: Bool = true) {
        guard allowed(path) else { Log.debug("snapshot path refused: \(path)"); return }
        guard let window = mainWindow else { return }
        if viaWindowServer { capture(window, to: path); return }
        guard let view = window.contentView?.superview ?? window.contentView,
              let rep = view.bitmapImageRepForCachingDisplay(in: view.bounds) else { return }
        view.cacheDisplay(in: view.bounds, to: rep)
        if let data = rep.representation(using: .png, properties: [:]) {
            try? data.write(to: URL(fileURLWithPath: path))
            Log.debug("snapshot \(path) \(Int(view.bounds.width))x\(Int(view.bounds.height))")
        }
    }

    private func windowImage(_ w: NSWindow) -> CGImage? {
        // CGWindowListCreateImage is marked unavailable in the SDK but still works for a process's own
        // windows without screen-recording permission; resolve it dynamically.
        typealias Fn = @convention(c) (CGRect, UInt32, UInt32, UInt32) -> Unmanaged<CGImage>?
        guard let h = dlopen(nil, RTLD_NOW), let sym = dlsym(h, "CGWindowListCreateImage") else { return nil }
        let fn = unsafeBitCast(sym, to: Fn.self)
        // kCGWindowListOptionIncludingWindow = 1 << 3, kCGWindowImageBoundsIgnoreFraming = 1 << 0
        return fn(.null, 1 << 3, UInt32(w.windowNumber), 1)?.takeRetainedValue()
    }

    /// Captures a window, compositing an attached sheet on top so sheets appear in context.
    private func capture(_ window: NSWindow, to path: String) {
        guard let final = composited(window) else { return }
        if let data = NSBitmapImageRep(cgImage: final).representation(using: .png, properties: [:]) {
            try? data.write(to: URL(fileURLWithPath: path))
            Log.debug("snapshot(cg) \(path) \(final.width)x\(final.height)")
        }
    }

    private func composited(_ window: NSWindow) -> CGImage? {
        guard let base = windowImage(window) else { return nil }
        var final = base
        if let sheet = window.attachedSheet, let sheetImg = windowImage(sheet) {
            let scale = CGFloat(base.width) / window.frame.width
            let w = base.width, h = base.height
            if let ctx = CGContext(data: nil, width: w, height: h, bitsPerComponent: 8, bytesPerRow: 0,
                                   space: CGColorSpaceCreateDeviceRGB(), bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue) {
                ctx.draw(base, in: CGRect(x: 0, y: 0, width: w, height: h))
                let sf = sheet.frame, wf = window.frame
                let rect = CGRect(x: (sf.minX - wf.minX) * scale, y: (sf.minY - wf.minY) * scale,
                                  width: CGFloat(sheetImg.width), height: CGFloat(sheetImg.height))
                ctx.draw(sheetImg, in: rect)
                if let img = ctx.makeImage() { final = img }
            }
        }
        return final
    }

    private static var recordTimer: Timer?
    private static let recordQueue = DispatchQueue(label: "spelunk.record")

    /// Writes the main window as JPEG frames plus `frames.txt` (index and seconds since start) into
    /// `dir`, about ten per second, until `recordstop`.
    private func startRecording(_ dir: String) {
        guard allowed(dir) else { Log.debug("record path refused: \(dir)"); return }
        Self.recordTimer?.invalidate()
        try? FileManager.default.createDirectory(atPath: dir, withIntermediateDirectories: true)
        let start = Date()
        var index = 0
        var busy = false
        let log = URL(fileURLWithPath: dir).appendingPathComponent("frames.txt")
        FileManager.default.createFile(atPath: log.path, contents: nil)
        let handle = try? FileHandle(forWritingTo: log)
        Self.recordTimer = Timer.scheduledTimer(withTimeInterval: 0.1, repeats: true) { _ in
            MainActor.assumeIsolated {
                guard !busy, let w = self.mainWindow,
                      let img = self.composited(w) else { return }
                busy = true
                let i = index, t = Date().timeIntervalSince(start)
                index += 1
                Self.recordQueue.async {
                    let name = String(format: "f%05d.jpg", i)
                    if let data = NSBitmapImageRep(cgImage: img).representation(using: .jpeg, properties: [.compressionFactor: 0.9]) {
                        try? data.write(to: URL(fileURLWithPath: dir).appendingPathComponent(name))
                        handle?.write(Data(String(format: "%@ %.3f\n", name, t).utf8))
                    }
                    DispatchQueue.main.async { busy = false }
                }
            }
        }
    }
}

extension NSView {
    func firstSubview<T: NSView>(ofType t: T.Type) -> T? {
        if let v = self as? T { return v }
        for c in subviews { if let v = c.firstSubview(ofType: t) { return v } }
        return nil
    }
}
