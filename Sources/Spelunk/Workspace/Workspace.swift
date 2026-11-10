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
    /// Plain is the file without the review's decorations; choosing it turns `diffShown` off and
    /// leaves the stored mode alone.
    case plain = "Plain", inline = "Inline", split = "Split", after = "After", before = "Before"
    var id: String { rawValue }
    /// The modes offered in the toolbar; Before stays reachable from menus and the palette.
    static let toolbar: [DiffMode] = [.plain, .inline, .split, .after]
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
    var document: SourceDocument? {
        didSet { if let d = document, d !== oldValue, d.isWorkingCopy { reanchor(in: d) } }
    }
    var selection: SourceRange?
    var highlightRanges: [SourceRange] = []
    /// Incremented to scroll the editor to `selection`; a target inside a fold unfolds it.
    var revealRequest = 0 {
        didSet { if let d = document, let s = selection { unfold(containing: s.start.line, in: d) } }
    }
    /// Folded function ids (first lines) per document; see `foldedRanges(for:)`.
    @ObservationIgnored var folds: [String: Set<Int>] = [:]
    /// Per fold key, the changed lines last seen; a function that gains a change unfolds.
    @ObservationIgnored var foldChanged: [String: Set<Int>] = [:]
    var foldsVersion = 0
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
    /// The vim mode and pending keys for the status bar; nil when vim navigation is off.
    var vimStatus: String?
    /// The old-side line number when the caret is on an inline removed line.
    var removedLineAtCaret: Int?
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
    /// Expanded folders in the Files tab.
    var treeExpanded: Set<String> = []
    /// Set to have the Files tab reveal the open file once, whether or not it follows it.
    var revealInTreePending = false

    /// Whether the editor shows the active review's diff on the review's files. Arriving at a hunk,
    /// a thread or a comment turns it on; opening a file from Files, Search or the palette turns it
    /// off while the review follows the working copy; the toolbar's Plain choice turns it off.
    var diffShown = true

    /// Review mode: the review being shown decorates its files with removed lines inline, hunk
    /// tiers, review folds and comments. Otherwise its files read as plain code with gutter change bars.
    var reviewing: Bool { review != nil && diffShown }

    /// The review's change to `doc`'s file, when `doc` is one of the review's two versions of it.
    func reviewFile(for doc: SourceDocument) -> FileDiff? {
        guard let r = review, doc.version == (doc.side == .old ? r.baseVersion : r.headVersion) else { return nil }
        return r.files.first { (doc.side == .old ? $0.oldPath : $0.newPath) == doc.path }
    }

    /// `reviewFile(for:)` while in review mode.
    func reviewedFile(_ doc: SourceDocument) -> FileDiff? { reviewing ? reviewFile(for: doc) : nil }

    /// In review mode on one of the review's files.
    var documentInReview: Bool {
        guard reviewing, let d = document else { return false }
        return reviewFile(for: d) != nil
    }

    /// Whether the toolbar's diff picker applies: the open file is one of the active review's.
    var diffPickerApplies: Bool {
        guard let r = review, !r.files.isEmpty, let d = document else { return false }
        return reviewFile(for: d) != nil
    }
    var palette: PaletteMode? { didSet { if palette != oldValue { paletteQuery = "" } } }
    var paletteQuery = ""
    var scmSection: SCMSection = .changes
    var showSubmitReview = false
    var commentDraft: PendingComment?
    var recentFiles: [String] = []

    /// Always-on review of the current jj revision (or uncommitted git changes).
    var workingReview: ReviewSession?
    /// The last time `@` became a different change, for the notice in the Review tab.
    var workingCopyMove: WorkingCopyMove?
    /// `@`'s change id as of the last refresh.
    private(set) var workingChange: String?
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
    let lean: LanguageServer
    var servers: [LanguageServer] { [ra, sourceKit, lean] }
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
        lean = LanguageServer(root: self.root, spec: .lean)
        scip = SCIPService(root: self.root)
        clippy = ClippyService(root: self.root)
        intel = IntelHub(root: self.root, ra: ra, servers: [ra, sourceKit, lean], scip: scip, docs: docs)
        traces = TraceStore(root: self.root)
        bookmarks = BookmarkStore(root: self.root)
        github = GitHubService(root: self.root)
        scm = SCMService(root: self.root)
        loadJobs()
        let store = Store.shared(for: self.root)
        Task { await store.prune(days: Prefs.cacheDays) }
        grammarObserver = NotificationCenter.default.addObserver(forName: .grammarsChanged, object: nil, queue: .main) { [weak self] _ in
            MainActor.assumeIsolated {
                self?.docs.invalidate()
                self?.reloadCurrentDocument()
            }
        }
        diffOptionsObserver = NotificationCenter.default.addObserver(forName: .diffOptionsChanged, object: nil, queue: .main) { [weak self] _ in
            MainActor.assumeIsolated {
                guard let self else { return }
                // The working-copy review may change target (an empty `@` and its parent), so it is resolved again.
                Task { await self.refreshWorkingReview() }
                for r in self.pinnedReviews { Task { await r.load() } }
            }
        }
    }

    @ObservationIgnored private var grammarObserver: NSObjectProtocol?
    @ObservationIgnored private var diffOptionsObserver: NSObjectProtocol?

    @ObservationIgnored private var reloadGeneration = 0

    /// Reads and parses the open working-copy file again, off the main thread. When several reloads
    /// overlap, the last one asked for wins.
    func reloadCurrentDocument(keepPosition: Bool = false) {
        guard let d = document, d.isWorkingCopy else { return }
        reloadGeneration += 1
        let generation = reloadGeneration
        Task {
            guard let fresh = await docs.documents([d.path])[d.path], generation == reloadGeneration,
                  let current = document, current !== fresh, current.path == d.path, current.isWorkingCopy else { return }
            document = fresh
            server(for: fresh.path)?.didOpen(path: fresh.path, text: fresh.text, language: fresh.language)
            if !keepPosition { revealRequest += 1 }
        }
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
    /// Where history stood at the last refresh, as `historyMark` reads it.
    @ObservationIgnored private var lastHistoryMark: String?
    @ObservationIgnored private var fileListStale = false
    @ObservationIgnored private var pendingListPaths: Set<String> = []
    @ObservationIgnored private var unlistedPaths: Set<String> = []

    private func startWatching() {
        lastHistoryMark = historyMark()
        let w = FileWatcher(root: root) { [weak self] paths, historyMoved in
            Task { @MainActor in self?.filesChanged(paths, historyMoved: historyMoved) }
        }
        w.start()
        watcher = w
    }

    /// Debounced reaction to edits on disk (yours, Claude's, a checkout): refresh the open file,
    /// the working-copy review, and the change graph when it is visible.
    private func filesChanged(_ paths: [String], historyMoved: Bool = false) {
        // Spelunk's own jj commands record operations too; only an operation it has not seen refreshes.
        if paths.isEmpty && (!historyMoved || historyMark() == lastHistoryMark) { return }
        for s in servers { s.filesChanged(paths, except: document?.isWorkingCopy == true ? document?.path : nil) }
        if let d = document, d.isWorkingCopy, paths.contains(d.path) { reloadCurrentDocument(keepPosition: true) }
        // A path that is new to the file list, or a listed one that is gone, means files were added or removed.
        let fm = FileManager.default
        let candidates = paths.filter { p in
            !unlistedPaths.contains(p) && allFileSet.contains(p) != fm.fileExists(atPath: root.appendingPathComponent(p).path)
        }
        if !candidates.isEmpty { fileListStale = true; pendingListPaths.formUnion(candidates) }
        refreshTask?.cancel()
        refreshTask = Task {
            try? await Task.sleep(for: .seconds(Prefs.refreshDelay))
            guard !Task.isCancelled else { return }
            // A later change cancels only the wait. The refresh runs to completion, and a review
            // that is already loading queues one more load.
            Task { await self.refreshAfterChanges() }
        }
    }

    private func refreshAfterChanges() async {
        let historyMoved = historyMark() != lastHistoryMark
        await refreshWorkingReview()
        for r in pinnedReviews where r.follows { await r.load() }
        if historyMoved { await checkFreshness(pinnedReviews) }
        lastHistoryMark = historyMark()
        // After the review's diff, which snapshots a jj working copy, so the list includes new files.
        if fileListStale {
            fileListStale = false
            allFiles = await VCS.listFiles(root, vcs: vcs.kind)
            allFileSet = Set(allFiles)
            // Paths that exist but stay out of the list (ignored files, folders) do not trigger it again.
            let fm = FileManager.default
            unlistedPaths.formUnion(pendingListPaths.filter { !allFileSet.contains($0) && fm.fileExists(atPath: root.appendingPathComponent($0).path) })
            pendingListPaths = []
            await rebuildTreeAsync()
        }
        if sidebarTab == .scm { await scm.refresh(kind: vcs.kind) }
    }

    /// Identifies where history stands: jj's current operation, or git's HEAD and the branch it names.
    private func historyMark() -> String? {
        let fm = FileManager.default
        let heads = root.appendingPathComponent(".jj/repo/op_heads/heads")
        if let ops = try? fm.contentsOfDirectory(atPath: heads.path) { return ops.sorted().joined(separator: ",") }
        let git = root.appendingPathComponent(".git")
        guard let head = try? String(contentsOf: git.appendingPathComponent("HEAD"), encoding: .utf8) else { return nil }
        let ref = head.hasPrefix("ref: ") ? head.dropFirst(5).trimmingCharacters(in: .whitespacesAndNewlines) : nil
        let target = ref.flatMap { try? String(contentsOf: git.appendingPathComponent($0), encoding: .utf8) } ?? ""
        return head + target
    }

    /// The working copy's own changes: `@` against its parent for jj, uncommitted changes for git.
    /// An empty `@` shows its parent instead when Settings ask for it.
    private func workingTarget() async -> ReviewTarget? {
        switch vcs.kind {
        case .jj:
            if Prefs.parentWhenEmpty,
               (try? await Shell.output("jj", ["log", "--no-graph", "-r", "@", "-T", "if(empty, \"empty\", \"\")"], cwd: root))?
                .trimmingCharacters(in: .whitespacesAndNewlines) == "empty" {
                return ReviewSession.parentOfEmpty
            }
            return .jj(from: "@-", to: "@")
        case .git: return .git(base: "HEAD", head: nil)
        case .none: return nil
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
        let moved = await noteWorkingCopyMove()
        dropStaleSelection(moved: moved)
    }

    /// Records `@` becoming a different change. Returns whether it did.
    private func noteWorkingCopyMove() async -> Bool {
        guard vcs.kind == .jj, let now = await resolveRevision("@") else { return false }
        defer { workingChange = now }
        guard let previous = workingChange, previous != now else { return false }
        if workingCopyMove?.previous == now {
            workingCopyMove = nil
            return true
        }
        let parent = await resolveRevision("@-")
        workingCopyMove = WorkingCopyMove(previous: previous, current: now, previousIsParent: parent == previous, at: Date())
        return true
    }

    /// Clears a hunk selection the active following review no longer has, or all of it once `@` is
    /// a different change, along with the context and split view that belonged to it.
    private func dropStaleSelection(moved: Bool) {
        guard let r = review, r.follows, let id = selectedHunkID,
              moved || !r.allHunks.contains(where: { $0.id == id }) else { return }
        selectedHunkID = nil
        if changeContext?.hunkID == id { changeContext = nil }
        splitDocument = nil
    }

    func closeReview(_ key: String) {
        pinnedReviews.first { $0.target.key == key }?.stopHeadIntel()
        pinnedReviews.removeAll { $0.target.key == key }
        if activeReviewKey == key { activateReview(nil, showList: false) }
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

    /// Where the caret is, for history: going back returns exactly here, in this version of the file.
    var currentLocation: CodeLocation? {
        guard let d = document else { return nil }
        let range = cursor.map { SourceRange(start: $0, end: $0) } ?? selection ?? SourceRange(line: 0)
        return CodeLocation(path: d.path, range: range, version: d.isWorkingCopy ? nil : d.version)
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
            // Any open review's version opens; the active review stays as it is, and the version chip
            // names the review the file belongs to.
            let open = [review].compactMap { $0 } + [workingReview].compactMap { $0 } + pinnedReviews
            guard let r = open.first(where: { v == $0.headVersion || v == $0.baseVersion }) else {
                statusMessage = "\(loc.path) is from a review that has been closed"
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
        let loc = CodeLocation(path: d.path, range: SourceRange(start: p, end: p), version: d.isWorkingCopy ? nil : d.version)
        let step = TraceStep(title: title, location: loc, edge: edge, source: arrival?.source ?? .manual,
                             snippet: d.lineText(p.line).trimmingCharacters(in: .whitespaces), anchor: CodeAnchor.make(loc, in: d))
        traces.insert(step)
        editingStepID = step.id
    }

    /// Adds a code path from `Trace.plainText()`'s format, finding each step by its symbol.
    func importCodePath(_ text: String) {
        guard let parsed = Trace.parsePlainText(text) else {
            statusMessage = "No code path found: expected a title line, then file:symbol:note lines"
            return
        }
        let resp = ClaudeTasks.TraceResponse(title: parsed.title, summary: nil,
                                             steps: parsed.steps.map { .init(file: $0.file, symbol: $0.symbol, line: nil, note: $0.note, link: nil) })
        var t = ClaudeTasks.materialize(resp, question: "", docs: docs)
        t.origin = .manual
        t.question = nil
        t.steps = t.steps.map { var s = $0; s.edge = .manual; s.source = .manual; return s }
        traces.add(t)
        inspectorPane = .paths
        showInspector = true
        let missing = t.steps.filter { !$0.verified }.count
        statusMessage = "Imported \(t.title): \(t.steps.count) steps" + (missing > 0 ? ", \(missing) not found" : "")
    }

    func newCodePath(fromCursor: Bool) {
        inspectorPane = .paths
        traces.create(title: "Untitled path", origin: .manual)
        if fromCursor { addCurrentToTrace() }
    }

    func toggleBookmark() {
        guard let d = document, let p = cursor else { return }
        let item = d.syntax.enclosingItem(line: p.line)
        let loc = CodeLocation(path: d.path, range: SourceRange(line: p.line, col: p.col), version: d.isWorkingCopy ? nil : d.version)
        bookmarks.toggle(Bookmark(title: context?.name ?? item?.qualifiedName ?? d.path.lastPathComponent,
                                  location: loc, context: reviewContextLabel, anchor: CodeAnchor.make(loc, in: d)))
    }

    var reviewContextLabel: String {
        if let r = review { return r.target.label }
        return vcs.kind == .none ? "" : (vcs.description.isEmpty ? vcs.revision : vcs.description)
    }

    /// Puts the open code path away and returns the inspector to the context it follows.
    func closeCodePath() {
        traces.close()
        editingStepID = nil
        if inspectorPane == .paths { inspectorPane = .context }
    }

    func playStep(_ index: Int) {
        guard let t = traces.active, index >= 0, index < t.steps.count else { return }
        let gen = beginNavigation(.step)
        traces.currentStep = index
        let step = t.steps[index]
        let (loc, anchor, found) = reanchored(step.location, step.anchor)
        if loc != step.location || anchor != step.anchor { traces.updateStep(step.id) { $0.location = loc; $0.anchor = anchor } }
        if !found { statusMessage = "\(step.title) is not where it was saved; showing its last known line" }
        open(loc, record: true, generation: gen)
    }

    func openBookmark(_ b: Bookmark) {
        let (loc, anchor, found) = reanchored(b.location, b.anchor)
        if loc != b.location || anchor != b.anchor {
            bookmarks.updateAll { if $0.id == b.id { $0.location = loc; $0.anchor = anchor } }
        }
        if !found { statusMessage = "\(b.title) is not where it was saved; showing its last known line" }
        open(loc)
    }

    /// A saved working-copy location checked against its file's current text: where it is now, a
    /// refreshed anchor, and whether it was found. Locations in a commit never move.
    func reanchored(_ loc: CodeLocation, _ anchor: CodeAnchor?, in doc: SourceDocument? = nil) -> (CodeLocation, CodeAnchor?, Bool) {
        guard loc.isWorkingCopy, let doc = doc ?? docs.document(loc.path) else { return (loc, anchor, true) }
        guard let anchor else { return (loc, CodeAnchor.make(loc, in: doc), true) }
        switch anchor.resolve(line: loc.line, in: doc) {
        case .unchanged:
            return (loc, anchor.fileHash == CodeAnchor.hash(doc.text) ? anchor : CodeAnchor.make(loc, in: doc), true)
        case .moved(let l):
            let moved = loc.onLine(l)
            return (moved, CodeAnchor.make(moved, in: doc), true)
        case .lost:
            return (loc, anchor, false)
        }
    }

    /// Moves every saved step and bookmark in this file to where its code is now.
    func reanchor(in doc: SourceDocument) {
        traces.updateAllSteps { s in
            guard s.location.path == doc.path, s.location.isWorkingCopy else { return }
            let (loc, anchor, _) = reanchored(s.location, s.anchor, in: doc)
            s.location = loc
            s.anchor = anchor
        }
        bookmarks.updateAll { b in
            guard b.location.path == doc.path, b.location.isWorkingCopy else { return }
            let (loc, anchor, _) = reanchored(b.location, b.anchor, in: doc)
            b.location = loc
            b.anchor = anchor
        }
    }

    // MARK: Review

    /// Opens a review. jj revisions written relative to `@` are resolved to change ids first, so a
    /// review keeps showing the change it opened on after `@` moves; a range that ends at `@` stays
    /// following it.
    func startReview(_ target: ReviewTarget, focusPath: String? = nil) {
        if case .git(let base, let head?) = target {
            // Refs such as HEAD and HEAD~1 move with the next commit; commit ids do not.
            Task {
                func sha(_ ref: String) async -> String? {
                    (try? await Shell.output("git", ["rev-parse", "--short=12", "--verify", "--quiet", ref + "^{commit}"], cwd: root))?
                        .trimmingCharacters(in: .whitespacesAndNewlines).nilIfEmpty
                }
                guard let h = await sha(head) else { openReview(target, focusPath: focusPath); return }
                let b = await sha(base)
                let parent = await sha(h + "^")
                openReview(.git(base: b != nil && b == parent ? h + "^" : b ?? base, head: h), focusPath: focusPath)
            }
            return
        }
        guard case .jj(let from, let to) = target, vcs.kind == .jj, to != "@", from.contains("@") || to.contains("@") else {
            openReview(target, focusPath: focusPath)
            return
        }
        Task {
            guard let head = await resolveRevision(to) else { openReview(target, focusPath: focusPath); return }
            let base = await resolveRevision(from)
            let parent = await resolveRevision(head + "-")
            openReview(.jj(from: base != nil && base == parent ? head + "-" : base ?? from, to: head), focusPath: focusPath)
        }
    }

    /// A jj revision's change id, or its commit id when the change is divergent; nil unless the
    /// revset names exactly one revision.
    func resolveRevision(_ rev: String) async -> String? {
        let out = try? await Shell.output("jj", ["log", "--no-graph", "--ignore-working-copy", "-r", rev, "-T",
                                                  "if(divergent, commit_id.short(12), change_id.short(8)) ++ \"\\n\""], cwd: root)
        let lines = (out ?? "").split(separator: "\n").map { $0.trimmingCharacters(in: .whitespaces) }.filter { !$0.isEmpty }
        return lines.count == 1 ? lines[0] : nil
    }

    /// Compares fixed reviews with where their revisions stand now.
    func checkFreshness(_ reviews: [ReviewSession]) async {
        let fixed = reviews.filter { !$0.follows }
        guard !fixed.isEmpty else { return }
        let parent = vcs.kind == .jj ? await resolveRevision("@-") : nil
        for r in fixed { await r.checkFreshness(at: workingChange, parent: parent) }
    }

    /// Whether `target` is the working-copy review's change written out by id.
    private func isWorkingChange(_ target: ReviewTarget) -> Bool {
        guard case .jj(let from, let to) = target, let at = workingChange, workingReview != nil else { return false }
        return (to.hasPrefix(at) || at.hasPrefix(to)) && to.count >= 4 && from == to + "-"
    }

    /// Opens `target` as given. The working copy's own target, or its change by id, shows the
    /// working-copy review; anything else is pinned beside it (reusing an existing pin).
    private func openReview(_ target: ReviewTarget, focusPath: String?) {
        let r: ReviewSession
        if let w = workingReview, w.target == target || isWorkingChange(target) {
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
            await checkFreshness([r])
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
    /// Starts a review comment at the caret, or across `lines` (1-based). A caret on an inline removed
    /// line comments on the old side.
    func draftComment(lines: ClosedRange<Int>? = nil) {
        guard let r = review, let d = document else { return }
        guard r.pullRequest != nil else {
            statusMessage = "Comments go to a pull request, and this review has none linked"
            return
        }
        guard reviewFile(for: d) != nil else {
            statusMessage = "Comments go on files of the review, and \(d.path.lastPathComponent) is not one"
            return
        }
        // The composer shows in review mode.
        diffShown = true
        var side = d.side == .old ? "LEFT" : "RIGHT"
        let line: Int
        if let lines {
            line = lines.upperBound
        } else if let old = removedLineAtCaret {
            side = "LEFT"
            line = old
        } else if let c = cursor {
            line = c.line + 1
        } else {
            return
        }
        let path = side == "LEFT" && d.side != .old ? (r.files.first { $0.newPath == d.path }?.oldPath ?? d.path) : d.path
        var draft = PendingComment(path: path, line: line, side: side, body: "")
        if let lines, lines.lowerBound < lines.upperBound { draft.startLine = lines.lowerBound }
        commentDraft = draft
    }

    /// Sends a working-copy document to its language server, starting the server on first use.
    func openInServer(_ d: SourceDocument) {
        guard let srv = server(for: d.path) else { return }
        if srv.status == .off, Prefs.autoStartServers { srv.start(near: d.path) }
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
        guard mode != .plain else { diffShown = false; return }
        diffShown = true
        let sideChanged = (mode == .before) != (diffMode == .before)
        diffMode = mode
        if sideChanged || mode == .split, let id = selectedHunkID, let h = review?.allHunks.first(where: { $0.id == id }) { selectHunk(h) }
    }

    func setReviewSide(_ side: ReviewSide) {
        diffShown = true
        if side == .before { diffMode = .before } else if diffMode == .before { diffMode = .inline }
        if let id = selectedHunkID, let h = review?.allHunks.first(where: { $0.id == id }) { selectHunk(h) }
    }

    /// Show the other side's lines inline (removed lines in the After view, added lines in Before).
    var inlineDiff: Bool { diffMode == .inline }

    /// Lines from the other side of the diff to show inline, keyed by the real line they precede.
    func phantomLines(for doc: SourceDocument) -> [Int: [PhantomLine]] {
        guard inlineDiff, let r = review, let f = reviewedFile(doc) else { return [:] }
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
    /// Items on the other version's lines follow their inline phantom line (`otherSide`).
    func inlineBlocks(for doc: SourceDocument) -> [(id: String, afterLine: Int, otherSide: Bool)] {
        guard let r = review, r.pullRequest != nil || commentDraft != nil, let file = reviewedFile(doc) else { return [] }
        let side = doc.side == .old ? "LEFT" : "RIGHT"
        let otherPath = doc.side == .old ? file.newPath : file.oldPath
        /// Whether an item at (path, side) shows in this document, and on which version's lines.
        func placement(_ path: String, _ s: String) -> Bool? {
            if path == doc.path, s == side { return false }
            if inlineDiff, s != side, path == otherPath { return true }
            return nil
        }
        var out: [(String, Int, Bool)] = []
        if let d = commentDraft, let other = placement(d.path, d.side) { out.append(("draft", d.line - 1, other)) }
        guard inlineThreads else { return out }
        for t in r.pullRequest?.threads ?? [] {
            if let other = placement(t.path, t.side), let l = t.anchorLine { out.append(("thread:" + t.id, l - 1, other)) }
        }
        for c in r.pendingForCurrentPR {
            if let other = placement(c.path, c.side) { out.append(("pending:" + c.id.uuidString, c.line - 1, other)) }
        }
        // On one line: existing threads, then your pending comments, then the composer.
        func rank(_ id: String) -> Int { id.hasPrefix("thread:") ? 0 : id.hasPrefix("pending:") ? 1 : 2 }
        return out.sorted { ($0.1, $0.2 ? 1 : 0, rank($0.0), $0.0) < ($1.1, $1.2 ? 1 : 0, rank($1.0), $1.0) }
    }

    /// Lines carrying review threads (true when unresolved) or pending comments, for the shown side.
    func commentLines(for doc: SourceDocument) -> [Int: Bool] {
        guard let r = review, reviewedFile(doc) != nil else { return [:] }
        let side = doc.side == .old ? "LEFT" : "RIGHT"
        var out: [Int: Bool] = [:]
        for t in r.pullRequest?.threads ?? [] where t.path == doc.path && t.side == side {
            if let l = t.anchorLine { out[l - 1] = (out[l - 1] ?? false) || !t.isResolved }
        }
        for c in r.pendingForCurrentPR where c.path == doc.path && c.side == side { out[c.line - 1] = true }
        return out
    }

    /// Per-line diff markers for a document of the review, in review mode.
    func diffMarkers(for doc: SourceDocument) -> [Int: DiffLineKind] {
        guard let f = reviewedFile(doc) else { return [:] }
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

    /// Gutter change bars for a document of the review outside review mode: lines added, lines
    /// that replace removed ones, and where lines were deleted.
    func changeBars(for doc: SourceDocument) -> [Int: ChangeBar] {
        guard !reviewing, doc.side != .old, let f = reviewFile(for: doc) else { return [:] }
        var out: [Int: ChangeBar] = [:]
        let last = max(0, doc.lines.lineCount - 1)
        for h in f.hunks {
            var removed = 0
            var added: [Int] = []
            func flush(before line: Int) {
                if !added.isEmpty {
                    for n in added { out[n] = removed > 0 ? .modified : .added }
                } else if removed > 0 {
                    out[min(line, last)] = out[min(line, last)] ?? .deletedAbove
                }
                removed = 0
                added = []
            }
            for l in h.lines {
                switch l.kind {
                case .removed: removed += 1
                case .added: if let n = l.newLine { added.append(n) }
                case .context: flush(before: l.newLine ?? 0)
                }
            }
            flush(before: h.newStart - 1 + h.newCount)
        }
        return out
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

/// `@` became a different change: from `previous` to `current`.
struct WorkingCopyMove: Equatable {
    var previous: String
    var current: String
    /// `previous` is now `@-`, as after `jj new` or `jj commit`.
    var previousIsParent: Bool
    var at: Date
}
