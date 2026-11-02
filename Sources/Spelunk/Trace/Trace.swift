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
    var currentStep: Int?
    var isRecording = false
    private let url: URL

    init(root: URL) {
        url = AppPaths.support(for: root).appendingPathComponent("traces.json")
        if let d = try? Data(contentsOf: url) {
            let dec = JSONDecoder()
            dec.dateDecodingStrategy = .iso8601
            traces = (try? dec.decode([Trace].self, from: d)) ?? []
        }
        activeID = traces.first?.id
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

    func save() {
        let enc = JSONEncoder()
        enc.dateEncodingStrategy = .iso8601
        enc.outputFormatting = [.prettyPrinted]
        if let d = try? enc.encode(traces) { try? d.write(to: url, options: .atomic) }
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

    func record(_ step: TraceStep) {
        guard isRecording else { return }
        append(step)
    }

    func startRecording(from step: TraceStep?) {
        let t = create(title: step.map { "Trace from \($0.title)" } ?? "Recorded trace", origin: .recorded)
        isRecording = true
        if var s = step {
            s.edge = .start
            var tt = t
            tt.steps = [s]
            active = tt
            currentStep = 0
        }
    }

    func updateStep(_ id: UUID, _ change: (inout TraceStep) -> Void) {
        guard var t = active, let i = t.steps.firstIndex(where: { $0.id == id }) else { return }
        change(&t.steps[i])
        active = t
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
}

@MainActor @Observable
final class BookmarkStore {
    var items: [Bookmark] = []
    private let url: URL

    init(root: URL) {
        url = AppPaths.support(for: root).appendingPathComponent("bookmarks.json")
        if let d = try? Data(contentsOf: url) { items = (try? JSONDecoder().decode([Bookmark].self, from: d)) ?? [] }
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

    func contains(path: String, line: Int) -> Bool { items.contains { $0.location.path == path && $0.location.line == line } }

    private func save() { if let d = try? JSONEncoder().encode(items) { try? d.write(to: url, options: .atomic) } }
}
