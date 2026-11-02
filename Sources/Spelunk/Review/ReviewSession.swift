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

struct LLMTriage: Codable, Sendable {
    var tier: ChangeTier
    var reason: String
    var summary: String?
}

@MainActor @Observable
final class ReviewSession {
    enum State: Equatable { case idle, loading(String), ready, failed(String) }

    let root: URL
    let target: ReviewTarget
    var state: State = .idle
    var title: String = ""
    var body: String = ""
    var files: [FileDiff] = []
    var analyses: [String: HunkAnalysis] = [:]
    var llm: [String: LLMTriage] = [:]
    var overview: String?
    var reviewOrder: [String] = []
    var triageState: String?
    var triaging = false
    var viewed: Set<String> = []
    var notes: [String: String] = [:]
    var hideTiers: Set<ChangeTier> = [.mechanical]
    var pullRequest: GitHubService.PullRequestDetails?
    var pendingComments: [PendingComment] = []
    var githubError: String?
    let github: GitHubService?
    var groupByTier = true

    /// Resolved revisions used to fetch file contents.
    private(set) var oldRev: String = ""
    private(set) var newRev: String?
    private var vcs: VCSKind = .git
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

    init(root: URL, target: ReviewTarget, github: GitHubService? = nil) {
        self.root = root
        self.target = target
        self.github = github
        loadPersisted()
    }

    // MARK: Persistence

    private struct Persisted: Codable {
        var viewed: [String]
        var notes: [String: String]
        var llm: [String: LLMTriage]
        var overview: String?
        var reviewOrder: [String]?
        var fingerprint: String
        var pendingComments: [PendingComment]?
    }

    private var stateURL: URL {
        AppPaths.support(for: root).appendingPathComponent("review-\(String(UInt(bitPattern: target.key.stableHash), radix: 36)).json")
    }

    private var fingerprint: String {
        String(UInt(bitPattern: files.flatMap(\.hunks).map { $0.id + $0.lines.map(\.text).joined() }.joined().stableHash), radix: 36)
    }

    private func loadPersisted() {
        guard let d = try? Data(contentsOf: stateURL), let p = try? JSONDecoder().decode(Persisted.self, from: d) else { return }
        viewed = Set(p.viewed)
        notes = p.notes
        llm = p.llm
        overview = p.overview
        reviewOrder = p.reviewOrder ?? []
        pendingComments = p.pendingComments ?? []
        persistedFingerprint = p.fingerprint
    }

    private var persistedFingerprint: String?

    func save() {
        let p = Persisted(viewed: Array(viewed), notes: notes, llm: llm, overview: overview, reviewOrder: reviewOrder, fingerprint: fingerprint, pendingComments: pendingComments)
        if let d = try? JSONEncoder().encode(p) { try? d.write(to: stateURL, options: .atomic) }
    }

    // MARK: Loading

    func load() async {
        state = .loading("Computing diff")
        do {
            let diffText = try await fetchDiff()
            files = DiffParser.parse(diffText).filter { !$0.hunks.isEmpty || $0.isBinary || $0.status != .modified }
            // Drop stale LLM triage when the diff changed since it was produced.
            if let fp = persistedFingerprint, fp != fingerprint {
                llm = [:]; overview = nil; reviewOrder = []
                viewed = viewed.intersection(Set(files.flatMap(\.hunks).map(\.id)))
            }
            if case .githubPR(let n) = target { await refreshPullRequest(n) }
            state = .loading("Classifying \(files.count) files")
            for f in files { await analyze(f) }
            // Hiding a tier only helps when something else is left to read.
            if allHunks.allSatisfy({ hideTiers.contains(tier(of: $0)) }) { hideTiers = [] }
            state = .ready
            save()
        } catch {
            state = .failed(error.localizedDescription)
        }
    }

    private func analyze(_ f: FileDiff) async {
        let oldDoc = f.status == .added ? nil : await document(f.oldPath, side: .old)
        let newDoc = f.status == .deleted ? nil : await document(f.newPath, side: .new)
        for h in f.hunks {
            analyses[h.id] = ChangeClassifier.classify(file: f, hunk: h, oldDoc: oldDoc, newDoc: newDoc)
        }
    }

    private func fetchDiff() async throws -> String {
        let fm = FileManager.default
        vcs = fm.fileExists(atPath: root.appendingPathComponent(".jj").path) ? .jj : .git
        switch target {
        case .jj(let from, let to):
            vcs = .jj
            oldRev = from
            newRev = to == "@" ? nil : to
            let desc = try? await Shell.output("jj", ["log", "--no-graph", "-r", to, "-T", "description"], cwd: root)
            let lines = (desc ?? "").split(separator: "\n", omittingEmptySubsequences: false)
            title = lines.first.map(String.init) ?? target.label
            if title.isEmpty { title = "(no description)" }
            body = lines.dropFirst().joined(separator: "\n").trimmingCharacters(in: .whitespacesAndNewlines)
            return try await Shell.output("jj", ["diff", "--git", "--context", "3", "--from", from, "--to", to], cwd: root)
        case .git(let base, let head):
            vcs = .git
            oldRev = base
            newRev = head
            title = target.label
            if let head { return try await Shell.output("git", ["diff", "--no-color", "--no-ext-diff", base, head], cwd: root) }
            return try await Shell.output("git", ["diff", "--no-color", "--no-ext-diff", base], cwd: root)
        case .githubPR(let n):
            vcs = .git
            state = .loading("Fetching PR #\(n)")
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
                state = .loading("Fetching PR commits")
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
            return try await Shell.output("git", ["diff", "--no-color", "--no-ext-diff", oldRev, head], cwd: root)
        }
    }

    enum Side { case old, new }

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
        let label = side == .old ? "Before" : (side == .new && newRev == nil ? nil : "After")
        let doc = SourceDocument(path: path, text: text, revisionLabel: label)
        if side == .old { oldDocs[path] = doc } else { newDocs[path] = doc }
        return doc
    }

    /// True when the "after" side is the working copy, so the code view can use live navigation.
    var afterIsWorkingCopy: Bool { newRev == nil }

    // MARK: Derived

    func tier(of h: Hunk) -> ChangeTier { llm[h.id]?.tier ?? analyses[h.id]?.tier ?? .behavior }

    func reasons(of h: Hunk) -> [String] {
        if let l = llm[h.id] { return [l.reason] }
        return analyses[h.id]?.reasons ?? []
    }

    var allHunks: [Hunk] { files.flatMap(\.hunks) }

    func hunks(in tier: ChangeTier) -> [Hunk] {
        let hs = allHunks.filter { self.tier(of: $0) == tier }
        guard !reviewOrder.isEmpty else { return hs }
        return hs.sorted { a, b in
            let ia = reviewOrder.firstIndex(of: a.id) ?? Int.max, ib = reviewOrder.firstIndex(of: b.id) ?? Int.max
            return ia < ib
        }
    }

    func fileTier(_ f: FileDiff) -> ChangeTier { f.hunks.map(tier(of:)).min() ?? .mechanical }

    var progress: (viewed: Int, total: Int) {
        let important = allHunks.filter { !tier(of: $0).isLowSignal }
        return (important.filter { viewed.contains($0.id) }.count, important.count)
    }

    func toggleViewed(_ id: String) {
        if viewed.contains(id) { viewed.remove(id) } else { viewed.insert(id) }
        save()
    }

    func file(for hunk: Hunk) -> FileDiff? { files.first { $0.hunks.contains { $0.id == hunk.id } } }

    // MARK: GitHub

    func refreshPullRequest(_ number: Int? = nil) async {
        guard let github else { return }
        let n: Int
        if let number { n = number } else if case .githubPR(let x) = target { n = x } else { return }
        do {
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
        return pendingComments.filter { c in
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

    func addPending(_ c: PendingComment) { pendingComments.append(c); save() }
    func removePending(_ id: UUID) { pendingComments.removeAll { $0.id == id }; save() }

    func submit(event: GitHubService.ReviewEvent, body: String) async throws {
        guard let github, let pr = pullRequest else { throw ClaudeError(message: "Not a GitHub pull request review") }
        try await github.submitReview(number: pr.number, commitId: pr.headSha, event: event, body: body, comments: pendingComments)
        pendingComments = []
        save()
        await refreshPullRequest(pr.number)
    }

    // MARK: Claude triage

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
            let r = try await Claude.run(prompt: prompt, system: ClaudeTasks.triageSystem, cwd: root, task: .triage, schema: ClaudeTasks.triageSchema) { [weak self] ev in
                if case .toolUse(let name, let s) = ev {
                    Task { @MainActor in self?.triageState = "\(name) \(s)" }
                }
            }
            let resp = try Claude.decode(ClaudeTasks.TriageResponse.self, from: r)
            for item in resp.hunks {
                guard let tier = ChangeTier(rawValue: item.tier) else { continue }
                llm[item.id] = LLMTriage(tier: tier, reason: item.reason, summary: item.summary)
            }
            overview = resp.overview
            reviewOrder = resp.reviewOrder ?? []
            triageState = String(format: "Triaged by Claude ($%.2f)", r.costUSD)
            save()
        } catch {
            triageState = "Triage failed: \(error.localizedDescription)"
        }
    }
}
