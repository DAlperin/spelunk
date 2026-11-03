import Foundation

/// One Claude run started from the UI: a question answered in prose, or a code path generated from
/// a question. Any number run at once; each keeps its own progress, result and cost.
struct ClaudeJob: Identifiable, Codable {
    enum Kind: String, Codable { case ask = "Ask", trace = "Trace", attach = "Attachment" }

    var id = UUID()
    var kind: Kind
    var question: String
    var anchor: String?
    var model: String
    var answer = ""
    var activity: [String] = []
    var running = true
    var cancelled = false
    var cost: Double = 0
    var error: String?
    /// The code path a trace job produced.
    var traceID: UUID?
    var started = Date()
    var finished: Date?
    /// Finished while the Claude pane was not showing it.
    var unseen = false
    /// Question, anchor and revision: a finished job with the same key answers a repeat instantly.
    var cacheKey: String?
    /// Shown from an earlier run instead of asking again.
    var fromCache = false

    var status: String {
        if running { return activity.last ?? "Starting" }
        if cancelled { return "Cancelled" }
        if let error { return error }
        if fromCache { return String(format: "Cached from %@ · $0", started.formatted(date: .abbreviated, time: .shortened)) }
        return String(format: "Done in %.0fs · $%.3f", (finished ?? Date()).timeIntervalSince(started), cost)
    }
}

extension Workspace {
    private var jobsURL: URL { AppPaths.support(for: root).appendingPathComponent("claude-jobs.json") }

    /// Finished, successful runs are kept on disk so answers survive relaunches and repeat questions
    /// cost nothing until the code changes.
    func loadJobs() {
        guard let d = try? Data(contentsOf: jobsURL), let saved = try? JSONDecoder().decode([ClaudeJob].self, from: d) else { return }
        jobs = saved
    }

    func saveJobs() {
        let keep = jobs.filter { !$0.running && !$0.cancelled && $0.error == nil && !$0.fromCache }.suffix(60)
        if let d = try? JSONEncoder().encode(Array(keep).map { var j = $0; j.unseen = false; return j }) { try? d.write(to: jobsURL, options: .atomic) }
    }

    func jobCacheKey(_ kind: ClaudeJob.Kind, _ question: String, _ anchor: String?) -> String {
        [kind.rawValue, question.trimmingCharacters(in: .whitespacesAndNewlines), anchor ?? "", vcs.revision].joined(separator: "\u{1}")
    }

    /// A previous successful run of the same job at the same revision, if any.
    private func cachedJob(_ key: String) -> ClaudeJob? {
        jobs.last { $0.cacheKey == key && !$0.running && !$0.cancelled && $0.error == nil && !$0.fromCache
            && ($0.kind != .trace || $0.traceID.map { id in traces.traces.contains { $0.id == id } } == true) }
    }

    private func replay(_ hit: ClaudeJob) {
        var j = hit
        j.id = UUID()
        j.fromCache = true
        j.unseen = false
        j.started = hit.started
        jobs.append(j)
        if j.kind == .trace { openJobTrace(j.id) }
    }

    var runningJobs: [ClaudeJob] { jobs.filter(\.running) }
    var unseenJobs: Int { jobs.filter(\.unseen).count }

    /// Opens the Claude pane with the question field focused.
    func openAsk() {
        showInspector = true
        inspectorPane = .claude
        askFocus += 1
    }

    func job(_ id: UUID) -> ClaudeJob? { jobs.first { $0.id == id } }

    func updateJob(_ id: UUID, _ f: (inout ClaudeJob) -> Void) {
        guard let i = jobs.firstIndex(where: { $0.id == id }) else { return }
        f(&jobs[i])
    }

    private func finishJob(_ id: UUID, _ f: (inout ClaudeJob) -> Void) {
        updateJob(id) {
            f(&$0)
            $0.running = false
            $0.finished = Date()
            $0.unseen = inspectorPane != .claude
        }
        jobTasks[id] = nil
        saveJobs()
    }

    func cancelJob(_ id: UUID) {
        jobTasks[id]?.cancel()
        jobTasks[id] = nil
        updateJob(id) { $0.running = false; $0.cancelled = true; $0.finished = Date() }
    }

    func removeJob(_ id: UUID) {
        cancelJob(id)
        jobs.removeAll { $0.id == id }
        saveJobs()
    }

    func clearFinishedJobs() { jobs.removeAll { !$0.running }; saveJobs() }

    func markJobsSeen() {
        for i in jobs.indices where jobs[i].unseen { jobs[i].unseen = false }
    }

    func ask(_ question: String, includeAnchor: Bool, force: Bool = false) {
        let anchor = includeAnchor ? anchorDescription() : nil
        let key = jobCacheKey(.ask, question, anchor)
        if !force, let hit = cachedJob(key) { replay(hit); return }
        var job = ClaudeJob(kind: .ask, question: question, anchor: anchor, model: ClaudeModels.label(Claude.model(for: .ask)))
        job.cacheKey = key
        let id = job.id
        jobs.append(job)
        var prompt = question
        if let anchor { prompt += "\n\nI am looking at \(anchor)." }
        if let r = review { prompt += "\n\nContext: I am reviewing \(r.title) (\(r.target.label))." }
        jobTasks[id] = Task {
            do {
                let res = try await Claude.run(prompt: prompt, system: ClaudeTasks.askSystem, cwd: root, task: .ask) { [weak self] ev in
                    Task { @MainActor in
                        self?.updateJob(id) { j in
                            switch ev {
                            case .toolUse(let n, let s): j.activity.append("\(n) \(s)")
                            case .text(let t): j.answer = t
                            }
                        }
                    }
                }
                finishJob(id) { $0.answer = res.text; $0.cost = res.costUSD }
            } catch {
                if Task.isCancelled { return }
                finishJob(id) { $0.error = error.localizedDescription }
            }
        }
    }

    /// Generates a code path from a question. When it lands, it opens only if the user is still where
    /// they started; otherwise it waits in the Claude pane and the path picker.
    func generateTrace(_ question: String, includeAnchor: Bool, force: Bool = false) {
        let anchor = includeAnchor ? anchorDescription() : nil
        let key = jobCacheKey(.trace, question, anchor)
        if !force, let hit = cachedJob(key) { replay(hit); return }
        var job = ClaudeJob(kind: .trace, question: question, anchor: anchor, model: ClaudeModels.label(Claude.model(for: .trace)))
        job.cacheKey = key
        let id = job.id
        jobs.append(job)
        let startPath = document?.path
        let startTrace = traces.activeID
        jobTasks[id] = Task {
            do {
                let res = try await Claude.run(prompt: ClaudeTasks.tracePrompt(question: question, anchor: anchor),
                                               system: ClaudeTasks.traceSystem, cwd: root, task: .trace, schema: ClaudeTasks.traceSchema) { [weak self] ev in
                    if case .toolUse(let n, let s) = ev {
                        Task { @MainActor in self?.updateJob(id) { $0.activity.append("\(n) \(s)") } }
                    }
                }
                let resp = try Claude.decode(ClaudeTasks.TraceResponse.self, from: res)
                let trace = ClaudeTasks.materialize(resp, question: question, docs: docs)
                let stayed = document?.path == startPath && traces.activeID == startTrace
                let previous = traces.activeID, previousStep = traces.currentStep
                traces.add(trace)
                finishJob(id) {
                    $0.traceID = trace.id
                    $0.cost = res.costUSD
                    $0.answer = String(format: "%d steps, %d verified", trace.steps.count, trace.steps.filter(\.verified).count)
                }
                if stayed {
                    playStep(0)
                } else {
                    traces.activeID = previous
                    traces.currentStep = previousStep
                    statusMessage = "Code path ready: \(trace.title)"
                }
            } catch {
                if Task.isCancelled { return }
                finishJob(id) { $0.error = error.localizedDescription }
            }
        }
    }

    func openJobTrace(_ id: UUID) {
        guard let tid = job(id)?.traceID, traces.traces.contains(where: { $0.id == tid }) else { return }
        traces.activeID = tid
        traces.currentStep = nil
        playStep(0)
    }
}
