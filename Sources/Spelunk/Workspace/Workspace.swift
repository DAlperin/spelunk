import AppKit
import Foundation
import Observation

enum SidebarTab: String, CaseIterable, Identifiable {
    case changes = "Changes", files = "Files", search = "Search", scm = "Source"
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
    var allFileSet: Set<String> = []
    var loadingFiles = false
    var childRepos: [URL] = []
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
    /// How the current location was reached; becomes the edge of a step added here.
    var arrival: (edge: TraceEdge, source: IntelSource)?
    var editingStepID: UUID?
    var palette: PaletteMode? { didSet { if palette != oldValue { paletteQuery = "" } } }
    var paletteQuery = ""
    var scmSection: SCMSection = .changes
    var showSubmitReview = false
    var commentDraft: PendingComment?
    var recentFiles: [String] = []

    /// Always-on review of the current jj revision (or uncommitted git changes).
    var workingReview: ReviewSession?
    /// Reviews opened explicitly: pull requests, graph changes, custom ranges.
    var pinnedReviews: [ReviewSession] = []
    /// Key of the pinned review being shown; nil shows the working copy.
    var activeReviewKey: String?

    var review: ReviewSession? {
        get {
            if let k = activeReviewKey, let r = pinnedReviews.first(where: { $0.target.key == k }) { return r }
            return workingReview
        }
        set {
            // Clearing the review closes the pinned one being shown and falls back to the working copy.
            if newValue == nil, let k = activeReviewKey { closeReview(k) }
        }
    }
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
    let github: GitHubService
    let scm: SCMService
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
        github = GitHubService(root: self.root)
        scm = SCMService(root: self.root)
        grammarObserver = NotificationCenter.default.addObserver(forName: .grammarsChanged, object: nil, queue: .main) { [weak self] _ in
            MainActor.assumeIsolated { self?.reloadCurrentDocument() }
        }
    }

    @ObservationIgnored private var grammarObserver: NSObjectProtocol?

    /// Re-parses open documents, e.g. after grammars change.
    func reloadCurrentDocument(keepPosition: Bool = false) {
        docs.invalidate()
        guard let d = document, d.revisionLabel == nil, let fresh = docs.document(d.path) else { return }
        document = fresh
        ra.didOpen(path: fresh.path, text: fresh.text, language: fresh.language)
        if !keepPosition { revealRequest += 1 }
    }

    func start() async {
        Log.debug("start \(root.path)")
        loadingFiles = true
        vcs = await VCS.detect(root)
        Log.debug("vcs \(vcs.kind) problem=\(vcs.problem ?? "-")")
        if vcs.kind == .none {
            childRepos = VCS.childRepositories(root)
        }
        allFiles = await VCS.listFiles(root, vcs: vcs.kind)
        allFileSet = Set(allFiles)
        Log.debug("files \(allFiles.count)")
        await rebuildTreeAsync()
        loadingFiles = false
        Log.debug("tree built")
        let isRust = FileManager.default.fileExists(atPath: root.appendingPathComponent("Cargo.toml").path)
        if isRust && UserDefaults.standard.object(forKey: "autoStartRA") as? Bool ?? true { ra.start() }
        scip.loadCached(sourceFiles: allFiles)
        startWatching()
        Task { await refreshWorkingReview() }
        if let readme = ["README.md", "src/main.rs", "src/lib.rs"].first(where: { allFileSet.contains($0) }) {
            open(CodeLocation(path: readme, range: SourceRange(line: 0)), record: false)
        }
    }

    func shutdown() { ra.stop(); clippy.cancel(); scip.cancel(); watcher?.stop() }

    @ObservationIgnored private var watcher: FileWatcher?
    @ObservationIgnored private var refreshTask: Task<Void, Never>?

    private func startWatching() {
        let w = FileWatcher(root: root) { [weak self] paths in
            Task { @MainActor in self?.filesChanged(paths) }
        }
        w.start()
        watcher = w
    }

    /// Debounced reaction to edits on disk (yours, Claude's, a checkout): refresh the open file,
    /// the working-copy review, and the change graph when it is visible.
    private func filesChanged(_ paths: [String]) {
        if let d = document, d.revisionLabel == nil, paths.contains(d.path) { reloadCurrentDocument(keepPosition: true) }
        refreshTask?.cancel()
        refreshTask = Task {
            try? await Task.sleep(nanoseconds: 600_000_000)
            guard !Task.isCancelled else { return }
            await refreshWorkingReview()
            if sidebarTab == .scm { await scm.refresh(kind: vcs.kind) }
        }
    }

    /// What "the current revision" means: @ when it has changes, otherwise the change below it
    /// (right after `jj new`). For git, uncommitted changes, or the last commit when clean.
    private func workingTarget() async -> ReviewTarget? {
        switch vcs.kind {
        case .jj:
            let empty = (try? await Shell.output("jj", ["log", "--no-graph", "-r", "@", "-T", "if(empty, \"1\", \"0\")"], cwd: root))?
                .trimmingCharacters(in: .whitespacesAndNewlines) == "1"
            return empty ? .jj(from: "@--", to: "@-") : .jj(from: "@-", to: "@")
        case .git:
            let dirty = !((try? await Shell.output("git", ["status", "--porcelain", "--untracked-files=no"], cwd: root)) ?? "").isEmpty
            return dirty ? .git(base: "HEAD", head: nil) : .git(base: "HEAD~1", head: "HEAD")
        case .none:
            return nil
        }
    }

    func refreshWorkingReview() async {
        guard let target = await workingTarget() else { workingReview = nil; return }
        if let r = workingReview, r.target == target {
            await r.load()
        } else {
            let r = ReviewSession(root: root, target: target, github: github, tracksWorkingCopy: true)
            workingReview = r
            await r.load()
        }
    }

    func closeReview(_ key: String) {
        pinnedReviews.removeAll { $0.target.key == key }
        if activeReviewKey == key { activeReviewKey = nil }
    }

    func checkOut(_ r: ReviewSession, _ option: ReviewSession.CheckoutOption) async {
        statusMessage = "Checking out…"
        do {
            try await r.runCheckout(option)
            vcs = await VCS.detect(root)
            statusMessage = "Checked out: \(option.label)"
        } catch {
            statusMessage = "Check out failed: \(error.localizedDescription)"
        }
        await refreshWorkingReview()
        await scm.refresh(kind: vcs.kind)
    }

    func showWorkingReview() {
        activeReviewKey = nil
        sidebarTab = .changes
        if let r = workingReview, let h = r.hunks(in: .critical).first ?? r.hunks(in: .behavior).first ?? r.allHunks.first { selectHunk(h) }
    }

    func rebuildTree() {
        Task { await rebuildTreeAsync() }
    }

    /// Filters and builds the file tree off the main actor; large repositories have 100k+ paths.
    func rebuildTreeAsync() async {
        let files = allFiles, sourceOnly = sourceOnly, showTests = showTests
        let (count, node) = await Task.detached(priority: .userInitiated) {
            let filtered = files.filter { p in
                (!sourceOnly || FileClassifier.isSource(p)) && (showTests || !FileClassifier.isTest(p))
            }
            return (filtered.count, FileNode.build(filtered))
        }.value
        visibleFileCount = count
        tree = node
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
            recentFiles.removeAll { $0 == loc.path }
            recentFiles.insert(loc.path, at: 0)
            if recentFiles.count > 30 { recentFiles.removeLast() }
            document = d
            ra.didOpen(path: d.path, text: d.text, language: d.language)
        }
        selection = loc.range
        cursor = loc.range.start
        highlightRanges = []
        revealRequest += 1
        arrival = edge.map { (edge: $0, source: source) }
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
        let isWorkingCopy = d.revisionLabel == nil
        // Code intelligence answers about the files on disk. For a Before/After view, query the same
        // symbol at its nearest occurrence in the working-copy file (falls back to name-based search
        // when the file no longer exists there).
        var queryPos = range.start
        if !isWorkingCopy, let wc = docs.document(d.path),
           let mapped = ClaudeTasks.nearestOccurrence(of: name, in: wc, near: p.line) {
            queryPos = mapped.start
        }
        let ctx = SymbolContext(name: name, path: d.path, pos: queryPos)
        context = ctx
        highlightRanges = []
        contextTask?.cancel()
        contextTask = Task {
            if isWorkingCopy && ra.status.isUsable, let hl = try? await ra.documentHighlights(path: d.path, at: range.start), !hl.isEmpty {
                if context === ctx { highlightRanges = hl }
            } else if context === ctx {
                highlightRanges = localOccurrences(of: name, in: d)
            }
            ctx.details = await intel.details(path: d.path, at: queryPos, name: name)
            guard context === ctx else { return }
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

    /// Adds the cursor location to the active code path, after the current step, and starts editing its note.
    func addCurrentToTrace() {
        guard let d = document, let p = cursor else { return }
        let item = d.syntax.enclosingItem(line: p.line)
        let title = item?.qualifiedName ?? context?.name ?? d.path.lastPathComponent
        let edge: TraceEdge = (traces.active?.steps.isEmpty ?? true) ? .start : (arrival?.edge ?? .manual)
        let step = TraceStep(title: title, location: CodeLocation(path: d.path, range: selection ?? SourceRange(line: p.line, col: p.col)),
                             edge: edge, source: arrival?.source ?? .manual,
                             snippet: d.lineText(p.line).trimmingCharacters(in: .whitespaces))
        traces.insert(step)
        editingStepID = step.id
    }

    func newCodePath(fromCursor: Bool) {
        traces.create(title: "Untitled path", origin: .manual)
        if fromCursor { addCurrentToTrace() }
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

    /// Opens a review. The working copy's own target switches to the working tab; anything else is
    /// pinned beside it (reusing an existing pin for the same target).
    func startReview(_ target: ReviewTarget, focusPath: String? = nil) {
        sidebarTab = .changes
        let r: ReviewSession
        if let w = workingReview, w.target == target {
            activeReviewKey = nil
            r = w
        } else if let existing = pinnedReviews.first(where: { $0.target == target }) {
            activeReviewKey = existing.target.key
            r = existing
        } else {
            r = ReviewSession(root: root, target: target, github: github)
            pinnedReviews.append(r)
            activeReviewKey = target.key
        }
        Task {
            await r.load()
            let focused = focusPath.flatMap { p in r.allHunks.first { $0.path == p } }
            if let first = focused ?? r.hunks(in: .critical).first ?? r.hunks(in: .behavior).first ?? r.allHunks.first { selectHunk(first) }
        }
    }

    func reviewChange(_ c: SCMService.Change, focusPath: String? = nil) {
        switch scm.kind {
        case .jj: startReview(.jj(from: "\(c.rev)-", to: c.rev), focusPath: focusPath)
        default: startReview(.git(base: "\(c.commitId)^", head: c.commitId), focusPath: focusPath)
        }
    }

    /// Starts a review comment on the cursor line, on whichever side of the diff is showing.
    func draftComment() {
        guard let r = review, let d = document, let c = cursor else { return }
        let side = d.revisionLabel == "Before" ? "LEFT" : "RIGHT"
        let path = side == "LEFT" ? (r.files.first { $0.oldPath == d.path }?.oldPath ?? d.path) : d.path
        commentDraft = PendingComment(path: path, line: c.line + 1, side: side, body: "")
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

    /// Show the other side's lines inline (removed lines in the After view, added lines in Before).
    var inlineDiff = UserDefaults.standard.object(forKey: "editor.inlineDiff") as? Bool ?? true {
        didSet { UserDefaults.standard.set(inlineDiff, forKey: "editor.inlineDiff") }
    }

    /// Lines from the other side of the diff to show inline, keyed by the real line they precede.
    func phantomLines(for doc: SourceDocument) -> [Int: [PhantomLine]] {
        guard inlineDiff, let r = review,
              let f = r.files.first(where: { $0.newPath == doc.path || $0.oldPath == doc.path }) else { return [:] }
        let isOld = doc.revisionLabel == "Before"
        if f.status == (isOld ? .deleted : .added) { return [:] }
        let other = r.cachedDocument(isOld ? f.newPath : f.oldPath, side: isOld ? .new : .old)
        let phantomKind: DiffLineKind = isOld ? .added : .removed
        var out: [Int: [PhantomLine]] = [:]
        func phantom(_ l: DiffLine) -> PhantomLine {
            let otherLine = (isOld ? l.newLine : l.oldLine) ?? 0
            var tokens: [Token] = []
            if let other, otherLine < other.lines.lineCount {
                let range = other.lines.lineRange(otherLine)
                for t in other.syntax.tokens where t.range.location < NSMaxRange(range) && NSMaxRange(t.range) > range.location {
                    let start = max(t.range.location, range.location)
                    let end = min(NSMaxRange(t.range), NSMaxRange(range))
                    tokens.append(Token(range: NSRange(location: start - range.location, length: end - start), kind: t.kind))
                }
            }
            return PhantomLine(kind: phantomKind, otherLine: otherLine, text: l.text, tokens: tokens)
        }
        for h in f.hunks {
            var pending: [DiffLine] = []
            for l in h.lines {
                if l.kind == phantomKind { pending.append(l); continue }
                if let anchor = isOld ? l.oldLine : l.newLine, !pending.isEmpty {
                    out[anchor, default: []] += pending.map(phantom)
                    pending = []
                }
            }
            if !pending.isEmpty {
                let anchor = isOld ? h.oldStart - 1 + h.oldCount : h.newStart - 1 + h.newCount
                out[max(0, anchor), default: []] += pending.map(phantom)
            }
        }
        return out
    }

    /// Lines carrying review threads (true when unresolved) or pending comments, for the shown side.
    func commentLines(for doc: SourceDocument) -> [Int: Bool] {
        guard let r = review else { return [:] }
        let side = doc.revisionLabel == "Before" ? "LEFT" : "RIGHT"
        var out: [Int: Bool] = [:]
        for t in r.pullRequest?.threads ?? [] where t.path == doc.path && t.side == side {
            if let l = t.anchorLine { out[l - 1] = (out[l - 1] ?? false) || !t.isResolved }
        }
        for c in r.pendingComments where c.path == doc.path && c.side == side { out[c.line - 1] = true }
        return out
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
                let res = try await Claude.run(prompt: prompt, system: ClaudeTasks.askSystem, cwd: root, task: .ask) { [weak self] ev in
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
                                               system: ClaudeTasks.traceSystem, cwd: root, task: .trace, schema: ClaudeTasks.traceSchema) { [weak self] ev in
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
        if !allFileSet.contains(p), let match = allFiles.first(where: { $0.hasSuffix("/" + p) }) { p = match }
        open(CodeLocation(path: p, range: SourceRange(line: max(0, line))), edge: .manual, source: .claude)
    }
}
