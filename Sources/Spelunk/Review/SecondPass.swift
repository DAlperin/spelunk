import Foundation

/// A review artifact an `attach` rule produces for some part of the change.
struct Attachment: Identifiable, Hashable {
    var rule: AttachRule
    /// Content-derived: the rule text plus the matched hunks' content keys.
    var key: String
    var label: String
    var paths: [String]
    var hunkIDs: [String]
    var id: String { key }

    static func == (a: Attachment, b: Attachment) -> Bool { a.key == b.key }
    func hash(into h: inout Hasher) { h.combine(key) }

    var isClaude: Bool { if case .claude = rule.action { true } else { false } }

    /// A shell command from the repository's own rules file: it comes with the code under review, so
    /// it runs only once the user has trusted that repository's commands.
    var needsTrust: Bool {
        guard rule.source == ".spelunk/review.rules", case .run = rule.action else { return false }
        return true
    }
}

/// What an attachment returns when it is structured: a Claude attachment always (through a JSON
/// schema), a command when its stdout is this JSON. Each part becomes real UI: findings open their
/// location, examples copy, actions draft a comment or start an ask or a trace.
struct AttachmentPayload: Codable, Hashable {
    struct Finding: Codable, Hashable {
        var title: String
        var detail: String?
        var path: String?
        var line: Int?
        /// info, warn or risk.
        var severity: String?
    }
    struct Example: Codable, Hashable {
        var title: String
        var language: String?
        var code: String
    }
    struct Action: Codable, Hashable {
        /// comment (draft a review comment on the hunk), ask, trace, or open (a path:line).
        var kind: String
        var label: String
        var text: String?
        var path: String?
        var line: Int?
    }
    var summary: String?
    var findings: [Finding]?
    var examples: [Example]?
    var actions: [Action]?

    var isEmpty: Bool { summary == nil && (findings ?? []).isEmpty && (examples ?? []).isEmpty && (actions ?? []).isEmpty }

    static let schema: [String: Any] = [
        "type": "object",
        "properties": [
            "summary": ["type": "string", "description": "Two or three sentences of Markdown at most."],
            "findings": ["type": "array", "items": ["type": "object", "properties": [
                "title": ["type": "string"], "detail": ["type": "string"], "path": ["type": "string"],
                "line": ["type": "integer"], "severity": ["type": "string", "enum": ["info", "warn", "risk"]],
            ], "required": ["title"]]],
            "examples": ["type": "array", "items": ["type": "object", "properties": [
                "title": ["type": "string"], "language": ["type": "string"], "code": ["type": "string"],
            ], "required": ["title", "code"]]],
            "actions": ["type": "array", "items": ["type": "object", "properties": [
                "kind": ["type": "string", "enum": ["comment", "ask", "trace", "open"]], "label": ["type": "string"],
                "text": ["type": "string"], "path": ["type": "string"], "line": ["type": "integer"],
            ], "required": ["kind", "label"]]],
        ],
        "required": ["summary"],
    ]
}

struct AttachmentResult: Codable, Hashable {
    var payload: AttachmentPayload?
    var markdown: String?
    var output: String?
    /// Files the command wrote into its output directory, as absolute paths.
    var files: [String] = []
    var error: String?
    var cost: Double = 0
    var date = Date()
    var seconds: Double = 0
}

extension ReviewSession {
    private func answerKey(_ q: String, _ h: Hunk) -> String { q + "\u{1}" + h.contentKey }

    private func rules() -> RuleSet { ReviewRules.shared.rules(for: root) }

    /// Facts for a hunk with every answer known so far.
    func currentFacts(_ h: Hunk) -> HunkFacts? {
        guard var f = facts[h.id] else { return nil }
        f.semantic = semantic[h.id]?.facts
        for (k, v) in conditionAnswers where k.hasSuffix("\u{1}" + h.contentKey) {
            f.answers[String(k.dropLast(h.contentKey.count + 1))] = v
        }
        return f
    }

    /// What a hunk still needs for its tier rules and attachments to be decided.
    private func pending(_ h: Hunk, _ rs: RuleSet) -> RulePending {
        guard let f = currentFacts(h) else { return RulePending() }
        var p = rs.evaluate(f).pending
        for a in rs.attachments where RuleSet.match(a.conditions, f) == nil { p.formUnion(RuleSet.pending(a.conditions, f)) }
        return p
    }

    /// Second pass: answers semantic and `llm` conditions for hunks whose other conditions already
    /// hold, re-evaluates them, then matches attachments.
    func resolvePendingRules() async {
        guard !resolvingRules else { rulesRerun = true; return }
        resolvingRules = true
        defer { resolvingRules = false }
        repeat {
            rulesRerun = false
            await resolvePendingRulesOnce()
        } while rulesRerun
    }

    private func resolvePendingRulesOnce() async {
        let rs = rules()
        // Attachments that need no answers show up before the slower semantic pass.
        matchAttachments(rs)
        for _ in 0..<3 {
            var semanticWork: [(Hunk, SemanticNeeds)] = []
            var questions: [String: [Hunk]] = [:]
            for f in files {
                for h in f.hunks {
                    let p = pending(h, rs)
                    if !p.needs.isEmpty { semanticWork.append((h, p.needs.union(semantic[h.id]?.needs ?? SemanticNeeds()))) }
                    for q in p.questions { questions[q, default: []].append(h) }
                }
            }
            if semanticWork.isEmpty && questions.isEmpty { break }
            if let provider = semanticProvider {
                for (i, (h, needs)) in semanticWork.enumerated() {
                    if rulesRerun { return }
                    guard let f = file(for: h) else { continue }
                    ruleState = "Semantic rules: \(i + 1) of \(semanticWork.count) hunks"
                    semantic[h.id] = (needs, await provider(h, f, needs))
                }
            } else {
                for (h, needs) in semanticWork { semantic[h.id] = (needs, .unavailable) }
            }
            for (q, hs) in questions.sorted(by: { $0.key < $1.key }) {
                ruleState = "Asking \(ClaudeModels.label(Claude.model(for: .rules))): \(q) (\(hs.count) hunks)"
                await answer(q, for: hs)
            }
            reevaluate(rs)
        }
        reevaluate(rs)
        matchAttachments(rs)
        ruleState = nil
    }

    private func reevaluate(_ rs: RuleSet) {
        var next = analyses
        for f in files {
            for h in f.hunks {
                guard let facts = currentFacts(h), facts.semantic != nil || !facts.answers.isEmpty else { continue }
                next[h.id] = ChangeClassifier.evaluate(rs, facts, enclosing: analyses[h.id]?.enclosing)
            }
        }
        analyses = next
    }

    /// One batched yes/no question per rule condition; every hunk sent gets a cached answer.
    private func answer(_ q: String, for hunks: [Hunk]) async {
        var remaining = hunks.filter { conditionAnswers[answerKey(q, $0)] == nil }
        while !remaining.isEmpty {
            var prompt = "Question: \(q)\n\nChange: \(title)\n\nHunks:\n"
            var budget = 50_000
            var sent: [Hunk] = []
            for h in remaining {
                let body = h.lines.filter { $0.kind != .context }.map { ($0.kind == .added ? "+" : "-") + $0.text }
                let text = body.count > 40 ? (body.prefix(40) + ["… \(body.count - 40) more lines"]).joined(separator: "\n") : body.joined(separator: "\n")
                let chunk = "\n### \(h.id) file=\(h.path) in=\(analyses[h.id]?.enclosing ?? "-")\n\(text)\n"
                if budget - chunk.utf8.count < 0 && !sent.isEmpty { break }
                budget -= chunk.utf8.count
                prompt += chunk
                sent.append(h)
            }
            remaining.removeFirst(sent.count)
            do {
                let r = try await Claude.run(prompt: prompt, system: ClaudeTasks.ruleQuestionSystem, cwd: root, task: .rules,
                                             schema: ClaudeTasks.ruleQuestionSchema, tools: [])
                let resp = try Claude.decode(ClaudeTasks.RuleQuestionResponse.self, from: r)
                let yes = Set(resp.yes)
                for h in sent { conditionAnswers[answerKey(q, h)] = yes.contains(h.id) }
                save()
            } catch {
                ruleState = "Rule question failed: \(error.localizedDescription)"
                return
            }
        }
    }

    // MARK: Attachments

    func matchAttachments(_ rs: RuleSet? = nil) {
        let rs = rs ?? rules()
        var out: [Attachment] = []
        for rule in rs.attachments {
            var matched: [Hunk] = []
            for f in files {
                for h in f.hunks {
                    if let facts = currentFacts(h), RuleSet.match(rule.conditions, facts) == true { matched.append(h) }
                }
            }
            guard !matched.isEmpty else { continue }
            let buckets: [(String, [Hunk])]
            switch rule.scope {
            case .change: buckets = [("Whole change", matched)]
            case .file: buckets = Dictionary(grouping: matched, by: \.path).sorted { $0.key < $1.key }.map { ($0.key, $0.value) }
            case .hunk: buckets = matched.map { (analyses[$0.id]?.enclosing ?? $0.path.lastPathComponent, [$0]) }
            }
            for (label, hs) in buckets {
                let basis = rule.text + "\n" + hs.map(\.contentKey).sorted().joined(separator: "\n")
                let key = String(UInt(bitPattern: basis.stableHash), radix: 36)
                out.append(Attachment(rule: rule, key: key, label: label, paths: Array(Set(hs.map(\.path))).sorted(), hunkIDs: hs.map(\.id)))
            }
        }
        attachments = out
        let missing = out.filter { attachmentResults[$0.key] == nil }
        guard !missing.isEmpty else { return }
        Task {
            let stored = await store.results(task: ResultTask.attachment, keys: missing.map(\.key))
            for a in missing {
                if let d = stored[a.key], let r = try? JSONDecoder().decode(AttachmentResult.self, from: d) {
                    attachmentResults[a.key] = r
                } else if let r = legacyAttachmentResult(a.key) {
                    attachmentResults[a.key] = r
                    if let d = try? JSONEncoder().encode(r) { await store.putResults(task: ResultTask.attachment, [(a.key, d)]) }
                }
            }
            for a in missing where Prefs.autoAttachments && a.rule.auto && attachmentResults[a.key] == nil && (!a.needsTrust || repoCommandsTrusted) { runAttachment(a) }
        }
    }

    var repoCommandsTrusted: Bool {
        (UserDefaults.standard.stringArray(forKey: "rules.trustedRepos") ?? []).contains(root.path)
    }

    func trustRepoCommands() {
        var list = UserDefaults.standard.stringArray(forKey: "rules.trustedRepos") ?? []
        if !list.contains(root.path) { list.append(root.path) }
        UserDefaults.standard.set(list, forKey: "rules.trustedRepos")
    }

    func attachments(for h: Hunk) -> [Attachment] {
        attachments.filter { $0.hunkIDs.contains(h.id) }
    }

    func attachments(forPath p: String) -> [Attachment] { attachments.filter { $0.paths.contains(p) } }

    private func attachmentDir(_ key: String) -> URL {
        let d = AppPaths.support(for: root).appendingPathComponent("attachments/\(key)", isDirectory: true)
        try? FileManager.default.createDirectory(at: d, withIntermediateDirectories: true)
        return d
    }

    private func legacyAttachmentResult(_ key: String) -> AttachmentResult? {
        let u = AppPaths.support(for: root).appendingPathComponent("attachments/\(key)/result.json")
        guard let d = try? Data(contentsOf: u) else { return nil }
        return try? JSONDecoder().decode(AttachmentResult.self, from: d)
    }

    func cancelAttachment(_ a: Attachment) {
        attachmentTasks[a.key]?.cancel()
        attachmentTasks[a.key] = nil
        attachmentsRunning.remove(a.key)
    }

    /// Runs the rule's command or Claude prompt. Results are stored next to their output files and
    /// reused until the rule or the matched hunks change.
    func runAttachment(_ a: Attachment) {
        guard !attachmentsRunning.contains(a.key), let action = a.rule.action, !a.needsTrust || repoCommandsTrusted else { return }
        attachmentsRunning.insert(a.key)
        let dir = attachmentDir(a.key)
        let out = dir.appendingPathComponent("out", isDirectory: true)
        try? FileManager.default.removeItem(at: out)
        try? FileManager.default.createDirectory(at: out, withIntermediateDirectories: true)
        let hunks = allHunks.filter { a.hunkIDs.contains($0.id) }
        let diff = hunks.map { h in
            "--- \(h.path)\n" + h.header + "\n" + h.lines.map { ($0.kind == .added ? "+" : $0.kind == .removed ? "-" : " ") + $0.text }.joined(separator: "\n")
        }.joined(separator: "\n\n")
        let diffURL = dir.appendingPathComponent("hunks.diff")
        try? diff.write(to: diffURL, atomically: true, encoding: .utf8)
        let name = hunks.first.flatMap { analyses[$0.id]?.enclosing } ?? ""
        let start = Date()
        attachmentTasks[a.key] = Task {
            var result = AttachmentResult()
            switch action {
            case .run(let command):
                let head: URL
                do { head = try await self.headCheckout() } catch {
                    result.error = error.localizedDescription
                    break
                }
                let quoted = { (s: String) in "'" + s.replacingOccurrences(of: "'", with: "'\\''") + "'" }
                let cmd = command
                    .replacingOccurrences(of: "{file}", with: quoted(a.paths.first ?? ""))
                    .replacingOccurrences(of: "{files}", with: a.paths.map(quoted).joined(separator: " "))
                    .replacingOccurrences(of: "{out}", with: quoted(out.path))
                    .replacingOccurrences(of: "{name}", with: quoted(name))
                    .replacingOccurrences(of: "{head}", with: quoted(head.path))
                let env = ["SPELUNK_HEAD_DIR=\(head.path)", "SPELUNK_FILE=\(a.paths.first ?? "")", "SPELUNK_FILES=\(a.paths.joined(separator: "\n"))",
                           "SPELUNK_OUT=\(out.path)", "SPELUNK_DIFF=\(diffURL.path)", "SPELUNK_NAME=\(name)",
                           "SPELUNK_BASE=\(oldRev)", "SPELUNK_HEAD=\(newRev ?? "")"]
                do {
                    let r = try await Shell.run("/usr/bin/env", env + ["/bin/sh", "-c", cmd], cwd: head, timeout: 900)
                    let text = (r.stdout + (r.ok ? "" : "\n" + r.stderr)).trimmingCharacters(in: .whitespacesAndNewlines)
                    if r.ok, text.hasPrefix("{"), let p = try? JSONDecoder().decode(AttachmentPayload.self, from: Data(text.utf8)), !p.isEmpty {
                        result.payload = p
                    } else if !text.isEmpty {
                        result.output = String(text.prefix(40_000))
                    }
                    if !r.ok { result.error = "exit \(r.status)" }
                } catch {
                    result.error = error.localizedDescription
                }
            case .claude(let ask):
                let head: URL
                do { head = try await self.headCheckout() } catch {
                    result.error = error.localizedDescription
                    break
                }
                let diffFile = self.fullDiffFile()
                var prompt = ask.replacingOccurrences(of: "{name}", with: name).replacingOccurrences(of: "{file}", with: a.paths.first ?? "")
                prompt += "\n\nChange: \(title)\n"
                prompt += "The working directory is the code after the whole change is applied. The full diff of the change is in \(diffFile.path) (\(files.count) files); "
                prompt += "check it, and the code as it now is, before reporting anything as missing or still present.\n"
                prompt += "Files changed: " + files.prefix(200).map { "\($0.path) (+\($0.addedCount) -\($0.removedCount))" }.joined(separator: ", ") + "\n"
                prompt += "\nThis attachment is for \(a.paths.joined(separator: ", ")). Its hunks:\n\n" + String(diff.prefix(60_000))
                do {
                    let r = try await Claude.run(prompt: prompt, system: ClaudeTasks.attachSystem, cwd: head, task: .attach,
                                                 schema: AttachmentPayload.schema, model: a.rule.model,
                                                 readableDirs: [diffFile.deletingLastPathComponent()])
                    if let p = try? Claude.decode(AttachmentPayload.self, from: r) { result.payload = p } else { result.markdown = r.text }
                    result.cost = r.costUSD
                } catch {
                    if Task.isCancelled { return }
                    result.error = error.localizedDescription
                }
            }
            if Task.isCancelled { return }
            let files = (try? FileManager.default.contentsOfDirectory(at: out, includingPropertiesForKeys: nil)) ?? []
            result.files = files.map(\.path).sorted()
            result.seconds = Date().timeIntervalSince(start)
            result.date = Date()
            if result.error == nil, let d = try? JSONEncoder().encode(result) {
                let store = self.store
                Task { await store.putResults(task: ResultTask.attachment, [(a.key, d)], model: a.rule.model) }
            }
            attachmentResults[a.key] = result
            attachmentsRunning.remove(a.key)
            attachmentTasks[a.key] = nil
        }
    }
}
