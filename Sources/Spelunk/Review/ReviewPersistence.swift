import Foundation

/// What was last written to the store, so `save()` writes only rows that changed.
struct PersistedMirror {
    var viewed: Set<String> = []
    var notes: [String: String] = [:]
    var llm: [String: LLMTriage] = [:]
    var conditions: [String: [String: Bool]] = [:]
    var meta: [String: String] = [:]
    var drafts: [UUID: PendingComment] = [:]
}

extension ReviewSession {
    enum ResultTask {
        static let triage = "triage.v1"
        static let conditions = "conditions.v1"
        static let attachment = "attachment.v1"
    }

    /// A name for this review that keeps meaning the same code: a PR number, a jj change id, or
    /// commit ids. Relative names such as `@` are resolved.
    func resolveIdentity() async -> String {
        func jjChange(_ rev: String) async -> String {
            let id = try? await Shell.output("jj", ["log", "--no-graph", "--ignore-working-copy", "-r", rev, "-T", "change_id"], cwd: root)
            return id?.trimmingCharacters(in: .whitespacesAndNewlines).nilIfEmpty ?? rev
        }
        func gitRev(_ rev: String) async -> String {
            let id = try? await Shell.output("git", ["rev-parse", rev], cwd: root)
            return id?.trimmingCharacters(in: .whitespacesAndNewlines).nilIfEmpty ?? rev
        }
        switch target {
        case .githubPR(let n):
            return "pr:\(n)"
        case .jj(let from, let to):
            let head = await jjChange(to)
            // A change reviewed against its parent is identified by the change alone, so its state
            // survives rebases.
            let isParent = from == "\(to)-" || (from == "@-" && to == "@") || (from == "@--" && to == "@-")
            return isParent ? "jj:\(head)" : "jj:\(await jjChange(from))..\(head)"
        case .git(let base, let head):
            let b = await gitRev(base)
            if let head { return "git:\(b)..\(await gitRev(head))" }
            let branch = (try? await Shell.output("git", ["rev-parse", "--abbrev-ref", "HEAD"], cwd: root))?
                .trimmingCharacters(in: .whitespacesAndNewlines) ?? "HEAD"
            return "git:\(b)..wt:\(branch)"
        }
    }

    var store: Store { Store.shared(for: root) }

    /// Loads user state for the review's identity (once) and cached results for hunks not seen yet.
    func hydrate() async {
        guard let identity else { return }
        if hydratedIdentity != identity {
            hydratedIdentity = identity
            if !(await store.hasReviewState(identity)) { await importLegacyState(into: identity) }
            var m = PersistedMirror()
            for row in await store.reviewState(identity) {
                switch row.kind {
                case "viewed": m.viewed.insert(row.key)
                case "note": m.notes[row.key] = row.value
                case "meta": m.meta[row.key] = row.value
                default: break
                }
            }
            for d in await store.drafts(identity) {
                if let c = try? JSONDecoder().decode(PendingComment.self, from: d) { m.drafts[c.id] = c }
            }
            viewed = m.viewed
            notes = m.notes
            pendingComments = m.drafts.values.sorted { $0.line < $1.line }
            overview = m.meta["overview"]
            reviewOrder = m.meta["order"].flatMap { try? JSONDecoder().decode([String].self, from: Data($0.utf8)) } ?? []
            claudeGroups = m.meta["groups"].flatMap { try? JSONDecoder().decode([HunkGroup].self, from: Data($0.utf8)) } ?? []
            overviewFingerprint = m.meta["overviewFingerprint"]
            mirror.viewed = m.viewed
            mirror.notes = m.notes
            mirror.meta = m.meta
            mirror.drafts = m.drafts
        }
        let keys = Array(Set(allHunks.map(\.contentKey)).filter { llm[$0] == nil })
        if !keys.isEmpty {
            for (k, d) in await store.results(task: ResultTask.triage, keys: keys) {
                if let t = try? JSONDecoder().decode(LLMTriage.self, from: d) { llm[k] = t; mirror.llm[k] = t }
            }
            for (k, d) in await store.results(task: ResultTask.conditions, keys: keys) {
                guard let answers = try? JSONDecoder().decode([String: Bool].self, from: d) else { continue }
                mirror.conditions[k] = answers
                for (q, v) in answers { conditionAnswers[q + "\u{1}" + k] = v }
            }
        }
    }

    /// Writes the rows that changed since the last save. Writes are chained so they land in order.
    func save() {
        guard let identity, hydratedIdentity == identity else { return }
        var state: [(kind: String, key: String, value: String?)] = []
        for k in viewed.subtracting(mirror.viewed) { state.append(("viewed", k, "1")) }
        for k in mirror.viewed.subtracting(viewed) { state.append(("viewed", k, nil)) }
        for (k, v) in notes where mirror.notes[k] != v { state.append(("note", k, v)) }
        for k in mirror.notes.keys where notes[k] == nil { state.append(("note", k, nil)) }
        var meta: [String: String] = [:]
        if let overview { meta["overview"] = overview }
        if let fp = overviewFingerprint { meta["overviewFingerprint"] = fp }
        if !reviewOrder.isEmpty, let d = try? JSONEncoder().encode(reviewOrder) { meta["order"] = String(decoding: d, as: UTF8.self) }
        if !claudeGroups.isEmpty, let d = try? JSONEncoder().encode(claudeGroups) { meta["groups"] = String(decoding: d, as: UTF8.self) }
        for (k, v) in meta where mirror.meta[k] != v { state.append(("meta", k, v)) }
        for k in mirror.meta.keys where meta[k] == nil { state.append(("meta", k, nil)) }

        var triage: [(key: String, value: Data)] = []
        for (k, t) in llm where mirror.llm[k] != t { if let d = try? JSONEncoder().encode(t) { triage.append((k, d)) } }
        let removedTriage = mirror.llm.keys.filter { llm[$0] == nil }

        var byHunk: [String: [String: Bool]] = [:]
        for (key, v) in conditionAnswers {
            guard let sep = key.lastIndex(of: "\u{1}") else { continue }
            byHunk[String(key[key.index(after: sep)...]), default: [:]][String(key[..<sep])] = v
        }
        var conditions: [(key: String, value: Data)] = []
        for (k, answers) in byHunk where mirror.conditions[k] != answers {
            if let d = try? JSONEncoder().encode(answers) { conditions.append((k, d)) }
        }

        let current = Dictionary(pendingComments.map { ($0.id, $0) }, uniquingKeysWith: { a, _ in a })
        let changedDrafts = current.values.filter { mirror.drafts[$0.id] != $0 }
        let removedDrafts = mirror.drafts.keys.filter { current[$0] == nil }.map(\.uuidString)

        mirror.viewed = viewed
        mirror.notes = notes
        mirror.meta = meta
        mirror.llm = llm
        mirror.conditions.merge(byHunk) { _, new in new }
        mirror.drafts = current
        guard !state.isEmpty || !triage.isEmpty || !removedTriage.isEmpty || !conditions.isEmpty || !changedDrafts.isEmpty || !removedDrafts.isEmpty else { return }

        let store = self.store
        let encoded = changedDrafts.compactMap { c in (try? JSONEncoder().encode(c)).map { (c, $0) } }
        let previous = writeChain
        writeChain = Task.detached {
            await previous?.value
            await store.applyReviewState(identity, state)
            if !triage.isEmpty { await store.putResults(task: ResultTask.triage, triage) }
            if !removedTriage.isEmpty { await store.deleteResults(task: ResultTask.triage, keys: removedTriage) }
            if !conditions.isEmpty { await store.putResults(task: ResultTask.conditions, conditions) }
            for (c, d) in encoded { await store.putDraft(id: c.id.uuidString, review: identity, pr: c.prNumber, commit: c.commitId, value: d) }
            if !removedDrafts.isEmpty { await store.deleteDrafts(removedDrafts) }
        }
    }

    // MARK: Legacy JSON

    private struct LegacyState: Codable {
        var viewed: [String]
        var notes: [String: String]
        var llm: [String: LLMTriage]
        var overview: String?
        var reviewOrder: [String]?
        var fingerprint: String
        var pendingComments: [PendingComment]?
        var claudeGroups: [HunkGroup]?
        var conditionAnswers: [String: Bool]?
    }

    /// Imports the JSON file earlier versions kept per review target, once, then renames it.
    private func importLegacyState(into identity: String) async {
        let url = AppPaths.support(for: root).appendingPathComponent("review-\(String(UInt(bitPattern: target.key.stableHash), radix: 36)).json")
        guard let d = try? Data(contentsOf: url), let p = try? JSONDecoder().decode(LegacyState.self, from: d) else { return }
        var state: [(kind: String, key: String, value: String?)] = p.viewed.map { ("viewed", $0, "1") }
        state += p.notes.map { ("note", $0.key, $0.value) }
        if let o = p.overview { state.append(("meta", "overview", o)); state.append(("meta", "overviewFingerprint", p.fingerprint)) }
        if let o = p.reviewOrder, !o.isEmpty, let e = try? JSONEncoder().encode(o) { state.append(("meta", "order", String(decoding: e, as: UTF8.self))) }
        if let g = p.claudeGroups, !g.isEmpty, let e = try? JSONEncoder().encode(g) { state.append(("meta", "groups", String(decoding: e, as: UTF8.self))) }
        await store.applyReviewState(identity, state)
        await store.putResults(task: ResultTask.triage, p.llm.compactMap { k, v in (try? JSONEncoder().encode(v)).map { (k, $0) } })
        var byHunk: [String: [String: Bool]] = [:]
        for (key, v) in p.conditionAnswers ?? [:] {
            guard let sep = key.lastIndex(of: "\u{1}") else { continue }
            byHunk[String(key[key.index(after: sep)...]), default: [:]][String(key[..<sep])] = v
        }
        await store.putResults(task: ResultTask.conditions, byHunk.compactMap { k, v in (try? JSONEncoder().encode(v)).map { (k, $0) } })
        // Drafts from before stamping are kept only for pull request reviews, where they belong.
        if case .githubPR(let n) = target {
            for var c in p.pendingComments ?? [] {
                c.prNumber = n
                if let e = try? JSONEncoder().encode(c) { await store.putDraft(id: c.id.uuidString, review: identity, pr: n, commit: c.commitId, value: e) }
            }
        }
        try? FileManager.default.moveItem(at: url, to: url.appendingPathExtension("imported"))
        Log.debug("review: imported legacy state for \(identity)")
    }
}

extension String {
    var nilIfEmpty: String? { isEmpty ? nil : self }
}
