import Foundation
import Observation

enum ReviewTarget: Codable, Hashable, Sendable {
    /// jj revsets; `to == "@"` means the working copy on disk.
    case jj(from: String, to: String)
    /// git refs; `head == nil` means the working tree on disk.
    case git(base: String, head: String?)
    case githubPR(Int)

    var label: String {
        switch self {
        case .jj(let f, let t): f == "@-" && t == "@" ? "Working copy (@)" : "\(f) → \(t)"
        case .git(let b, let h): h == nil ? "\(b) → working tree" : "\(b)…\(h!)"
        case .githubPR(let n): "PR #\(n)"
        }
    }

    var key: String {
        switch self {
        case .jj(let f, let t): "jj:\(f):\(t)"
        case .git(let b, let h): "git:\(b):\(h ?? "WT")"
        case .githubPR(let n): "pr:\(n)"
        }
    }
}

struct LLMTriage: Codable, Sendable, Equatable {
    /// `skipped`: sent to the quick pass but left out of its reply. Cached so it is not resent; the rules decide.
    enum Pass: String, Codable, Sendable { case quick, deep, skipped }
    var tier: ChangeTier
    var reason: String
    var summary: String?
    /// Nil for results saved before passes were distinguished; treated as deep.
    var pass: Pass?
    var isQuick: Bool { pass == .quick }
    var isSkipped: Bool { pass == .skipped }
}

@MainActor @Observable
final class ReviewSession {
    enum State: Equatable { case idle, loading(String), ready, failed(String) }

    let root: URL
    let target: ReviewTarget
    var state: State = .idle
    var title: String = ""
    var body: String = ""
    var files: [FileDiff] = [] {
        didSet {
            var idx: [String: Int] = [:]
            for (i, f) in files.enumerated() { for h in f.hunks { idx[h.id] = i } }
            fileIndex = idx
            layoutCache = nil
        }
    }
    /// Hunk id to index in `files`.
    @ObservationIgnored private var fileIndex: [String: Int] = [:]
    var analyses: [String: HunkAnalysis] = [:] { didSet { layoutCache = nil } }
    var llm: [String: LLMTriage] = [:] { didSet { layoutCache = nil } }
    var overview: String?
    var reviewOrder: [String] = [] {
        didSet {
            orderRank = Dictionary(reviewOrder.enumerated().map { ($1, $0) }, uniquingKeysWith: { a, _ in a })
            layoutCache = nil
        }
    }
    @ObservationIgnored private var orderRank: [String: Int] = [:]
    var triageState: String?
    var triaging = false
    var overviewIsStale = false
    /// Short jj change id of the reviewed revision, when it is one.
    var changeID: String?

    var addedCount: Int { files.reduce(0) { $0 + $1.addedCount } }
    var removedCount: Int { files.reduce(0) { $0 + $1.removedCount } }

    /// Short name for menus: the PR number, the change id, or the range.
    var shortLabel: String {
        switch target {
        case .githubPR(let n): "PR #" + String(n)
        case .jj: tracksWorkingCopy ? "Working copy" : (changeID ?? target.label)
        case .git(_, let h): tracksWorkingCopy ? "Working copy" : (h.map { String($0.prefix(8)) } ?? "uncommitted")
        }
    }

    func markViewed(_ hs: [Hunk]) {
        for h in hs { viewed.insert(h.contentKey) }
        save()
    }

    /// One line describing a hunk: Claude's summary when there is one, else the rule reasons.
    func summary(of h: Hunk) -> String {
        if let s = triage(of: h)?.summary, !s.isEmpty { return s }
        return reasons(of: h).joined(separator: " · ")
    }

    /// `file.rs:123`, the hunk's first changed line in the version it is reviewed in.
    func location(of h: Hunk) -> String {
        guard let f = file(for: h) else { return h.path.lastPathComponent }
        let line = f.status == .deleted ? h.anchorOldLine : h.anchorNewLine
        return f.path.lastPathComponent + ":" + String(line + 1)
    }
    /// Problems in the review rule files, shown above the change list.
    var ruleErrors: [String] { ReviewRules.shared.rules(for: root).errors }
    var lastLoaded: Date?
    private var loading = false
    private var reloadPending = false
    var viewed: Set<String> = []
    var notes: [String: String] = [:]
    var pullRequest: GitHubService.PullRequestDetails?
    var pendingComments: [PendingComment] = []
    var githubError: String?
    let github: GitHubService?
    enum ListMode: String, CaseIterable, Identifiable { case importance = "Importance", files = "Files"; var id: String { rawValue } }
    var listMode: ListMode = ListMode(rawValue: UserDefaults.standard.string(forKey: "review.listMode") ?? "") ?? .importance {
        didSet { UserDefaults.standard.set(listMode.rawValue, forKey: "review.listMode") }
    }
    /// Commits in the review's range, oldest first (empty for a single commit).
    var rangeCommits: [RangeCommit] = []
    /// One commit of the range being shown on its own, or nil for the whole range.
    var selectedCommit: String?

    /// The head's own rust-analyzer, when started.
    @ObservationIgnored var headIntel: HeadIntel? { didSet { headIntelVersion += 1 } }
    var headIntelVersion = 0

    /// The open pull request for a local review's bookmark, when there is one.
    var linkedPR: Int?
    var linkedBookmark: String?
    var linkedPRHead: String?
    var linkedInSync: Bool?
    var groups: [HunkGroup] = [] { didSet { layoutCache = nil } }
    var claudeGroups: [HunkGroup] = [] { didSet { layoutCache = nil } }
    /// Related hunks shown together inside the importance list.
    var groupRelated = UserDefaults.standard.object(forKey: "review.groupRelated") as? Bool ?? true {
        didSet { UserDefaults.standard.set(groupRelated, forKey: "review.groupRelated"); layoutCache = nil }
    }
    /// Groups opened in the list; the one holding the selected hunk opens on its own.
    var expandedGroups: Set<String> = []
    /// The low-signal box is open; it opens on its own when navigation reaches a hunk inside it.
    var showLowSignal = false
    @ObservationIgnored var layoutCache: [TierSection]?

    /// The resolved review identity that user state is stored under (see `resolveIdentity`).
    @ObservationIgnored var identity: String?
    @ObservationIgnored var hydratedIdentity: String?
    @ObservationIgnored var mirror = PersistedMirror()
    @ObservationIgnored var writeChain: Task<Void, Never>?
    /// The diff the overview was written for; the overview is stale once the diff differs.
    @ObservationIgnored var overviewFingerprint: String?

    /// Facts from the first pass, re-evaluated once semantic and `llm` answers arrive.
    @ObservationIgnored var facts: [String: HunkFacts] = [:]
    /// Answers semantic rule conditions; set by the workspace, which owns code intelligence.
    @ObservationIgnored var semanticProvider: (@MainActor (Hunk, FileDiff, SemanticNeeds) async -> SemanticFacts)?
    @ObservationIgnored var semantic: [String: (needs: SemanticNeeds, facts: SemanticFacts)] = [:]
    /// `llm` condition answers keyed by question and hunk content.
    var conditionAnswers: [String: Bool] = [:]
    var ruleState: String?
    var resolvingRules = false
    /// Set when a load lands while the second pass is running, so it starts over on the new diff.
    @ObservationIgnored var rulesRerun = false

    var attachments: [Attachment] = []
    var attachmentResults: [String: AttachmentResult] = [:]
    var attachmentsRunning: Set<String> = []
    @ObservationIgnored var attachmentTasks: [String: Task<Void, Never>] = [:]
    var grouping = false
    var groupState: String?

    /// Resolved revisions used to fetch file contents.
    var oldRev: String = ""
    var newRev: String?
    var vcs: VCSKind = .git
    private var prBaseOid: String?
    private var prHeadOid: String?

    private func hasCommit(_ sha: String) async -> Bool {
        (try? await Shell.run("git", ["cat-file", "-e", "\(sha)^{commit}"], cwd: root))?.ok ?? false
    }

    /// Remotes whose URL points at the pull request's repository, most likely first.
    private func remotesForRepository() async -> [String] {
        let out = (try? await Shell.output("git", ["remote", "-v"], cwd: root)) ?? ""
        let slug = (await github?.ensureRepo())?.lowercased()
        var matching: [String] = [], others: [String] = []
        for line in out.split(separator: "\n") {
            let parts = line.split(whereSeparator: { $0 == " " || $0 == "\t" }).map(String.init)
            guard parts.count >= 2, !matching.contains(parts[0]), !others.contains(parts[0]) else { continue }
            if let slug, parts[1].lowercased().contains(slug) { matching.append(parts[0]) } else { others.append(parts[0]) }
        }
        return matching + others
    }
    private var oldDocs: [String: SourceDocument] = [:]
    private var newDocs: [String: SourceDocument] = [:]

    /// True for the always-on working-copy review, which refreshes as files change.
    let tracksWorkingCopy: Bool

    init(root: URL, target: ReviewTarget, github: GitHubService? = nil, tracksWorkingCopy: Bool = false) {
        self.root = root
        self.target = target
        self.github = github
        self.tracksWorkingCopy = tracksWorkingCopy
        if restoreSnapshot() { Task { await hydrate() } }
    }

    // MARK: Persistence

    var fingerprint: String {
        String(UInt(bitPattern: files.flatMap(\.hunks).map { $0.id + $0.lines.map(\.text).joined() }.joined().stableHash), radix: 36)
    }

    // MARK: Snapshot

    /// The last loaded diff and its classification, so reopening a review shows it immediately.
    private struct Snapshot: Codable {
        /// Bumped when hunk identity or analysis shape changes; other formats are ignored.
        static let currentFormat = 3
        var format: Int?
        var identity: String?
        var diff: String
        var analyses: [String: HunkAnalysis]
        var title: String
        var body: String
        var oldRev: String
        var newRev: String?
        var prBaseOid: String?
        var prHeadOid: String?
        var vcs: String
    }

    private var snapshotURL: URL {
        AppPaths.support(for: root).appendingPathComponent("review-snapshot-\(String(UInt(bitPattern: target.key.stableHash), radix: 36)).json")
    }

    private func saveSnapshot(_ diff: String) {
        guard !tracksWorkingCopy, selectedCommit == nil, diff.utf8.count < 20_000_000 else { return }
        let snap = Snapshot(format: Snapshot.currentFormat, identity: identity, diff: diff, analyses: analyses, title: title, body: body, oldRev: oldRev, newRev: newRev,
                            prBaseOid: prBaseOid, prHeadOid: prHeadOid, vcs: vcs == .jj ? "jj" : "git")
        Task.detached { [url = snapshotURL] in
            if let d = try? JSONEncoder().encode(snap) { try? d.write(to: url, options: .atomic) }
        }
    }

    func restoreSnapshot() -> Bool {
        guard !tracksWorkingCopy, let d = try? Data(contentsOf: snapshotURL), let snap = try? JSONDecoder().decode(Snapshot.self, from: d),
              snap.format == Snapshot.currentFormat else { return false }
        let restored = DiffParser.parse(snap.diff).filter { !$0.hunks.isEmpty || $0.isBinary || $0.status != .modified }
        guard !restored.isEmpty else { return false }
        title = snap.title
        body = snap.body
        oldRev = snap.oldRev
        newRev = snap.newRev
        prBaseOid = snap.prBaseOid
        prHeadOid = snap.prHeadOid
        vcs = snap.vcs == "jj" ? .jj : .git
        files = restored
        analyses = snap.analyses
        identity = snap.identity
        recomputeGroups()
        state = .ready
        return true
    }

    // MARK: Loading

    /// Computes the diff and classifies it. The first load shows progress; later loads (live
    /// refreshes) swap results in place so the list does not flash.
    func load() async {
        guard !loading else { reloadPending = true; return }
        loading = true
        defer { loading = false }
        var first = files.isEmpty && state != .ready
        // Show the last result at once and refresh behind it.
        if first, restoreSnapshot() { first = false }
        if first { state = .loading("Computing diff") }
        do {
            var diffText = try await fetchDiff()
            identity = await resolveIdentity()
            await loadRangeCommits()
            if let c = selectedCommit { diffText = try await commitDiff(c) }
            let newFiles = DiffParser.parse(diffText).filter { !$0.hunks.isEmpty || $0.isBinary || $0.status != .modified }
            oldDocs = [:]
            newDocs = [:]
            if case .githubPR(let n) = target, pullRequest == nil { Task { await refreshPullRequest(n) } }
            if first { state = .loading("Classifying \(newFiles.count) files") }
            var newAnalyses: [String: HunkAnalysis] = [:]
            var newFacts: [String: HunkFacts] = [:]
            let started = Date()
            let source = DocSource(root: root, vcs: vcs, oldRev: oldRev, newRev: newRev)
            // Fetch, parse and classify files in parallel; each file costs one or two VCS reads and parses.
            let results = await withTaskGroup(of: FileResult.self) { group in
                var out: [FileResult] = []
                var pending = newFiles[...]
                func add(_ f: FileDiff) {
                    group.addTask { await Self.analyzeFile(f, source: source) }
                }
                for _ in 0..<min(10, pending.count) { add(pending.removeFirst()) }
                for await r in group {
                    out.append(r)
                    if first { state = .loading("Classifying \(out.count)/\(newFiles.count) files") }
                    if let f = pending.first { pending.removeFirst(); add(f) }
                }
                return out
            }
            for r in results {
                if let d = r.oldDoc { oldDocs[d.path] = d }
                if let d = r.newDoc { newDocs[d.path] = d }
                for (id, a, f) in r.hunks { newAnalyses[id] = a; newFacts[id] = f }
            }
            // A PR whose commits are not local reads contents from GitHub, one file at a time.
            for f in newFiles where newFacts[f.hunks.first?.id ?? ""] == nil && !f.hunks.isEmpty {
                let oldDoc = f.status == .added ? nil : await document(f.oldPath, side: .old)
                let newDoc = f.status == .deleted ? nil : await document(f.newPath, side: .new)
                for h in f.hunks {
                    let r = ChangeClassifier.analyze(file: f, hunk: h, oldDoc: oldDoc, newDoc: newDoc, root: root)
                    newAnalyses[h.id] = r.analysis
                    newFacts[h.id] = r.facts
                }
            }
            Log.debug(String(format: "review: classified %d files in %.2fs", newFiles.count, Date().timeIntervalSince(started)))
            files = newFiles
            facts = newFacts
            semantic = [:]
            analyses = newAnalyses
            recomputeGroups()
            // Viewed marks and triage are keyed by hunk content, so entries for hunks that no longer
            // exist simply stop matching. The overview describes the whole change; flag it once stale.
            await hydrate()
            overviewIsStale = overview != nil && overviewFingerprint != nil && overviewFingerprint != fingerprint
            lastLoaded = Date()
            state = .ready
            save()
            saveSnapshot(diffText)
            if Self.autoClassify { Task { await quickClassify() } }
            Task { await resolvePendingRules() }
            if linkedPR == nil { Task { await linkPullRequest() } } else { Task { await checkLinkedHead() } }
        } catch {
            state = .failed(error.localizedDescription)
        }
        if reloadPending {
            reloadPending = false
            loading = false
            await load()
        }
    }


    private func fetchDiff() async throws -> String {
        let fm = FileManager.default
        vcs = fm.fileExists(atPath: root.appendingPathComponent(".jj").path) ? .jj : .git
        switch target {
        case .jj(let from, let to):
            vcs = .jj
            // Record commit ids, not revsets: `@-` names a different commit after the next `jj new`,
            // and versions recorded on locations must keep meaning the same text.
            func commit(_ rev: String) async -> String {
                let id = try? await Shell.output("jj", ["log", "--no-graph", "--ignore-working-copy", "-r", rev, "-T", "commit_id"], cwd: root)
                return id?.trimmingCharacters(in: .whitespacesAndNewlines).nilIfEmpty ?? rev
            }
            oldRev = await commit(from)
            newRev = to == "@" ? nil : await commit(to)
            let desc = try? await Shell.output("jj", ["log", "--no-graph", "-r", to, "-T", "description"], cwd: root)
            let lines = (desc ?? "").split(separator: "\n", omittingEmptySubsequences: false)
            title = lines.first.map(String.init) ?? target.label
            if title.isEmpty { title = "(no description)" }
            body = lines.dropFirst().joined(separator: "\n").trimmingCharacters(in: .whitespacesAndNewlines)
            changeID = (try? await Shell.output("jj", ["log", "--no-graph", "-r", to, "-T", "change_id.short(8)"], cwd: root))?
                .trimmingCharacters(in: .whitespacesAndNewlines)
            return try await Shell.output("jj", ["diff", "--git", "--context", "3"] + Self.jjWhitespace + ["--from", from, "--to", to], cwd: root)
        case .git(let base, let head):
            vcs = .git
            func commit(_ rev: String) async -> String {
                let id = try? await Shell.output("git", ["rev-parse", rev], cwd: root)
                return id?.trimmingCharacters(in: .whitespacesAndNewlines).nilIfEmpty ?? rev
            }
            oldRev = await commit(base)
            newRev = head == nil ? nil : await commit(head!)
            title = target.label
            if let head { return try await Shell.output("git", ["diff", "--no-color", "--no-ext-diff"] + Self.gitWhitespace + [base, head], cwd: root) }
            return try await Shell.output("git", ["diff", "--no-color", "--no-ext-diff"] + Self.gitWhitespace + [base], cwd: root)
        case .githubPR(let n):
            vcs = .git
            if files.isEmpty { state = .loading("Fetching PR #\(n)") }
            guard await github?.ensureRepo() != nil else {
                throw ClaudeError(message: "\(root.lastPathComponent) has no GitHub remote, so it has no pull request #\(n).")
            }
            let json = try await Shell.output("gh", ["pr", "view", "\(n)", "--json", "title,body,baseRefOid,headRefOid,url,author"], cwd: root)
            guard let obj = try JSONSerialization.jsonObject(with: Data(json.utf8)) as? [String: Any],
                  let base = obj["baseRefOid"] as? String, let head = obj["headRefOid"] as? String else {
                throw ClaudeError(message: "Unexpected gh output")
            }
            title = "#\(n) \(obj["title"] as? String ?? "")"
            body = obj["body"] as? String ?? ""
            prBaseOid = base
            prHeadOid = head
            if !(await hasCommit(head)) {
                if files.isEmpty { state = .loading("Fetching PR commits") }
                for remote in await remotesForRepository() {
                    _ = try? await Shell.run("git", ["fetch", "--quiet", "--no-tags", remote, "pull/\(n)/head"], cwd: root)
                    if await hasCommit(head) {
                        if !(await hasCommit(base)) { _ = try? await Shell.run("git", ["fetch", "--quiet", "--no-tags", remote, base], cwd: root) }
                        break
                    }
                }
            }
            guard await hasCommit(head) else {
                // Contents come from the GitHub API instead (see `document(_:side:)`).
                oldRev = ""; newRev = ""
                return try await Shell.output("gh", ["pr", "diff", "\(n)"], cwd: root)
            }
            let mb = (try? await Shell.output("git", ["merge-base", base, head], cwd: root))?.trimmingCharacters(in: .whitespacesAndNewlines)
            oldRev = mb ?? base
            newRev = head
            return try await Shell.output("git", ["diff", "--no-color", "--no-ext-diff"] + Self.gitWhitespace + [oldRev, head], cwd: root)
        }
    }

    /// Diff flags for the whitespace preference. A pull request whose commits cannot be fetched uses
    /// GitHub's diff, which always includes whitespace changes.
    static var jjWhitespace: [String] { Prefs.ignoreWhitespace ? ["--ignore-all-space"] : [] }
    static var gitWhitespace: [String] { Prefs.ignoreWhitespace ? ["-w"] : [] }

    enum Side { case old, new }

    /// Where file contents for each side come from, captured for background loading.
    struct DocSource: Sendable {
        var root: URL
        var vcs: VCSKind
        var oldRev: String
        var newRev: String?

        func text(_ path: String, old: Bool) async -> String? {
            let rev: String? = old ? oldRev : newRev
            if !old && rev == nil { return try? String(contentsOf: root.appendingPathComponent(path), encoding: .utf8) }
            guard let rev, !rev.isEmpty else { return nil }
            if vcs == .jj {
                if let t = try? await Shell.output("jj", ["file", "show", "--ignore-working-copy", "-r", rev, "--", "root-file:\"\(path)\""], cwd: root) { return t }
                return try? await Shell.output("jj", ["file", "show", "--ignore-working-copy", "-r", rev, path], cwd: root)
            }
            return try? await Shell.output("git", ["show", "\(rev):\(path)"], cwd: root)
        }
    }

    struct FileResult: Sendable {
        var oldDoc: SourceDocument?
        var newDoc: SourceDocument?
        var hunks: [(String, HunkAnalysis, HunkFacts)]
    }

    nonisolated static func analyzeFile(_ f: FileDiff, source: DocSource) async -> FileResult {
        async let oldText = f.status == .added ? nil : source.text(f.oldPath, old: true)
        async let newText = f.status == .deleted ? nil : source.text(f.newPath, old: false)
        let ot = await oldText, nt = await newText
        // Missing contents (a PR not fetched locally) fall back to the main-actor path.
        if (f.status != .added && ot == nil) || (f.status != .deleted && nt == nil) { return FileResult(hunks: []) }
        let oldDoc = ot.map { SourceDocument(path: f.oldPath, text: $0, version: .revision(source.oldRev), side: .old) }
        let newDoc = nt.map { SourceDocument(path: f.newPath, text: $0, version: source.newRev.map { .revision($0) } ?? .workingCopy, side: .new) }
        let hunks = f.hunks.map { h in
            let r = ChangeClassifier.analyze(file: f, hunk: h, oldDoc: oldDoc, newDoc: newDoc, root: source.root)
            return (h.id, r.analysis, r.facts)
        }
        return FileResult(oldDoc: oldDoc, newDoc: newDoc, hunks: hunks)
    }

    func document(_ path: String, side: Side) async -> SourceDocument? {
        if side == .old, let d = oldDocs[path] { return d }
        if side == .new, let d = newDocs[path] { return d }
        let rev: String? = side == .old ? oldRev : newRev
        var text: String?
        if side == .new && rev == nil {
            text = try? String(contentsOf: root.appendingPathComponent(path), encoding: .utf8)
        } else if let rev, !rev.isEmpty {
            if vcs == .jj {
                text = try? await Shell.output("jj", ["file", "show", "-r", rev, "--", "root-file:\"\(path)\""], cwd: root)
                if text == nil { text = try? await Shell.output("jj", ["file", "show", "-r", rev, path], cwd: root) }
            } else {
                text = try? await Shell.output("git", ["show", "\(rev):\(path)"], cwd: root)
            }
        }
        if text == nil, case .githubPR = target, let repo = await github?.ensureRepo(),
           let ref = side == .old ? prBaseOid : prHeadOid {
            // PR commits are not available locally; read the file from GitHub at the PR's base or head.
            let encoded = path.split(separator: "/").map { $0.addingPercentEncoding(withAllowedCharacters: .urlPathAllowed) ?? String($0) }.joined(separator: "/")
            text = try? await Shell.output("gh", ["api", "-H", "Accept: application/vnd.github.raw", "repos/\(repo)/contents/\(encoded)?ref=\(ref)"], cwd: root)
        }
        guard let text else { return nil }
        let version: CodeVersion = side == .old ? baseVersion : headVersion
        let doc = SourceDocument(path: path, text: text, version: version, side: side == .old ? .old : .new)
        if side == .old { oldDocs[path] = doc } else { newDocs[path] = doc }
        return doc
    }

    /// A side's document if it was already loaded (classification loads both sides of every file).
    func cachedDocument(_ path: String, side: Side) -> SourceDocument? {
        side == .old ? oldDocs[path] : newDocs[path]
    }

    /// True when the "after" side is the working copy, so the code view can use live navigation.
    var afterIsWorkingCopy: Bool { newRev == nil }
    /// The versions of the review's two sides, as recorded on documents and locations.
    var baseVersion: CodeVersion { .revision(oldRev) }
    var headVersion: CodeVersion { afterIsWorkingCopy ? .workingCopy : .revision(newRev ?? "") }

    // MARK: Derived

    /// Claude's tier when there is one, except that the cheap quick pass cannot lower a hunk the
    /// rules call critical; only deep triage, which reads the code, can.
    func tier(of h: Hunk) -> ChangeTier {
        let rule = analyses[h.id]?.tier
        guard let t = triage(of: h) else { return rule ?? .behavior }
        if t.isQuick, rule == .critical, t.tier != .critical { return .critical }
        return t.tier
    }

    func triage(of h: Hunk) -> LLMTriage? { llm[h.contentKey].flatMap { $0.isSkipped ? nil : $0 } }

    func isViewed(_ h: Hunk) -> Bool { viewed.contains(h.contentKey) }

    func reasons(of h: Hunk) -> [String] {
        if let l = triage(of: h) { return [l.reason] }
        return analyses[h.id]?.reasons ?? []
    }

    var allHunks: [Hunk] { files.flatMap(\.hunks) }

    func hunks(in tier: ChangeTier) -> [Hunk] {
        let hs = allHunks.filter { self.tier(of: $0) == tier }
        guard !orderRank.isEmpty else { return hs }
        return hs.sorted { (orderRank[$0.contentKey] ?? Int.max) < (orderRank[$1.contentKey] ?? Int.max) }
    }

    func fileTier(_ f: FileDiff) -> ChangeTier { f.hunks.map(tier(of:)).min() ?? .mechanical }

    var progress: (viewed: Int, total: Int) {
        let important = allHunks.filter { !tier(of: $0).isLowSignal }
        return (important.filter { isViewed($0) }.count, important.count)
    }

    func toggleViewed(_ id: String) {
        guard let h = allHunks.first(where: { $0.id == id }) else { return }
        toggleViewed(h)
    }

    func toggleViewed(_ h: Hunk) {
        let k = h.contentKey
        if viewed.contains(k) { viewed.remove(k) } else { viewed.insert(k) }
        save()
    }

    func file(for hunk: Hunk) -> FileDiff? { fileIndex[hunk.id].flatMap { files[safe: $0] } }

    // MARK: Check out

    struct CheckoutOption: Identifiable, Hashable {
        var id: String { label }
        var label: String
        var detail: String
        var steps: [[String]]
    }

    /// Ways to make this review's "after" side the working copy, as command sequences.
    func checkoutOptions(repoVCS: VCSKind) async -> [CheckoutOption] {
        switch target {
        case .jj(_, let to):
            return [
                CheckoutOption(label: "New change on top (jj new \(to))", detail: "Leaves \(to) untouched; edits go into a new change above it.",
                               steps: [["jj", "new", to]]),
                CheckoutOption(label: "Edit it directly (jj edit \(to))", detail: "Edits amend \(to) itself; descendants are rebased automatically.",
                               steps: [["jj", "edit", to]]),
            ]
        case .git(_, let head):
            guard let head else { return [] }
            if repoVCS == .jj { return [CheckoutOption(label: "New change on top (jj new \(head))", detail: "", steps: [["jj", "new", head]])] }
            return [CheckoutOption(label: "Detached checkout (git switch --detach)", detail: "Requires a clean working tree.", steps: [["git", "switch", "--detach", head]])]
        case .githubPR(let n):
            guard let head = prHeadOid else { return [] }
            if repoVCS == .jj {
                let remote = await remotesForRepository().first ?? "origin"
                return [CheckoutOption(
                    label: "New change on top of PR #\(n) (jj new)",
                    detail: "Fetches the PR head as \(remote)/pr/\(n), imports it, then starts a change on top.",
                    steps: [["git", "fetch", "--quiet", "--no-tags", remote, "+pull/\(n)/head:refs/remotes/\(remote)/pr/\(n)"],
                            ["jj", "git", "import"],
                            ["jj", "new", head]])]
            }
            return [CheckoutOption(label: "Check out PR #\(n) (gh pr checkout)", detail: "Creates or updates a local branch for the PR.", steps: [["gh", "pr", "checkout", "\(n)"]])]
        }
    }

    func runCheckout(_ option: CheckoutOption) async throws {
        for step in option.steps {
            let r = try await Shell.run(step[0], Array(step.dropFirst()), cwd: root)
            guard r.ok else { throw ShellError(command: step.joined(separator: " "), result: r) }
        }
    }

    // MARK: GitHub

    func refreshPullRequest(_ number: Int? = nil) async {
        guard let github else { return }
        let n: Int
        if let number { n = number } else if case .githubPR(let x) = target { n = x } else { return }
        do {
            let first = pullRequest == nil
            pullRequest = try await github.details(n)
            githubError = nil
        } catch {
            githubError = error.localizedDescription
        }
    }

    /// Threads anchored inside the hunk's line range on either side.
    func threads(for h: Hunk) -> [GitHubService.ReviewThread] {
        guard let pr = pullRequest, let f = file(for: h) else { return [] }
        return pr.threads.filter { t in
            guard let line = t.anchorLine else { return false }
            if t.side == "LEFT" {
                return t.path == f.oldPath && line >= h.oldStart && line < h.oldStart + max(1, h.oldCount)
            }
            return t.path == f.newPath && line >= h.newStart && line < h.newStart + max(1, h.newCount)
        }
    }

    func pending(for h: Hunk) -> [PendingComment] {
        guard let f = file(for: h) else { return [] }
        return pendingForCurrentPR.filter { c in
            c.side == "LEFT"
                ? c.path == f.oldPath && c.line >= h.oldStart && c.line < h.oldStart + max(1, h.oldCount)
                : c.path == f.newPath && c.line >= h.newStart && c.line < h.newStart + max(1, h.newCount)
        }
    }

    /// Whether GitHub will accept a comment on this line: it must fall inside a diff hunk.
    func isCommentable(path: String, line: Int, side: String) -> Bool {
        files.contains { f in
            f.hunks.contains { h in
                side == "LEFT"
                    ? f.oldPath == path && line >= h.oldStart && line < h.oldStart + max(1, h.oldCount)
                    : f.newPath == path && line >= h.newStart && line < h.newStart + max(1, h.newCount)
            }
        }
    }

    /// Drafts are stamped with the pull request and head they were written against, so they can only
    /// ever be submitted there.
    func addPending(_ c: PendingComment) {
        var c = c
        c.prNumber = c.prNumber ?? pullRequest?.number
        c.commitId = c.commitId ?? pullRequest?.headSha
        pendingComments.append(c)
        save()
    }

    /// Drafts for the pull request currently attached to this review.
    var pendingForCurrentPR: [PendingComment] {
        guard let pr = pullRequest else { return [] }
        return pendingComments.filter { $0.prNumber == nil || $0.prNumber == pr.number }
    }
    func removePending(_ id: UUID) { pendingComments.removeAll { $0.id == id }; save() }

    func submit(event: GitHubService.ReviewEvent, body: String) async throws {
        guard let github, let pr = pullRequest else { throw ClaudeError(message: "Not a GitHub pull request review") }
        let drafts = pendingForCurrentPR
        // Comments anchor to the commit they were written against; drafts from an older head are
        // still posted there, which GitHub shows as outdated rather than misplaced.
        let commit = drafts.compactMap(\.commitId).first ?? pr.headSha
        try await github.submitReview(number: pr.number, commitId: commit, event: event, body: body, comments: drafts)
        let sent = Set(drafts.map(\.id))
        pendingComments.removeAll { sent.contains($0.id) }
        save()
        await refreshPullRequest(pr.number)
    }

    // MARK: Claude triage

    // MARK: Quick classification

    static var autoClassify: Bool {
        get { Prefs.autoClassify }
        set { UserDefaults.standard.set(newValue, forKey: Prefs.Key.autoClassify) }
    }

    var classifyState: String?
    private var classifying = false

    /// Hunks worth a model's opinion: not yet classified, and not settled by the rules beyond doubt.
    var classifyCandidates: [Hunk] {
        allHunks.filter { h in
            guard llm[h.contentKey] == nil else { return false }
            return !(analyses[h.id]?.settled ?? false)
        }
    }

    /// Cheap per-hunk pass after the static rules: diff text only, no tools. Every hunk sent gets a
    /// cached result keyed by its content (the model's tier, or the rules' tier when the reply skips
    /// it), so reopening a review or refreshing the working copy only sends hunks never seen before.
    func quickClassify() async {
        guard !classifying else { return }
        classifying = true
        defer { classifying = false }
        let model = ClaudeModels.label(Claude.model(for: .classify))
        var total = 0, cost = 0.0
        while true {
            let batch = Array(classifyCandidates.prefix(Prefs.quickBatch))
            guard !batch.isEmpty else { break }
            classifyState = "Classifying \(batch.count) new hunks with \(model)…"
            var prompt = "Change: \(title)\n\nHunks:\n"
            var budget = 60_000
            var sent: [Hunk] = []
            for h in batch {
                let a = analyses[h.id]
                let body = h.lines.filter { $0.kind != .context }.map { ($0.kind == .added ? "+" : "-") + $0.text }
                let text = body.count > 40 ? (body.prefix(40) + ["… \(body.count - 40) more lines"]).joined(separator: "\n") : body.joined(separator: "\n")
                let chunk = "\n### \(h.id) file=\(h.path) in=\(a?.enclosing ?? "-") heuristic=\(a?.tier.rawValue ?? "?") (\(a?.reasons.joined(separator: "; ") ?? ""))\n\(text)\n"
                if budget - chunk.utf8.count < 0 && !sent.isEmpty { break }
                budget -= chunk.utf8.count
                prompt += chunk
                sent.append(h)
            }
            do {
                let r = try await Claude.run(prompt: prompt, system: ClaudeTasks.classifySystem, cwd: root, task: .classify,
                                             schema: ClaudeTasks.classifySchema, tools: [])
                let resp = try Claude.decode(ClaudeTasks.ClassifyResponse.self, from: r)
                let byID = Dictionary(resp.hunks.map { ($0.id, $0) }, uniquingKeysWith: { a, _ in a })
                for h in sent where llm[h.contentKey] == nil {
                    if let item = byID[h.id], let tier = ChangeTier(rawValue: item.tier) {
                        llm[h.contentKey] = LLMTriage(tier: tier, reason: item.reason, pass: .quick)
                    } else {
                        llm[h.contentKey] = LLMTriage(tier: analyses[h.id]?.tier ?? .behavior, reason: "", pass: .skipped)
                    }
                }
                total += sent.count
                cost += r.costUSD
                save()
            } catch {
                classifyState = "Quick classification failed: \(error.localizedDescription)"
                return
            }
        }
        classifyState = total == 0 ? "All hunks classified (cached)" : String(format: "Classified %d new hunks with %@ ($%.3f)", total, model, cost)
    }

    func triageWithClaude() async {
        triageState = "Asking Claude"
        triaging = true
        defer { triaging = false }
        var prompt = "Change: \(title)\n"
        if !body.isEmpty { prompt += "\nDescription:\n\(body.prefix(4000))\n" }
        prompt += "\nHunks (id, file, enclosing item, heuristic tier, diff):\n"
        var budget = 120_000
        for f in files {
            for h in f.hunks {
                let a = analyses[h.id]
                var chunk = "\n### \(h.id)  file=\(f.path)  in=\(a?.enclosing ?? "-")  heuristic=\(a?.tier.rawValue ?? "?") (\(a?.reasons.joined(separator: "; ") ?? ""))\n"
                let body = h.lines.map { ($0.kind == .added ? "+" : $0.kind == .removed ? "-" : " ") + $0.text }
                let text = body.count > 80 ? (body.prefix(60) + ["... \(body.count - 60) more lines"]).joined(separator: "\n") : body.joined(separator: "\n")
                chunk += text + "\n"
                if FileClassifier.isGenerated(f.path) { chunk = "\n### \(h.id)  file=\(f.path)  heuristic=mechanical (generated; body omitted)\n" }
                budget -= chunk.utf8.count
                if budget < 0 { prompt += "\n### \(h.id) file=\(f.path) heuristic=\(a?.tier.rawValue ?? "?") (body omitted for size)\n"; continue }
                prompt += chunk
            }
        }
        do {
            let head = try await headCheckout()
            let r = try await Claude.run(prompt: prompt, system: ClaudeTasks.triageSystem, cwd: head, task: .triage, schema: ClaudeTasks.triageSchema) { [weak self] ev in
                if case .toolUse(let name, let s) = ev {
                    Task { @MainActor in self?.triageState = "\(name) \(s)" }
                }
            }
            let resp = try Claude.decode(ClaudeTasks.TriageResponse.self, from: r)
            for item in resp.hunks {
                guard let tier = ChangeTier(rawValue: item.tier) else { continue }
                guard let h = allHunks.first(where: { $0.id == item.id }) else { continue }
                llm[h.contentKey] = LLMTriage(tier: tier, reason: item.reason, summary: item.summary, pass: .deep)
            }
            overview = resp.overview
            overviewFingerprint = fingerprint
            let byID = Dictionary(allHunks.map { ($0.id, $0.contentKey) }, uniquingKeysWith: { a, _ in a })
            reviewOrder = (resp.reviewOrder ?? []).compactMap { byID[$0] }
            overviewIsStale = false
            triageState = String(format: "Triaged by Claude ($%.2f)", r.costUSD)
            save()
        } catch {
            triageState = "Triage failed: \(error.localizedDescription)"
        }
    }
}
