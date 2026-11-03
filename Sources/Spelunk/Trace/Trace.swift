import Foundation
import Observation

enum TraceEdge: String, Codable, Sendable {
    case start, definition, reference, caller, callee, implementation, manual, claude

    var label: String {
        switch self {
        case .start: "start"
        case .definition: "go to definition"
        case .reference: "reference"
        case .caller: "called from"
        case .callee: "calls"
        case .implementation: "implementation"
        case .manual: "added"
        case .claude: "Claude"
        }
    }

    var glyph: String {
        switch self {
        case .start: "circle.fill"
        case .definition: "arrow.right"
        case .reference: "arrow.turn.down.right"
        case .caller: "arrow.uturn.left"
        case .callee: "arrow.down.right"
        case .implementation: "square.stack.3d.up"
        case .manual: "plus"
        case .claude: "sparkles"
        }
    }
}

struct TraceStep: Codable, Identifiable, Hashable, Sendable {
    var id = UUID()
    var title: String
    var location: CodeLocation
    var note: String = ""
    var edge: TraceEdge
    var source: IntelSource
    /// False when an LLM-proposed step could not be matched to a real symbol in the file.
    var verified: Bool = true
    var snippet: String = ""
    /// Finds the step again after its file changes.
    var anchor: CodeAnchor?
}

struct Trace: Codable, Identifiable, Hashable, Sendable {
    enum Origin: String, Codable, Sendable { case recorded, manual, claude }
    var id = UUID()
    var title: String
    var question: String?
    var summary: String?
    var origin: Origin
    var steps: [TraceStep] = []
    var created = Date()
    var updated = Date()

    /// The plain-text form: the title, then one `file:symbol:note` line per step, with `\` and `:`
    /// escaped in the file and symbol fields. Steps carry no line numbers; they are found again by
    /// symbol, so other tools (Claude Code in a terminal, a script) can write paths Spelunk opens.
    func plainText() -> String {
        func esc(_ s: String) -> String { s.replacingOccurrences(of: "\\", with: "\\\\").replacingOccurrences(of: ":", with: "\\:") }
        var lines = [title]
        for s in steps {
            let note = s.note.replacingOccurrences(of: "\n", with: " ")
            lines.append("\(esc(s.location.path)):\(esc(s.title)):\(note)")
        }
        return lines.joined(separator: "\n") + "\n"
    }

    /// Reads `plainText()`'s format: nil without a title and at least one well-formed step.
    static func parsePlainText(_ text: String) -> (title: String, steps: [(file: String, symbol: String, note: String)])? {
        var lines = text.split(separator: "\n", omittingEmptySubsequences: true).map { $0.trimmingCharacters(in: .whitespaces) }.filter { !$0.isEmpty }
        guard !lines.isEmpty else { return nil }
        let title = lines.removeFirst()
        var steps: [(String, String, String)] = []
        for line in lines {
            // Split on the first two unescaped colons; the note keeps any colons it has.
            var fields: [String] = [], cur = "", escaped = false
            for ch in line {
                if fields.count == 2 { cur.append(ch); continue }
                if escaped { cur.append(ch); escaped = false } else if ch == "\\" { escaped = true } else if ch == ":" { fields.append(cur); cur = "" } else { cur.append(ch) }
            }
            fields.append(cur)
            guard fields.count == 3, !fields[0].isEmpty, !fields[1].isEmpty else { continue }
            steps.append((fields[0], fields[1], fields[2].trimmingCharacters(in: .whitespaces)))
        }
        return steps.isEmpty ? nil : (title, steps)
    }

    func markdown() -> String {
        var s = "# \(title)\n\n"
        if let q = question { s += "> \(q)\n\n" }
        if let sum = summary, !sum.isEmpty { s += "\(sum)\n\n" }
        for (i, st) in steps.enumerated() {
            s += "\(i + 1). **\(st.title)** — `\(st.location.path):\(st.location.displayLine)`"
            if st.edge != .start && st.edge != .claude { s += " _(\(st.edge.label))_" }
            s += "\n"
            if !st.note.isEmpty { s += "   \(st.note.replacingOccurrences(of: "\n", with: "\n   "))\n" }
        }
        return s
    }
}

@MainActor @Observable
final class TraceStore {
    var traces: [Trace] = []
    var activeID: UUID?
    /// The step being shown, by identity, so reordering or switching paths cannot point it elsewhere.
    var currentStepID: UUID?
    /// Index of the current step in the active path; nil when it is not in that path.
    var currentStep: Int? {
        get { currentStepID.flatMap { id in active?.steps.firstIndex { $0.id == id } } }
        set { currentStepID = newValue.flatMap { active?.steps[safe: $0]?.id } }
    }
    @ObservationIgnored private let sync: ItemSync<Trace>

    init(root: URL) {
        sync = ItemSync(kind: "trace", root: root, legacyFile: "traces.json")
        Task {
            let loaded = await sync.load()
            traces = loaded + traces.filter { t in !loaded.contains { $0.id == t.id } }
            if activeID == nil { activeID = traces.first?.id }
        }
    }

    var active: Trace? {
        get { traces.first { $0.id == activeID } }
        set {
            guard let newValue, let i = traces.firstIndex(where: { $0.id == newValue.id }) else { return }
            traces[i] = newValue
            traces[i].updated = Date()
            save()
        }
    }

    /// Coalesces bursts of edits (typing a note) into one write.
    func save() {
        pendingSave?.cancel()
        pendingSave = Task {
            try? await Task.sleep(for: .milliseconds(400))
            guard !Task.isCancelled else { return }
            writeNow()
        }
    }

    @ObservationIgnored private var pendingSave: Task<Void, Never>?

    func writeNow() {
        pendingSave?.cancel()
        sync.sync(traces)
    }

    @discardableResult
    func create(title: String, origin: Trace.Origin, question: String? = nil) -> Trace {
        let t = Trace(title: title, question: question, origin: origin)
        traces.insert(t, at: 0)
        activeID = t.id
        currentStep = nil
        save()
        return t
    }

    func add(_ t: Trace) {
        traces.insert(t, at: 0)
        activeID = t.id
        currentStep = t.steps.isEmpty ? nil : 0
        save()
    }

    func delete(_ id: UUID) {
        traces.removeAll { $0.id == id }
        if activeID == id { activeID = traces.first?.id; currentStep = nil }
        save()
    }

    /// Appends to the active trace, creating a recorded trace if none is active.
    func append(_ step: TraceStep) {
        if active == nil { create(title: "Trace from \(step.title)", origin: .recorded) }
        guard var t = active else { return }
        if let last = t.steps.last, last.location.path == step.location.path, last.location.line == step.location.line { return }
        t.steps.append(step)
        active = t
        currentStep = t.steps.count - 1
    }

    /// Inserts after the current step (or at the end) and makes the new step current.
    func insert(_ step: TraceStep) {
        if active == nil { create(title: "Untitled path", origin: .manual) }
        guard var t = active else { return }
        let at = currentStep.map { min($0 + 1, t.steps.count) } ?? t.steps.count
        t.steps.insert(step, at: at)
        active = t
        currentStep = at
    }

    func rename(_ title: String) {
        guard var t = active else { return }
        t.title = title
        active = t
    }

    func duplicateActive() {
        guard var t = active else { return }
        t.id = UUID()
        t.title += " copy"
        t.steps = t.steps.map { var s = $0; s.id = UUID(); return s }
        t.created = Date()
        add(t)
    }

    func moveStep(_ id: UUID, by delta: Int) {
        guard var t = active, let i = t.steps.firstIndex(where: { $0.id == id }) else { return }
        let j = i + delta
        guard j >= 0, j < t.steps.count else { return }
        t.steps.swapAt(i, j)
        active = t
        if currentStep == i { currentStep = j }
    }

    func updateStep(_ id: UUID, _ change: (inout TraceStep) -> Void) {
        guard var t = active, let i = t.steps.firstIndex(where: { $0.id == id }) else { return }
        change(&t.steps[i])
        active = t
    }

    /// Applies `change` to every step of every path; saves when any step changed.
    func updateAllSteps(_ change: (inout TraceStep) -> Void) {
        var changed = false
        for i in traces.indices {
            for j in traces[i].steps.indices {
                let before = traces[i].steps[j]
                change(&traces[i].steps[j])
                if traces[i].steps[j] != before { changed = true }
            }
        }
        if changed { save() }
    }

    func removeStep(_ id: UUID) {
        guard var t = active else { return }
        t.steps.removeAll { $0.id == id }
        active = t
        if let c = currentStep, c >= t.steps.count { currentStep = t.steps.isEmpty ? nil : t.steps.count - 1 }
    }

    func moveSteps(from: IndexSet, to: Int) {
        guard var t = active else { return }
        t.steps.move(fromOffsets: from, toOffset: to)
        active = t
    }
}

/// Bookmarked locations, per repository.
struct Bookmark: Codable, Identifiable, Hashable, Sendable {
    var id = UUID()
    var title: String
    var location: CodeLocation
    var context: String
    /// Finds the bookmark again after its file changes.
    var anchor: CodeAnchor?
}

@MainActor @Observable
final class BookmarkStore {
    var items: [Bookmark] = []
    @ObservationIgnored private let sync: ItemSync<Bookmark>

    init(root: URL) {
        sync = ItemSync(kind: "bookmark", root: root, legacyFile: "bookmarks.json")
        Task {
            let loaded = await sync.load()
            items = items + loaded.filter { b in !items.contains { $0.id == b.id } }
        }
    }

    func toggle(_ b: Bookmark) {
        if let i = items.firstIndex(where: { $0.location.path == b.location.path && $0.location.line == b.location.line }) {
            items.remove(at: i)
        } else {
            items.insert(b, at: 0)
        }
        save()
    }

    func remove(_ id: UUID) { items.removeAll { $0.id == id }; save() }

    /// Applies `change` to every bookmark; saves when any changed.
    func updateAll(_ change: (inout Bookmark) -> Void) {
        let before = items
        for i in items.indices { change(&items[i]) }
        if items != before { save() }
    }

    func contains(path: String, line: Int) -> Bool { items.contains { $0.location.path == path && $0.location.line == line } }

    private func save() { sync.sync(items) }
}
