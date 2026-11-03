import Foundation

/// Hunks that belong to one logical change: every place a removed symbol was used, every use of a
/// new one, or a group Claude proposed. Groups refer to hunks by content key, so they survive
/// reloads, and a hunk may sit in several groups.
struct HunkGroup: Identifiable, Hashable, Codable, Sendable {
    enum Kind: String, Codable, Sendable { case removes, adds, changes, claude }

    var kind: Kind
    var title: String
    var symbols: [String]
    var keys: [String]
    var rationale: String?
    var id: String { kind.rawValue + ":" + title }

    var glyph: String {
        switch kind {
        case .removes: "minus.circle"
        case .adds: "plus.circle"
        case .changes: "arrow.triangle.branch"
        case .claude: "sparkles"
        }
    }
}

/// Deterministic grouping: identifiers (including those inside string literals, which is how
/// config flags and metric names show up) that the change removes everywhere, adds fresh, or edits
/// across several files. Common words and identifiers that appear in most of the diff are ignored.
enum HunkGrouper {
    static let stop: Set<String> = [
        "self", "Self", "super", "crate", "true", "false", "None", "Some", "Ok", "Err", "Option", "Result", "String", "Vec",
        "Box", "Arc", "Rc", "HashMap", "BTreeMap", "BTreeSet", "HashSet", "clone", "into", "unwrap", "expect", "iter",
        "collect", "len", "map", "push", "insert", "default", "new", "from", "to_string", "as_ref", "await", "async",
        "impl", "where", "match", "return", "const", "static", "struct", "enum", "trait", "pub", "use", "mod", "let",
        "mut", "ref", "fn", "for", "while", "loop", "else", "type", "dyn", "move", "unsafe", "Debug", "Clone",
        "Default", "Serialize", "Deserialize", "PartialEq", "Eq", "Hash", "derive", "test", "assert", "assert_eq",
        "format", "println", "tracing", "debug", "info", "warn", "error", "config", "value", "name", "result", "this",
        "that", "with", "should", "when", "then", "TODO",
    ]

    /// Distinctive enough to tie hunks together: snake case, camel case or digits, or simply long.
    static func distinctive(_ s: String) -> Bool {
        guard s.count >= 4, !stop.contains(s), s.first?.isNumber == false else { return false }
        let inner = s.dropFirst()
        if s.contains("_") || inner.contains(where: \.isUppercase) || s.contains(where: \.isNumber) { return true }
        // A single plain word, capitalized or not, is usually English or a common type name.
        return s.count >= Prefs.groupDistinctLength
    }

    private static let identRE = try! NSRegularExpression(pattern: #"[A-Za-z_][A-Za-z0-9_]*"#)

    /// Identifiers on a changed line, with line comments dropped.
    static func identifiers(_ line: String) -> Set<String> {
        var t = line.trimmingCharacters(in: .whitespaces)
        if t.hasPrefix("//") || t.hasPrefix("#") || t.hasPrefix("*") || t.hasPrefix("/*") { return [] }
        if let r = t.range(of: " //") { t = String(t[..<r.lowerBound]) }
        let ns = t as NSString
        var out: Set<String> = []
        for m in identRE.matches(in: t, range: NSRange(location: 0, length: ns.length)) {
            let s = ns.substring(with: m.range)
            if distinctive(s) { out.insert(s) }
        }
        return out
    }

    /// Spelling-insensitive key, so `ENABLE_HALF_JOIN2`, `enable_half_join2` and `EnableHalfJoin2`
    /// form one group.
    static func normalize(_ s: String) -> String { s.lowercased().replacingOccurrences(of: "_", with: "") }

    static func group(_ files: [FileDiff], skipPaths: (String) -> Bool = { _ in false }) -> [HunkGroup] {
        struct Use { var removed: Set<Int> = []; var added: Set<Int> = []; var spellings: [String: Int] = [:] }
        var hunks: [Hunk] = []
        var uses: [String: Use] = [:]
        for f in files where !skipPaths(f.path) {
            for h in f.hunks {
                let i = hunks.count
                hunks.append(h)
                for l in h.lines where l.kind != .context {
                    for id in identifiers(l.text) {
                        let k = normalize(id)
                        var u = uses[k] ?? Use()
                        if l.kind == .removed { u.removed.insert(i) } else { u.added.insert(i) }
                        u.spellings[id, default: 0] += 1
                        uses[k] = u
                    }
                }
            }
        }
        guard hunks.count >= 2 else { return [] }
        let cap = max(12, hunks.count / 4)

        struct Candidate { var seed: Set<Int> = []; var keys: Set<String>; var kind: HunkGroup.Kind; var symbols: [String]; var members: Set<Int>; var score: Int }
        var candidates: [Candidate] = []
        for (key, u) in uses {
            let members = u.removed.union(u.added)
            guard members.count >= 2, members.count <= cap else { continue }
            let fileCount = Set(members.map { hunks[$0].path }).count
            let kind: HunkGroup.Kind = u.added.isEmpty ? .removes : u.removed.isEmpty ? .adds : .changes
            // An identifier edited in place within one file is ordinary churn, not a cross-cutting change.
            if kind == .changes && fileCount < 2 { continue }
            if fileCount < 2 && members.count < 3 { continue }
            let spelling = u.spellings.max { $0.value < $1.value || ($0.value == $1.value && $0.key > $1.key) }!.key
            // A symbol that disappears or appears everywhere is the clearest unit of review; one that is
            // merely mentioned on both sides of many hunks is usually a type passing through.
            let score: Int
            switch kind {
            case .removes, .adds: score = 1000 + fileCount * 3 + members.count
            default: score = fileCount * 3 + members.count - max(0, members.count - 12) * 4
            }
            candidates.append(Candidate(keys: [key], kind: kind, symbols: [spelling], members: members, score: score))
        }
        candidates.sort { $0.score != $1.score ? $0.score > $1.score : $0.symbols[0] < $1.symbols[0] }

        // Fold related candidates into the stronger one: same kind and one name containing the other
        // (`ENABLE_HALF_JOIN2` and `enable_compute_half_join2` around `half_join2`), or nearly the same hunks.
        var kept: [Candidate] = []
        for c in candidates {
            if let i = kept.firstIndex(where: { k in
                let ck = c.keys.first!
                let related = k.kind == c.kind && k.kind != .changes
                    && k.keys.contains { min($0.count, ck.count) >= 6 && ($0.contains(ck) || ck.contains($0)) }
                    && Set(k.members.map { hunks[$0].path }).intersection(c.members.map { hunks[$0].path }).count > 0
                // Compare against the group's original seed, not its grown union, so merging does not snowball.
                let inter = Double(k.seed.intersection(c.members).count)
                return related || inter / Double(k.seed.union(c.members).count) >= Prefs.groupOverlap
            }) {
                if !kept[i].symbols.contains(c.symbols[0]) { kept[i].symbols.append(c.symbols[0]) }
                kept[i].members.formUnion(c.members)
                kept[i].keys.formUnion(c.keys)
                continue
            }
            var seeded = c
            seeded.seed = c.members
            kept.append(seeded)
            if kept.count >= Prefs.groupMaxGroups { break }
        }

        return kept.map { c in
            let order = c.members.sorted()
            let names = c.symbols.prefix(2).map { "`\($0)`" }.joined(separator: ", ") + (c.symbols.count > 2 ? " +\(c.symbols.count - 2)" : "")
            let verb = switch c.kind {
            case .removes: "Removes"
            case .adds: "Adds"
            default: "Changes around"
            }
            return HunkGroup(kind: c.kind, title: "\(verb) \(names)", symbols: c.symbols, keys: order.map { hunks[$0].contentKey })
        }
    }
}

extension ReviewSession {
    /// Claude's groups first, then the symbol groups.
    var allGroups: [HunkGroup] { claudeGroups + groups }

    func hunks(of g: HunkGroup) -> [Hunk] {
        let byKey = Dictionary(allHunks.map { ($0.contentKey, $0) }, uniquingKeysWith: { a, _ in a })
        return g.keys.compactMap { byKey[$0] }
    }

    func groups(containing h: Hunk) -> [HunkGroup] {
        allGroups.filter { $0.keys.contains(h.contentKey) }
    }

    func fileCount(of g: HunkGroup) -> Int { Set(hunks(of: g).map(\.path)).count }

    /// Regroups the current files off the main thread; a newer call supersedes an older one still running.
    func recomputeGroups() async {
        groupsGeneration += 1
        let generation = groupsGeneration
        let files = self.files
        let grouped = await Task.detached(priority: .userInitiated) {
            HunkGrouper.group(files) { FileClassifier.isGenerated($0) || $0.hasSuffix(".lock") }
        }.value
        if generation == groupsGeneration { groups = grouped }
    }

    /// Asks a cheap model to group the important hunks into logical changes. Diff text only, no tools.
    func groupWithClaude() async {
        guard !grouping else { return }
        grouping = true
        defer { grouping = false }
        let candidates = allHunks.filter { !tier(of: $0).isLowSignal }
        let model = ClaudeModels.label(Claude.model(for: .group))
        groupState = "Grouping \(candidates.count) hunks with \(model)…"
        var prompt = "Change: \(title)\n"
        if !body.isEmpty { prompt += "\nDescription:\n\(body.prefix(3000))\n" }
        prompt += "\nHunks:\n"
        var budget = 90_000
        var sent: [String: Hunk] = [:]
        for h in candidates {
            let body = h.lines.filter { $0.kind != .context }.map { ($0.kind == .added ? "+" : "-") + $0.text }
            let text = body.count > 16 ? (body.prefix(16) + ["… \(body.count - 16) more lines"]).joined(separator: "\n") : body.joined(separator: "\n")
            let chunk = "\n### \(h.id) file=\(h.path) in=\(analyses[h.id]?.enclosing ?? "-")\n\(text)\n"
            if budget - chunk.utf8.count < 0 { break }
            budget -= chunk.utf8.count
            prompt += chunk
            sent[h.id] = h
        }
        do {
            let r = try await Claude.run(prompt: prompt, system: ClaudeTasks.groupSystem, cwd: root, task: .group,
                                         schema: ClaudeTasks.groupSchema, tools: [])
            let resp = try Claude.decode(ClaudeTasks.GroupResponse.self, from: r)
            claudeGroups = resp.groups.compactMap { g in
                let keys = g.hunks.compactMap { sent[$0]?.contentKey }
                return keys.count >= 2 ? HunkGroup(kind: .claude, title: g.title, symbols: [], keys: keys, rationale: g.rationale) : nil
            }
            groupState = String(format: "%d groups from %@ ($%.3f)", claudeGroups.count, model, r.costUSD)
            save()
        } catch {
            groupState = "Grouping failed: \(error.localizedDescription)"
        }
    }
}

/// One tier of the importance list. A group sits in the tier of its most important member and
/// holds its members from any important tier, so a related change reads as one unit.
struct TierSection: Identifiable {
    enum Item: Identifiable {
        case hunk(Hunk)
        case group(HunkGroup, [Hunk])
        var id: String {
            switch self {
            case .hunk(let h): "h:" + h.id
            case .group(let g, _): "g:" + g.id
            }
        }
    }
    var tier: ChangeTier
    var items: [Item]
    var id: ChangeTier { tier }

    var hunks: [Hunk] {
        items.flatMap { i -> [Hunk] in
            switch i {
            case .hunk(let h): [h]
            case .group(_, let hs): hs
            }
        }
    }
}

extension ReviewSession {
    /// The important tiers as shown in the list, cached until tiers, groups or the order change.
    var tierSections: [TierSection] {
        if let c = layoutCache { return c }
        let c = computeSections()
        layoutCache = c
        return c
    }

    private func computeSections() -> [TierSection] {
        let important = Set(ChangeTier.important)
        var groupOf: [String: Int] = [:]
        var placed: [(group: HunkGroup, tier: ChangeTier, hunks: [Hunk])] = []
        if groupRelated {
            for g in allGroups {
                let members = hunks(of: g).filter { groupOf[$0.id] == nil && important.contains(tier(of: $0)) }
                guard members.count >= 2 else { continue }
                let t = members.map(tier(of:)).min()!
                let ordered = members.sorted { tier(of: $0) < tier(of: $1) }
                for h in members { groupOf[h.id] = placed.count }
                placed.append((g, t, ordered))
            }
        }
        var emitted: Set<Int> = []
        return ChangeTier.important.compactMap { t in
            var items: [TierSection.Item] = []
            for h in hunks(in: t) {
                if let gi = groupOf[h.id] {
                    guard placed[gi].tier == t, !emitted.contains(gi) else { continue }
                    emitted.insert(gi)
                    items.append(.group(placed[gi].group, placed[gi].hunks))
                } else {
                    items.append(.hunk(h))
                }
            }
            return items.isEmpty ? nil : TierSection(tier: t, items: items)
        }
    }

    /// The group the hunk is listed under, if any.
    func listedGroup(of h: Hunk) -> HunkGroup? {
        for s in tierSections {
            for case .group(let g, let hs) in s.items where hs.contains(where: { $0.id == h.id }) { return g }
        }
        return nil
    }
}
