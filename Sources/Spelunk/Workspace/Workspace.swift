import AppKit
import Foundation
import Observation

enum SidebarTab: String, CaseIterable, Identifiable {
    case changes = "Changes", files = "Files", search = "Search"
    var id: String { rawValue }
}

enum ReviewSide: String, CaseIterable { case before = "Before", after = "After" }

/// What the context pane is about: the symbol under the cursor.
@MainActor @Observable
final class SymbolContext {
    let name: String
    let path: String
    let pos: SourcePos
    var details: SymbolDetails?
    var references: [ReferenceHit] = []
    var referencesSource: IntelSource?
    var implementations: [ReferenceHit] = []
    var implementationsSource: IntelSource?
    var callDirection: CallDirection = .incoming
    var calls: [CallNode] = []
    var loadingReferences = false
    var loadingCalls = false
    var loadingImpls = false

    init(name: String, path: String, pos: SourcePos) { self.name = name; self.path = path; self.pos = pos }
}

struct AskEntry: Identifiable {
    let id = UUID()
    var question: String
    var anchor: String?
    var answer: String = ""
    var activity: [String] = []
    var running = true
    var cost: Double = 0
    var error: String?
}

@MainActor @Observable
final class Workspace {
    let root: URL
    var name: String { root.lastPathComponent }
    var vcs = VCSInfo(kind: .none, revision: "", description: "", hasGit: false)
    var allFiles: [String] = []
    var tree = FileNode(name: "", path: "", children: [])
    var showTests = UserDefaults.standard.object(forKey: "showTests") as? Bool ?? false { didSet { UserDefaults.standard.set(showTests, forKey: "showTests"); rebuildTree() } }
    var sourceOnly = UserDefaults.standard.object(forKey: "sourceOnly") as? Bool ?? true { didSet { UserDefaults.standard.set(sourceOnly, forKey: "sourceOnly"); rebuildTree() } }
    var visibleFileCount = 0

    var sidebarTab: SidebarTab = .files
    var document: SourceDocument?
    var selection: SourceRange?
    var highlightRanges: [SourceRange] = []
    var revealRequest = 0
    var cursor: SourcePos?
    var context: SymbolContext?
    var backStack: [CodeLocation] = []
    var forwardStack: [CodeLocation] = []
    var statusMessage: String?

    var review: ReviewSession?
    var reviewSide: ReviewSide = .after
    var selectedHunkID: String?

    var askEntries: [AskEntry] = []
    var traceGenerating: String?
    var showAsk = false

    let docs: DocumentCache
    let ra: RustAnalyzer
    let scip: SCIPService
    let clippy: ClippyService
    let intel: IntelHub
    let traces: TraceStore
    let bookmarks: BookmarkStore
    private var contextTask: Task<Void, Never>?

    init(root: URL) {
        self.root = root.standardizedFileURL
        docs = DocumentCache(root: self.root)
        ra = RustAnalyzer(root: self.root)
        scip = SCIPService(root: self.root)
        clippy = ClippyService(root: self.root)
        intel = IntelHub(root: self.root, ra: ra, scip: scip, docs: docs)
        traces = TraceStore(root: self.root)
        bookmarks = BookmarkStore(root: self.root)
    }

    func start() async {
        Log.debug("start \(root.path)")
        vcs = await VCS.detect(root)
        Log.debug("vcs \(vcs.kind)")
        allFiles = await VCS.listFiles(root, vcs: vcs.kind)
        Log.debug("files \(allFiles.count)")
        rebuildTree()
        Log.debug("tree built")
        let isRust = FileManager.default.fileExists(atPath: root.appendingPathComponent("Cargo.toml").path)
        if isRust && UserDefaults.standard.object(forKey: "autoStartRA") as? Bool ?? true { ra.start() }
        Log.debug("ra started")
        scip.loadCached(sourceFiles: allFiles)
        Log.debug("scip cache requested")
        if let readme = ["README.md", "src/main.rs", "src/lib.rs"].first(where: { allFiles.contains($0) }) {
            open(CodeLocation(path: readme, range: SourceRange(line: 0)), record: false)
            Log.debug("opened \(readme)")
        }
    }

    func shutdown() { ra.stop(); clippy.cancel(); scip.cancel() }

    func rebuildTree() {
        let filtered = allFiles.filter { p in
            (!sourceOnly || FileClassifier.isSource(p)) && (showTests || !FileClassifier.isTest(p))
        }
        visibleFileCount = filtered.count
        tree = FileNode.build(filtered)
    }

    // MARK: Navigation

    var currentLocation: CodeLocation? {
        guard let d = document else { return nil }
        return CodeLocation(path: d.path, range: selection ?? SourceRange(line: cursor?.line ?? 0))
    }

    /// Opens a location in the working copy. Records it in history, and in the active trace when recording.
    func open(_ loc: CodeLocation, record: Bool = true, edge: TraceEdge? = nil, title: String? = nil, source: IntelSource = .manual) {
        if record, let cur = currentLocation, cur != loc { backStack.append(cur); forwardStack.removeAll() }
        if document?.path != loc.path || document?.revisionLabel != nil {
            guard let d = docs.document(loc.path) else { statusMessage = "Could not open \(loc.path)"; return }
            document = d
            ra.didOpen(path: d.path, text: d.text, language: d.language)
        }
        selection = loc.range
        cursor = loc.range.start
        highlightRanges = []
        revealRequest += 1
        if let edge, let d = document {
            let name = title ?? d.word(at: loc.range.start)?.0 ?? loc.shortDescription
            traces.record(TraceStep(title: name, location: loc, edge: edge, source: source,
                                    snippet: d.lineText(loc.line).trimmingCharacters(in: .whitespaces)))
        }
    }

    /// Shows a document that is not the working copy (review before/after).
    func show(_ doc: SourceDocument, line: Int) {
        if let cur = currentLocation, cur.path != doc.path || document?.revisionLabel != doc.revisionLabel { backStack.append(cur) }
        document = doc
        if doc.revisionLabel == nil { ra.didOpen(path: doc.path, text: doc.text, language: doc.language) }
        selection = SourceRange(line: line)
        cursor = SourcePos(line: line, col: 0)
        revealRequest += 1
    }

    func goBack() {
        guard let loc = backStack.popLast() else { return }
        if let cur = currentLocation { forwardStack.append(cur) }
        open(loc, record: false)
    }

    func goForward() {
        guard let loc = forwardStack.popLast() else { return }
        if let cur = currentLocation { backStack.append(cur) }
        open(loc, record: false)
    }

    // MARK: Symbol interactions

    /// Click in the editor: update the context pane for the symbol under the cursor.
    func didClick(at p: SourcePos) {
        cursor = p
        guard let d = document, let (name, range) = d.word(at: p) else { return }
        if context?.name == name && context?.path == d.path && context?.pos.line == p.line { return }
        let ctx = SymbolContext(name: name, path: d.path, pos: range.start)
        context = ctx
        highlightRanges = []
        contextTask?.cancel()
        let isWorkingCopy = d.revisionLabel == nil
        contextTask = Task {
            if isWorkingCopy && ra.status.isUsable, let hl = try? await ra.documentHighlights(path: d.path, at: range.start), !hl.isEmpty {
                if context === ctx { highlightRanges = hl }
            } else if context === ctx {
                highlightRanges = localOccurrences(of: name, in: d)
            }
            guard isWorkingCopy else {
                ctx.details = SymbolDetails(name: name, kindLabel: "Symbol", source: .textSearch)
                return
            }
            ctx.details = await intel.details(path: d.path, at: range.start, name: name)
            await loadReferences(ctx)
            await loadCalls(ctx)
            await loadImplementations(ctx)
        }
    }

    private func localOccurrences(of name: String, in d: SourceDocument) -> [SourceRange] {
        guard let re = try? NSRegularExpression(pattern: "\\b\(NSRegularExpression.escapedPattern(for: name))\\b") else { return [] }
        return re.matches(in: d.text, range: NSRange(location: 0, length: d.ns.length)).prefix(500).map {
            SourceRange(start: d.lines.position(of: $0.range.location), end: d.lines.position(of: NSMaxRange($0.range)))
        }
    }

    func loadReferences(_ ctx: SymbolContext) async {
        ctx.loadingReferences = true
        let (refs, src) = await intel.references(path: ctx.path, at: ctx.pos, name: ctx.name)
        ctx.references = refs
        ctx.referencesSource = src
        ctx.loadingReferences = false
    }

    func loadCalls(_ ctx: SymbolContext) async {
        ctx.loadingCalls = true
        ctx.calls = await intel.callRoots(ctx.callDirection, path: ctx.path, at: ctx.pos, name: ctx.name)
        ctx.loadingCalls = false
    }

    func loadImplementations(_ ctx: SymbolContext) async {
        let kind = ctx.details?.kindLabel ?? ""
        guard kind == "Trait" || kind == "Struct" || kind == "Enum" || kind == "Method" || kind == "Function" || kind == "Symbol" else { return }
        ctx.loadingImpls = true
        let (hits, src) = await intel.implementations(path: ctx.path, at: ctx.pos, name: ctx.name)
        ctx.implementations = hits.filter { !($0.location.path == ctx.path && $0.location.line == ctx.pos.line) }
        ctx.implementationsSource = src
        ctx.loadingImpls = false
    }

    func goToDefinition(at p: SourcePos) {
        guard let d = document, let (name, range) = d.word(at: p) else { return }
        Task {
            statusMessage = "Resolving \(name)…"
            let (defs, src) = await intel.definitions(path: d.path, at: range.start, name: name)
            statusMessage = nil
            guard let first = defs.first else { statusMessage = "No definition found for \(name)"; return }
            if traces.isRecording, traces.active?.steps.isEmpty ?? true {
                traces.append(TraceStep(title: d.syntax.enclosingItem(line: p.line)?.qualifiedName ?? name,
                                        location: CodeLocation(path: d.path, range: range), edge: .start, source: .manual,
                                        snippet: d.lineText(p.line).trimmingCharacters(in: .whitespaces)))
            }
            open(first, edge: .definition, title: name, source: src)
            if defs.count > 1 { statusMessage = "\(defs.count) definitions (\(src.label)); showing first" }
        }
    }

    func followReference(_ hit: ReferenceHit) {
        open(hit.location, edge: hit.isDefinition ? .definition : .reference, title: hit.enclosing ?? context?.name, source: hit.source)
    }

    func followCall(_ node: CallNode, direction: CallDirection) {
        let target = direction == .incoming ? (node.callSites.first ?? node.location) : node.location
        open(target, edge: direction == .incoming ? .caller : .callee, title: node.name, source: node.source)
    }

    func addCurrentToTrace() {
        guard let d = document, let p = cursor else { return }
        let item = d.syntax.enclosingItem(line: p.line)
        let title = context?.name ?? item?.qualifiedName ?? d.path.lastPathComponent
        traces.append(TraceStep(title: title, location: CodeLocation(path: d.path, range: selection ?? SourceRange(line: p.line, col: p.col)),
                                edge: .manual, source: .manual, snippet: d.lineText(p.line).trimmingCharacters(in: .whitespaces)))
    }

    func toggleBookmark() {
        guard let d = document, let p = cursor else { return }
        let item = d.syntax.enclosingItem(line: p.line)
        bookmarks.toggle(Bookmark(title: context?.name ?? item?.qualifiedName ?? d.path.lastPathComponent,
                                  location: CodeLocation(path: d.path, range: SourceRange(line: p.line, col: p.col)),
                                  context: reviewContextLabel))
    }

    var reviewContextLabel: String {
        if let r = review { return r.target.label }
        return vcs.kind == .none ? "" : (vcs.description.isEmpty ? vcs.revision : vcs.description)
    }

    func playStep(_ index: Int) {
        guard let t = traces.active, index >= 0, index < t.steps.count else { return }
        traces.currentStep = index
        open(t.steps[index].location, record: true)
    }

    // MARK: Review

    func startReview(_ target: ReviewTarget) {
        let r = ReviewSession(root: root, target: target)
        review = r
        sidebarTab = .changes
        Task {
            await r.load()
            if let first = r.hunks(in: .critical).first ?? r.hunks(in: .behavior).first ?? r.allHunks.first { selectHunk(first) }
        }
    }

    func selectHunk(_ h: Hunk) {
        selectedHunkID = h.id
        guard let r = review, let f = r.file(for: h) else { return }
        Task {
            let side: ReviewSession.Side = (reviewSide == .before || f.status == .deleted) ? .old : .new
            let line = side == .old ? h.anchorOldLine : h.anchorNewLine
            if side == .new && r.afterIsWorkingCopy {
                open(CodeLocation(path: f.newPath, range: SourceRange(line: line)), record: true)
            } else if let doc = await r.document(side == .old ? f.oldPath : f.newPath, side: side) {
                show(doc, line: line)
            }
        }
    }

    func setReviewSide(_ side: ReviewSide) {
        reviewSide = side
        if let id = selectedHunkID, let h = review?.allHunks.first(where: { $0.id == id }) { selectHunk(h) }
    }

    /// Per-line diff markers for the document currently shown, when it belongs to the review.
    func diffMarkers(for doc: SourceDocument) -> [Int: DiffLineKind] {
        guard let r = review, let f = r.files.first(where: { $0.newPath == doc.path || $0.oldPath == doc.path }) else { return [:] }
        let isOld = doc.revisionLabel == "Before"
        var m: [Int: DiffLineKind] = [:]
        for h in f.hunks {
            for l in h.lines {
                if isOld, l.kind == .removed, let o = l.oldLine { m[o] = .removed }
                if !isOld, l.kind == .added, let n = l.newLine { m[n] = .added }
            }
        }
        return m
    }

    // MARK: Claude

    func anchorDescription() -> String? {
        guard let d = document, let p = cursor else { return nil }
        let item = d.syntax.enclosingItem(line: p.line)
        var s = "\(d.path):\(p.line + 1)"
        if let item { s += " (in \(item.kind.label.lowercased()) `\(item.qualifiedName)`)" }
        if let c = context { s += ", symbol `\(c.name)`" }
        return s
    }

    func ask(_ question: String, includeAnchor: Bool) {
        let anchor = includeAnchor ? anchorDescription() : nil
        var entry = AskEntry(question: question, anchor: anchor)
        let id = entry.id
        entry.activity = []
        askEntries.append(entry)
        showAsk = true
        var prompt = question
        if let anchor { prompt += "\n\nI am looking at \(anchor)." }
        if let r = review { prompt += "\n\nContext: I am reviewing \(r.title) (\(r.target.label))." }
        Task {
            do {
                let res = try await Claude.run(prompt: prompt, system: ClaudeTasks.askSystem, cwd: root) { [weak self] ev in
                    Task { @MainActor in
                        guard let self, let i = self.askEntries.firstIndex(where: { $0.id == id }) else { return }
                        switch ev {
                        case .toolUse(let n, let s): self.askEntries[i].activity.append("\(n) \(s)")
                        case .text(let t): self.askEntries[i].answer = t
                        }
                    }
                }
                if let i = askEntries.firstIndex(where: { $0.id == id }) {
                    askEntries[i].answer = res.text
                    askEntries[i].running = false
                    askEntries[i].cost = res.costUSD
                }
            } catch {
                if let i = askEntries.firstIndex(where: { $0.id == id }) {
                    askEntries[i].error = error.localizedDescription
                    askEntries[i].running = false
                }
            }
        }
    }

    func generateTrace(_ question: String, includeAnchor: Bool) {
        let anchor = includeAnchor ? anchorDescription() : nil
        traceGenerating = "Starting Claude"
        Task {
            do {
                let res = try await Claude.run(prompt: ClaudeTasks.tracePrompt(question: question, anchor: anchor),
                                               system: ClaudeTasks.traceSystem, cwd: root, schema: ClaudeTasks.traceSchema) { [weak self] ev in
                    if case .toolUse(let n, let s) = ev { Task { @MainActor in self?.traceGenerating = "\(n) \(s)" } }
                }
                let resp = try Claude.decode(ClaudeTasks.TraceResponse.self, from: res)
                let trace = ClaudeTasks.materialize(resp, question: question, docs: docs)
                traces.add(trace)
                traceGenerating = nil
                statusMessage = String(format: "Trace generated: %d steps, %d verified ($%.2f)",
                                       trace.steps.count, trace.steps.filter(\.verified).count, res.costUSD)
                playStep(0)
            } catch {
                traceGenerating = nil
                statusMessage = "Trace failed: \(error.localizedDescription)"
            }
        }
    }

    /// Opens a `path:line` reference from Claude's prose.
    func openCitation(_ s: String) {
        let parts = s.split(separator: ":")
        guard let path = parts.first else { return }
        let line = parts.count > 1 ? (Int(parts[1]) ?? 1) - 1 : 0
        var p = String(path)
        if !allFiles.contains(p), let match = allFiles.first(where: { $0.hasSuffix("/" + p) }) { p = match }
        open(CodeLocation(path: p, range: SourceRange(line: max(0, line))), edge: .manual, source: .claude)
    }
}
