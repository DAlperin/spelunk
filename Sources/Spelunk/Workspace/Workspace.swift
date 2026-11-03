import AppKit
import Foundation
import Observation

enum SidebarTab: String, CaseIterable, Identifiable {
    case changes = "Review", files = "Files", search = "Search", scm = "History"
    var id: String { rawValue }
}

enum ContextFocus { case symbol, hunk }

enum InspectorPane: String, CaseIterable, Identifiable {
    case context = "Context", claude = "Claude", conversation = "Conversation", paths = "Code Paths", outline = "Outline", bookmarks = "Bookmarks", problems = "Problems"
    var id: String { rawValue }
}

enum ReviewSide: String, CaseIterable { case before = "Before", after = "After" }

/// How a review shows a file: the new version with removed lines inline, both versions side by
/// side, or either version alone.
enum DiffMode: String, CaseIterable, Identifiable {
    case inline = "Inline", split = "Split", after = "After", before = "Before"
    var id: String { rawValue }
    /// The modes offered in the toolbar; Before stays reachable from menus and the palette.
    static let toolbar: [DiffMode] = [.inline, .split, .after]
}

/// What the context pane is about: the symbol under the cursor.
@MainActor @Observable
final class SymbolContext {
    let name: String
    let path: String
    let pos: SourcePos
    /// The intelligence answering for this symbol, and the version its answers belong to.
    var hub: IntelHub?
    var version: CodeVersion?
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
    var callers: [CallNode] = []
    var callees: [CallNode] = []
    var loadingCallers = false
    var loadingCallees = false
    /// Text matches in files of other languages (scripts, docs, SQL tests).
    var mentions: [TextMatch] = []
    /// "Method of Instance", from the definition's enclosing impl or trait.
    var container: String?
    var isPublic: Bool?
    var started = Date()
    var elapsed: TimeInterval?

    init(name: String, path: String, pos: SourcePos) { self.name = name; self.path = path; self.pos = pos }
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
    var changeContext: ChangeContext?
    /// Which subject the context pane shows; set by the last hunk selection or symbol click.
    var contextFocus: ContextFocus = .symbol
    /// Keeps the current symbol in the context pane while you click elsewhere.
    var contextPinned = false
    var inspectorPane: InspectorPane = .context
    var showGenerateTrace = false
    var showRuleWriter = false
    @ObservationIgnored var navGeneration = 0
    @ObservationIgnored var phantomCache: (key: String, value: [Int: [PhantomLine]])?
    @ObservationIgnored var hoverCache: [String: HoverInfo] = [:]
    var navReason: NavReason = .manual
    /// A description to draft a rule from as soon as the rule writer opens.
    var ruleWriterSeed: String?
    /// Show review threads under their lines in the editor.
    var inlineThreads = true
    @ObservationIgnored var connectorCache: (key: String, value: [StepConnector])?
    /// Files tab shows only files that hold steps of the active path.
    var pathFilesOnly = false

    /// Whether the open file is part of the review being shown (diff controls apply only then).
    var documentInReview: Bool {
        guard let r = review, let d = document else { return false }
        return sidebarTab == .changes || r.files.contains { $0.newPath == d.path || $0.oldPath == d.path }
    }
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
    var diffMode: DiffMode = DiffMode(rawValue: UserDefaults.standard.string(forKey: "editor.diffMode") ?? "") ?? .inline {
        didSet { UserDefaults.standard.set(diffMode.rawValue, forKey: "editor.diffMode") }
    }
    var reviewSide: ReviewSide { diffMode == .before ? .before : .after }
    /// The old side of the selected file, for the split view's left pane.
    var splitDocument: SourceDocument?
    var selectedHunkID: String?

    var jobs: [ClaudeJob] = []
    @ObservationIgnored var jobTasks: [UUID: Task<Void, Never>] = [:]
    /// Bumped to focus the Claude pane's question field.
    var askFocus = 0
    var showInspector = true

    let docs: DocumentCache
    /// rust-analyzer; other languages' servers are in `servers`.
    let ra: LanguageServer
    let sourceKit: LanguageServer
    var servers: [LanguageServer] { [ra, sourceKit] }
    func server(for path: String) -> LanguageServer? { servers.first { $0.spec.handles(path) } }
    /// The server for the file on screen, or rust-analyzer when the file has none.
    var activeServer: LanguageServer { document.flatMap { server(for: $0.path) } ?? ra }
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
        ra = LanguageServer(root: self.root, spec: .rust)
        sourceKit = LanguageServer(root: self.root, spec: .swift)
        scip = SCIPService(root: self.root)
        clippy = ClippyService(root: self.root)
        intel = IntelHub(root: self.root, ra: ra, servers: [ra, sourceKit], scip: scip, docs: docs)
        traces = TraceStore(root: self.root)
        bookmarks = BookmarkStore(root: self.root)
        github = GitHubService(root: self.root)
        scm = SCMService(root: self.root)
        loadJobs()
        let store = Store.shared(for: self.root)
        Task { await store.prune(days: Prefs.cacheDays) }
        grammarObserver = NotificationCenter.default.addObserver(forName: .grammarsChanged, object: nil, queue: .main) { [weak self] _ in
            MainActor.assumeIsolated { self?.reloadCurrentDocument() }
        }
    }

    @ObservationIgnored private var grammarObserver: NSObjectProtocol?

    /// Re-parses open documents, e.g. after grammars change.
    func reloadCurrentDocument(keepPosition: Bool = false) {
        docs.invalidate()
        guard let d = document, d.isWorkingCopy, let fresh = docs.document(d.path) else { return }
        document = fresh
        server(for: fresh.path)?.didOpen(path: fresh.path, text: fresh.text, language: fresh.language)
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
        if isRust && Prefs.autoStartServers { ra.start() }
        scip.loadCached(sourceFiles: allFiles)
        startWatching()
        Task { await refreshWorkingReview() }
        if let readme = ["README.md", "src/main.rs", "src/lib.rs"].first(where: { allFileSet.contains($0) }) {
            open(CodeLocation(path: readme, range: SourceRange(line: 0)), record: false)
        }
    }

    /// Stops everything this workspace started, so nothing keeps it alive or writes after it closes.
    func shutdown() {
        traces.writeNow()
        for t in jobTasks.values { t.cancel() }
        jobTasks = [:]
        contextTask?.cancel()
        refreshTask?.cancel()
        for s in servers { s.stop() }
        for r in pinnedReviews { r.stopHeadIntel() }
        clippy.cancel(); scip.cancel(); watcher?.stop()
    }

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
        for s in servers { s.filesChanged(paths, except: document?.isWorkingCopy == true ? document?.path : nil) }
        if let d = document, d.isWorkingCopy, paths.contains(d.path) { reloadCurrentDocument(keepPosition: true) }
        refreshTask?.cancel()
        refreshTask = Task {
            try? await Task.sleep(for: .seconds(Prefs.refreshDelay))
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
            attachSemantics(r)
            workingReview = r
            await r.load()
        }
    }

    func closeReview(_ key: String) {
        pinnedReviews.first { $0.target.key == key }?.stopHeadIntel()
        pinnedReviews.removeAll { $0.target.key == key }
        if activeReviewKey == key { activateReview(nil) }
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

    func showWorkingReview() { activateReview(nil) }

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
    /// - Parameter generation: when continuing a navigation started earlier (after an await), its
    ///   generation; the move is dropped if another navigation has started since.
    func open(_ loc: CodeLocation, record: Bool = true, edge: TraceEdge? = nil, title: String? = nil, source: IntelSource = .manual,
              reason: NavReason = .manual, generation: Int? = nil) {
        if let generation { guard isCurrentNavigation(generation) else { return } } else { beginNavigation(reason) }
        if record, let cur = currentLocation, cur != loc { backStack.append(cur); forwardStack.removeAll() }
        // A location names the text it belongs to. Review-side locations open that side's document;
        // everything else (code intelligence answers, files, history) is the working copy.
        if let v = loc.version, v != .workingCopy {
            guard let r = review, v == r.headVersion || v == r.baseVersion else {
                statusMessage = "\(loc.path) is from a review that is not open"
                return
            }
            let side: ReviewSession.Side = v == r.baseVersion && v != r.headVersion ? .old : .new
            if let d = r.cachedDocument(loc.path, side: side) {
                if document !== d { document = d }
            } else {
                let gen = navGeneration
                Task {
                    guard let d = await r.document(loc.path, side: side), isCurrentNavigation(gen) else { return }
                    document = d
                    selection = loc.range
                    cursor = loc.range.start
                    revealRequest += 1
                }
                return
            }
        } else if document?.path != loc.path || !(document?.isWorkingCopy ?? false) {
            guard let d = docs.document(loc.path) else { statusMessage = "Could not open \(loc.path)"; return }
            recentFiles.removeAll { $0 == loc.path }
            recentFiles.insert(loc.path, at: 0)
            if recentFiles.count > 30 { recentFiles.removeLast() }
            document = d
            openInServer(d)
        }
        selection = loc.range
        cursor = loc.range.start
        highlightRanges = []
        revealRequest += 1
        arrival = edge.map { (edge: $0, source: source) }
    }

    /// Shows a document that is not the working copy (review before/after).
    func show(_ doc: SourceDocument, line: Int, reason: NavReason = .manual, generation: Int? = nil) {
        if let generation { guard isCurrentNavigation(generation) else { return } } else { beginNavigation(reason) }
        if let cur = currentLocation, cur.path != doc.path || document?.version != doc.version { backStack.append(cur) }
        document = doc
        if doc.isWorkingCopy { openInServer(doc) }
        selection = SourceRange(line: line)
        cursor = SourcePos(line: line, col: 0)
        revealRequest += 1
    }

    func goBack() {
        guard let loc = backStack.popLast() else { return }
        if let cur = currentLocation { forwardStack.append(cur) }
        open(loc, record: false, reason: .history)
    }

    func goForward() {
        guard let loc = forwardStack.popLast() else { return }
        if let cur = currentLocation { backStack.append(cur) }
        open(loc, record: false, reason: .history)
    }

    // MARK: Symbol interactions

    /// Click in the editor: update the context pane for the symbol under the cursor.
    func didClick(at p: SourcePos) {
        cursor = p
        guard let d = document, let (name, range) = d.word(at: p) else { return }
        beginNavigation(.click)
        if contextPinned { return }
        if context?.name == name && context?.path == d.path && context?.pos.line == p.line { return }
        let isWorkingCopy = d.isWorkingCopy
        let target = intelTarget(d, name: name, range: range)
        let queryPos = target.pos
        let ctx = SymbolContext(name: name, path: d.path, pos: queryPos)
        ctx.hub = target.hub
        ctx.version = target.version
        context = ctx
        highlightRanges = []
        contextTask?.cancel()
        contextTask = Task {
            if isWorkingCopy, let srv = server(for: d.path), srv.status.isUsable, let hl = try? await srv.documentHighlights(path: d.path, at: range.start), !hl.isEmpty {
                if context === ctx { highlightRanges = hl }
            } else if context === ctx {
                highlightRanges = localOccurrences(of: name, in: d)
            }
            var details = await target.hub.details(path: d.path, at: queryPos, name: name)
            details.definition = details.definition.map { Self.tagged($0, target.version) }
            ctx.details = details
            guard context === ctx else { return }
            describeContainer(ctx)
            async let refs: Void = loadReferences(ctx)
            async let both: Void = loadCallersAndCallees(ctx)
            await refs
            await both
            ctx.elapsed = Date().timeIntervalSince(ctx.started)
            await loadImplementations(ctx)
            await loadMentions(ctx)
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
        let (refs, src) = await (ctx.hub ?? intel).references(path: ctx.path, at: ctx.pos, name: ctx.name)
        ctx.references = refs.map { var h = $0; h.location = Self.tagged(h.location, ctx.version); return h }
        ctx.referencesSource = src
        ctx.loadingReferences = false
    }

    func loadCallersAndCallees(_ ctx: SymbolContext) async {
        ctx.loadingCallers = true
        ctx.loadingCallees = true
        let hub = ctx.hub ?? intel
        ctx.callers = await hub.callRoots(.incoming, path: ctx.path, at: ctx.pos, name: ctx.name)
        tag(ctx.callers, ctx.version, hub: hub)
        ctx.loadingCallers = false
        let callees = await hub.callRoots(.outgoing, path: ctx.path, at: ctx.pos, name: ctx.name)
        tag(callees, ctx.version, hub: hub)
        // In call order: by the first call site.
        ctx.callees = callees.sorted { ($0.callSites.first?.line ?? .max, $0.callSites.first?.range.start.col ?? 0) < ($1.callSites.first?.line ?? .max, $1.callSites.first?.range.start.col ?? 0) }
        ctx.loadingCallees = false
        ctx.calls = ctx.callDirection == .incoming ? ctx.callers : ctx.callees
    }

    private func describeContainer(_ ctx: SymbolContext) {
        guard let def = ctx.details?.definition, let doc = (ctx.hub ?? intel).docs.document(def.path),
              let item = doc.syntax.flatOutline.first(where: { $0.nameRange.start.line == def.line && $0.name == ctx.name }) else { return }
        ctx.isPublic = item.isPublic
        if let p = item.parent {
            let what = item.kind == .method ? "Method" : item.kind.label
            ctx.container = p.kind == .impl ? "\(what) of \(p.name)" : "\(what) in \(p.kind.label.lowercased()) \(p.name)"
        }
    }

    func loadMentions(_ ctx: SymbolContext) async {
        guard ctx.name.count >= 4 else { return }
        var opts = TextSearch.Options()
        opts.wholeWord = true
        opts.caseSensitive = true
        let ext = ctx.path.pathExtension
        opts.globs = ext.isEmpty ? [] : ["!*.\(ext)"]
        opts.limit = 40
        let hits = (try? await TextSearch.search(root: root, query: ctx.name, options: opts)) ?? []
        if context === ctx { ctx.mentions = hits }
    }

    func loadCalls(_ ctx: SymbolContext) async {
        ctx.loadingCalls = true
        let hub = ctx.hub ?? intel
        ctx.calls = await hub.callRoots(ctx.callDirection, path: ctx.path, at: ctx.pos, name: ctx.name)
        tag(ctx.calls, ctx.version, hub: hub)
        ctx.loadingCalls = false
    }

    func loadImplementations(_ ctx: SymbolContext) async {
        let kind = ctx.details?.kindLabel ?? ""
        guard kind == "Trait" || kind == "Struct" || kind == "Enum" || kind == "Method" || kind == "Function" || kind == "Symbol" else { return }
        ctx.loadingImpls = true
        let (hits, src) = await (ctx.hub ?? intel).implementations(path: ctx.path, at: ctx.pos, name: ctx.name)
        ctx.implementations = hits.map { var h = $0; h.location = Self.tagged(h.location, ctx.version); return h }.filter { !($0.location.path == ctx.path && $0.location.line == ctx.pos.line) }
        ctx.implementationsSource = src
        ctx.loadingImpls = false
    }

    /// Code intelligence answers about the working copy. For a symbol in another version, the
    /// position of the same identifier nearest that line in the working-copy file.
    func intelPosition(in d: SourceDocument, name: String, range: SourceRange) -> SourcePos {
        guard !d.isWorkingCopy, let wc = docs.document(d.path),
              let mapped = ClaudeTasks.nearestOccurrence(of: name, in: wc, near: range.start.line) else { return range.start }
        return mapped.start
    }

    func goToDefinition(at p: SourcePos) {
        guard let d = document, let (name, range) = d.word(at: p) else { return }
        let gen = beginNavigation(.definition)
        let target = intelTarget(d, name: name, range: range)
        Task {
            statusMessage = "Resolving \(name)…"
            let (found, src) = await target.hub.definitions(path: d.path, at: target.pos, name: name)
            let defs = found.map { Self.tagged($0, target.version) }
            guard isCurrentNavigation(gen) else { return }
            statusMessage = nil
            guard let first = defs.first else { statusMessage = "No definition found for \(name)"; return }
            open(first, edge: .definition, title: name, source: src, generation: gen)
            if defs.count > 1 { statusMessage = "\(defs.count) definitions (\(src.label)); showing first" }
        }
    }

    func followReference(_ hit: ReferenceHit) {
        open(hit.location, edge: hit.isDefinition ? .definition : .reference, title: hit.enclosing ?? context?.name, source: hit.source, reason: .reference)
    }

    func followCall(_ node: CallNode, direction: CallDirection) {
        let target = direction == .incoming ? (node.callSites.first ?? node.location) : node.location
        open(target, edge: direction == .incoming ? .caller : .callee, title: node.name, source: node.source, reason: .reference)
    }

    /// Adds the cursor location to the active code path, after the current step, and starts editing its note.
    func addCurrentToTrace() {
        guard let d = document, let p = cursor else { return }
        let item = d.syntax.enclosingItem(line: p.line)
        let title = item?.qualifiedName ?? context?.name ?? d.path.lastPathComponent
        let edge: TraceEdge = (traces.active?.steps.isEmpty ?? true) ? .start : (arrival?.edge ?? .manual)
        let step = TraceStep(title: title, location: CodeLocation(path: d.path, range: selection ?? SourceRange(line: p.line, col: p.col),
                                                                  version: d.isWorkingCopy ? nil : d.version),
                             edge: edge, source: arrival?.source ?? .manual,
                             snippet: d.lineText(p.line).trimmingCharacters(in: .whitespaces))
        traces.insert(step)
        editingStepID = step.id
    }

    func newCodePath(fromCursor: Bool) {
        inspectorPane = .paths
        traces.create(title: "Untitled path", origin: .manual)
        if fromCursor { addCurrentToTrace() }
    }

    func toggleBookmark() {
        guard let d = document, let p = cursor else { return }
        let item = d.syntax.enclosingItem(line: p.line)
        bookmarks.toggle(Bookmark(title: context?.name ?? item?.qualifiedName ?? d.path.lastPathComponent,
                                  location: CodeLocation(path: d.path, range: SourceRange(line: p.line, col: p.col),
                                                         version: d.isWorkingCopy ? nil : d.version),
                                  context: reviewContextLabel))
    }

    var reviewContextLabel: String {
        if let r = review { return r.target.label }
        return vcs.kind == .none ? "" : (vcs.description.isEmpty ? vcs.revision : vcs.description)
    }

    func playStep(_ index: Int) {
        guard let t = traces.active, index >= 0, index < t.steps.count else { return }
        let gen = beginNavigation(.step)
        traces.currentStep = index
        open(t.steps[index].location, record: true, generation: gen)
    }

    // MARK: Review

    /// Opens a review. The working copy's own target switches to the working tab; anything else is
    /// pinned beside it (reusing an existing pin for the same target).
    func startReview(_ target: ReviewTarget, focusPath: String? = nil) {
        let r: ReviewSession
        if let w = workingReview, w.target == target {
            r = w
            activateReview(nil)
        } else if let existing = pinnedReviews.first(where: { $0.target == target }) {
            r = existing
            activateReview(existing.target.key)
        } else {
            r = ReviewSession(root: root, target: target, github: github)
            attachSemantics(r)
            pinnedReviews.append(r)
            activateReview(target.key)
        }
        func selectFirst() {
            let focused = focusPath.flatMap { p in r.allHunks.first { $0.path == p } }
            if let first = focused ?? r.tierSections.first?.hunks.first ?? r.allHunks.first { selectHunk(first) }
        }
        if let p = focusPath, r.state == .ready, r.allHunks.contains(where: { $0.path == p }) { selectFirst() }
        Task {
            await r.load()
            if Prefs.headServer, r.files.contains(where: { $0.path.hasSuffix(".rs") }) { await r.startHeadIntel() }
            guard review === r else { return }
            if selectedHunkID == nil || !r.allHunks.contains(where: { $0.id == selectedHunkID }) { selectFirst() }
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
        let side = d.side == .old ? "LEFT" : "RIGHT"
        let path = side == "LEFT" ? (r.files.first { $0.oldPath == d.path }?.oldPath ?? d.path) : d.path
        commentDraft = PendingComment(path: path, line: c.line + 1, side: side, body: "")
    }

    /// Sends a working-copy document to its language server, starting the server on first use.
    func openInServer(_ d: SourceDocument) {
        guard let srv = server(for: d.path) else { return }
        if srv.status == .off, Prefs.autoStartServers { srv.start() }
        srv.didOpen(path: d.path, text: d.text, language: d.language)
    }

    /// Back to the selected hunk's change context after looking at a symbol.
    func showHunkContext() {
        guard review != nil, changeContext != nil else { return }
        contextPinned = false
        contextFocus = .hunk
        inspectorPane = .context
        showInspector = true
    }

    func selectHunk(_ h: Hunk) {
        selectedHunkID = h.id
        let gen = beginNavigation(.hunk)
        if let r = review, let g = r.listedGroup(of: h) { r.expandedGroups.insert(g.id) }
        if let r = review, r.tier(of: h).isLowSignal { r.showLowSignal = true }
        if changeContext?.hunkID != h.id { loadChangeContext(for: h) }
        guard let r = review, let f = r.file(for: h) else { return }
        Task {
            let side: ReviewSession.Side = (reviewSide == .before || f.status == .deleted) ? .old : .new
            let line = side == .old ? h.anchorOldLine : h.anchorNewLine
            if side == .new && r.afterIsWorkingCopy {
                open(CodeLocation(path: f.newPath, range: SourceRange(line: line)), record: true, generation: gen)
            } else if let doc = await r.document(side == .old ? f.oldPath : f.newPath, side: side) {
                show(doc, line: line, generation: gen)
            }
            guard isCurrentNavigation(gen) else { return }
            if diffMode == .split, f.status != .added, let old = await r.document(f.oldPath, side: .old) {
                splitDocument = old
                splitRevealLine = h.anchorOldLine
                splitRevealRequest += 1
            } else {
                splitDocument = nil
            }
        }
    }

    /// Set by the split view's old-side pane; the main editor calls it with its top visible line.
    @ObservationIgnored var splitScroller: ((Int) -> Void)?
    /// Index into the PR's threads (sorted by file and line) for N / P navigation.
    var currentThreadID: String?

    var sortedThreads: [GitHubService.ReviewThread] {
        (review?.pullRequest?.threads ?? []).sorted { a, b in
            if a.isResolved != b.isResolved { return !a.isResolved }
            return a.path == b.path ? (a.anchorLine ?? 0) < (b.anchorLine ?? 0) : a.path < b.path
        }
    }

    func moveThread(_ d: Int) {
        let ts = sortedThreads
        guard !ts.isEmpty else { return }
        let i = ts.firstIndex { $0.id == currentThreadID } ?? (d > 0 ? -1 : ts.count)
        let t = ts[(i + d + ts.count) % ts.count]
        showThread(t)
    }

    func showThread(_ t: GitHubService.ReviewThread) {
        currentThreadID = t.id
        guard let r = review, let line = t.anchorLine else { return }
        let side: ReviewSession.Side = t.side == "LEFT" ? .old : .new
        if let h = r.allHunks.first(where: { r.threads(for: $0).contains { $0.id == t.id } }) { selectedHunkID = h.id }
        let gen = beginNavigation(.thread)
        Task {
            if side == .old {
                if diffMode != .before { diffMode = .before }
                if let doc = await r.document(t.path, side: .old) { show(doc, line: line - 1, generation: gen) }
            } else if r.afterIsWorkingCopy {
                if diffMode == .before { diffMode = .inline }
                open(CodeLocation(path: t.path, range: SourceRange(line: line - 1)), generation: gen)
            } else if let doc = await r.document(t.path, side: .new) {
                if diffMode == .before { diffMode = .inline }
                show(doc, line: line - 1, generation: gen)
            }
        }
    }

    func jump(to c: PendingComment) {
        guard let r = review else { return }
        let gen = beginNavigation(.thread)
        Task {
            if c.side == "LEFT" {
                diffMode = .before
                if let d = await r.document(c.path, side: .old) { show(d, line: c.line - 1, generation: gen) }
            } else if r.afterIsWorkingCopy {
                if diffMode == .before { diffMode = .inline }
                open(CodeLocation(path: c.path, range: SourceRange(line: c.line - 1)), generation: gen)
            } else if let d = await r.document(c.path, side: .new) {
                if diffMode == .before { diffMode = .inline }
                show(d, line: c.line - 1, generation: gen)
            }
        }
    }

    func resolveCurrentThread() {
        guard let id = currentThreadID, let r = review, let t = r.pullRequest?.threads.first(where: { $0.id == id }) else { return }
        Task {
            do { try await github.setResolved(threadId: id, !t.isResolved) } catch { statusMessage = error.localizedDescription }
            await r.refreshPullRequest()
        }
    }

    var splitRevealLine = 0
    var splitRevealRequest = 0

    /// Old-file line corresponding to a new-file line, through the review's hunks; used to keep the
    /// split view's panes aligned while scrolling.
    func oldLine(forNew line: Int, path: String) -> Int {
        guard let f = review?.files.first(where: { $0.newPath == path }) else { return line }
        var delta = 0
        for h in f.hunks {
            if line < h.newStart - 1 { break }
            if line < h.newStart - 1 + h.newCount {
                // Inside a hunk: use the nearest context line's old number.
                if let l = h.lines.last(where: { ($0.newLine ?? Int.max) <= line && $0.oldLine != nil }), let o = l.oldLine {
                    return o + (l.newLine.map { line - $0 } ?? 0)
                }
                return h.oldStart - 1
            }
            delta = (h.oldStart + h.oldCount) - (h.newStart + h.newCount)
        }
        return max(0, line + delta)
    }

    func setDiffMode(_ mode: DiffMode) {
        let sideChanged = (mode == .before) != (diffMode == .before)
        diffMode = mode
        if sideChanged || mode == .split, let id = selectedHunkID, let h = review?.allHunks.first(where: { $0.id == id }) { selectHunk(h) }
    }

    func setReviewSide(_ side: ReviewSide) {
        if side == .before { diffMode = .before } else if diffMode == .before { diffMode = .inline }
        if let id = selectedHunkID, let h = review?.allHunks.first(where: { $0.id == id }) { selectHunk(h) }
    }

    /// Show the other side's lines inline (removed lines in the After view, added lines in Before).
    var inlineDiff: Bool { diffMode == .inline }

    /// Lines from the other side of the diff to show inline, keyed by the real line they precede.
    func phantomLines(for doc: SourceDocument) -> [Int: [PhantomLine]] {
        guard inlineDiff, let r = review,
              let f = r.files.first(where: { $0.newPath == doc.path || $0.oldPath == doc.path }) else { return [:] }
        let isOld = doc.side == .old
        if f.status == (isOld ? .deleted : .added) { return [:] }
        let other = r.cachedDocument(isOld ? f.newPath : f.oldPath, side: isOld ? .new : .old)
        // The editor asks on every update; the answer only changes with the documents and hunks.
        let key = "\(doc.id)|\(other.map { "\($0.id)" } ?? "-")|\(f.hunks.map(\.id).joined(separator: ","))"
        if let c = phantomCache, c.key == key { return c.value }
        let value = computePhantomLines(f, isOld: isOld, other: other)
        phantomCache = (key, value)
        return value
    }

    private func computePhantomLines(_ f: FileDiff, isOld: Bool, other: SourceDocument?) -> [Int: [PhantomLine]] {
        let phantomKind: DiffLineKind = isOld ? .added : .removed
        var out: [Int: [PhantomLine]] = [:]
        func phantom(_ l: DiffLine) -> PhantomLine {
            let otherLine = (isOld ? l.newLine : l.oldLine) ?? 0
            var tokens: [Token] = []
            if let other, otherLine < other.lines.lineCount {
                let range = other.lines.lineRange(otherLine)
                let all = other.syntax.tokens
                // Tokens are sorted by start: find the first starting at or after the line, then step
                // back over earlier tokens that may span into it (multi-line strings and comments).
                var lo = 0, hi = all.count
                while lo < hi {
                    let mid = (lo + hi) / 2
                    if all[mid].range.location < range.location { lo = mid + 1 } else { hi = mid }
                }
                var i = lo
                while i > 0, lo - i < 64 { i -= 1 }
                while i < all.count, all[i].range.location < NSMaxRange(range) {
                    let t = all[i]
                    i += 1
                    guard NSMaxRange(t.range) > range.location else { continue }
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

    /// Embedded views to show under lines of this document: review threads, your pending comments,
    /// and the comment composer. Each is (id, zero-based line it follows).
    func inlineBlocks(for doc: SourceDocument) -> [(id: String, afterLine: Int)] {
        guard let r = review, r.pullRequest != nil || commentDraft != nil else { return [] }
        let side = doc.side == .old ? "LEFT" : "RIGHT"
        guard inlineThreads else {
            if let d = commentDraft, d.path == doc.path, d.side == side { return [("draft", d.line - 1)] }
            return []
        }
        var out: [(String, Int)] = []
        for t in r.pullRequest?.threads ?? [] where t.path == doc.path && t.side == side {
            if let l = t.anchorLine { out.append(("thread:" + t.id, l - 1)) }
        }
        for c in r.pendingForCurrentPR where c.path == doc.path && c.side == side { out.append(("pending:" + c.id.uuidString, c.line - 1)) }
        if let d = commentDraft, d.path == doc.path, d.side == side { out.append(("draft", d.line - 1)) }
        // On one line: existing threads, then your pending comments, then the composer.
        func rank(_ id: String) -> Int { id.hasPrefix("thread:") ? 0 : id.hasPrefix("pending:") ? 1 : 2 }
        return out.sorted { $0.1 == $1.1 ? (rank($0.0), $0.0) < (rank($1.0), $1.0) : $0.1 < $1.1 }
    }

    /// Lines carrying review threads (true when unresolved) or pending comments, for the shown side.
    func commentLines(for doc: SourceDocument) -> [Int: Bool] {
        guard let r = review else { return [:] }
        let side = doc.side == .old ? "LEFT" : "RIGHT"
        var out: [Int: Bool] = [:]
        for t in r.pullRequest?.threads ?? [] where t.path == doc.path && t.side == side {
            if let l = t.anchorLine { out[l - 1] = (out[l - 1] ?? false) || !t.isResolved }
        }
        for c in r.pendingForCurrentPR where c.path == doc.path && c.side == side { out[c.line - 1] = true }
        return out
    }

    /// Per-line diff markers for the document currently shown, when it belongs to the review.
    func diffMarkers(for doc: SourceDocument) -> [Int: DiffLineKind] {
        guard let r = review, let f = r.files.first(where: { $0.newPath == doc.path || $0.oldPath == doc.path }) else { return [:] }
        let isOld = doc.side == .old
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

    /// Opens a `path:line` reference from Claude's prose.
    func openCitation(_ s: String) {
        let parts = s.split(separator: ":")
        guard let path = parts.first else { return }
        let line = parts.count > 1 ? (Int(parts[1]) ?? 1) - 1 : 0
        var p = String(path)
        if !allFileSet.contains(p), let match = allFiles.first(where: { $0.hasSuffix("/" + p) }) { p = match }
        // Claude reads the head of a review that is not the working copy, so its citations do too.
        let version = review.flatMap { $0.afterIsWorkingCopy ? nil : $0.headVersion }
        let inReview = review?.files.contains { $0.newPath == p } ?? false
        open(CodeLocation(path: p, range: SourceRange(line: max(0, line)), version: inReview ? version : nil),
             edge: .manual, source: .claude, reason: .citation)
    }
}
