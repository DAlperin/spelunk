import Foundation
import Observation

/// The Getting Started guide: a few things to try in a repository, each ticked off when the user
/// does it. Progress is kept across launches in the support folder. The guide opens by itself in
/// repository windows until it is finished or closed; Help › Getting Started brings it back.
@MainActor @Observable
final class Guide {
    static let shared = Guide()

    /// Things the user does that steps wait for.
    enum Event: String, Codable, CaseIterable {
        case openedFile, followedDefinition, wentBack, searched, steppedHunk, openedReview, closedReview, addedPathStep, openedPalette
    }

    struct Step: Identifiable {
        let id: String
        let title: String
        let detail: String
        let keys: [String]
        /// The step is done once all of these have happened.
        let events: [Event]
        var showMe: ShowMe?
    }

    /// A button that brings up the part of the window a step is about.
    struct ShowMe {
        let label: String
        var available: @MainActor (Workspace) -> Bool = { _ in true }
        let run: @MainActor (Workspace) -> Void
    }

    static let steps: [Step] = [
        Step(id: "open", title: "Open a file",
             detail: "Press ⌘K and type part of a file's name, or pick a file in the Files tab.",
             keys: ["⌘K"], events: [.openedFile],
             showMe: ShowMe(label: "Go to File") { $0.palette = .files }),
        Step(id: "definition", title: "Follow a name to its definition",
             detail: "⌘-click a function or type, or put the cursor on it and press ⇧⌘D. Then press ⌘[ to come back to where you were.",
             keys: ["⌘-click", "⇧⌘D", "⌘["], events: [.followedDefinition, .wentBack]),
        Step(id: "search", title: "Search the repository",
             detail: "Results update as you type. The line under the query limits the files searched, for example *.rs or src/.",
             keys: ["⇧⌘F"], events: [.searched],
             showMe: ShowMe(label: "Open Search") { $0.findInRepository() }),
        Step(id: "hunks", title: "Step through your changes",
             detail: "The Review tab lists what changed in the working copy, most important first. J and K move from hunk to hunk, and the editor shows each one as a diff.",
             keys: ["J", "K"], events: [.steppedHunk],
             showMe: ShowMe(label: "Open Review") { $0.sidebarTab = .changes }),
        Step(id: "review", title: "Review another change",
             detail: "In the History tab, select a change and click Review. That review stays on the change you picked while you keep working. The chip above the editor says which version of the file is open.",
             keys: [], events: [.openedReview],
             showMe: ShowMe(label: "Open History") { $0.sidebarTab = .scm }),
        Step(id: "close", title: "Go back to the working copy",
             detail: "⌥⌘W, or the × next to the review's name in the toolbar, closes the review and reopens the file as it is on disk.",
             keys: ["⌥⌘W"], events: [.closedReview],
             showMe: ShowMe(label: "Close Review", available: { $0.activeReviewKey != nil }) { $0.closeActiveReview() }),
        Step(id: "path", title: "Record a code path",
             detail: "A code path is a list of locations, each with a note, for following a flow through the code. ⇧⌘T adds the cursor's location; ⌥] and ⌥[ step through the path.",
             keys: ["⇧⌘T", "⌥]", "⌥["], events: [.addedPathStep],
             showMe: ShowMe(label: "Open Code Paths") { ws in ws.inspectorPane = .paths; ws.showInspector = true }),
        Step(id: "palette", title: "Find any command",
             detail: "⇧⌘K opens the command palette. It lists every command, with its shortcut.",
             keys: ["⇧⌘K"], events: [.openedPalette],
             showMe: ShowMe(label: "Open Palette") { $0.palette = .commands }),
    ]

    private(set) var events: Set<Event> = []
    private(set) var skipped: Set<String> = []
    /// Closed by the user; it stays closed until reopened from the Help menu.
    private(set) var closed = false
    /// Showing in repository windows.
    private(set) var visible = false
    /// Folded down to its title bar.
    var collapsed = false
    /// The step picked from the list, shown instead of the first one left to do.
    var picked: String?
    /// The title of the step just done, shown for a moment.
    private(set) var justDone: String?

    @ObservationIgnored private var doneTask: Task<Void, Never>?
    @ObservationIgnored private let file: URL

    init(file: URL = AppPaths.base.appendingPathComponent("guide.json")) {
        self.file = file
        if let data = try? Data(contentsOf: file), let s = try? JSONDecoder().decode(Saved.self, from: data) {
            events = Set(s.events)
            skipped = Set(s.skipped)
            closed = s.closed
        }
    }

    private struct Saved: Codable {
        var events: [Event]
        var skipped: [String]
        var closed: Bool
    }

    private func save() {
        let s = Saved(events: events.sorted { $0.rawValue < $1.rawValue }, skipped: skipped.sorted(), closed: closed)
        try? FileManager.default.createDirectory(at: file.deletingLastPathComponent(), withIntermediateDirectories: true)
        try? JSONEncoder().encode(s).write(to: file, options: .atomic)
    }

    func isDone(_ s: Step) -> Bool { skipped.contains(s.id) || s.events.allSatisfy(events.contains) }
    var doneCount: Int { Self.steps.filter(isDone).count }
    var finished: Bool { doneCount == Self.steps.count }
    /// The step the card shows.
    var focus: Step? { Self.steps.first { $0.id == picked } ?? Self.steps.first { !isDone($0) } }

    func note(_ e: Event) {
        guard !events.contains(e) else { return }
        let before = Set(Self.steps.filter(isDone).map(\.id))
        events.insert(e)
        save()
        guard let step = Self.steps.first(where: { isDone($0) && !before.contains($0.id) }) else { return }
        if picked == step.id { picked = nil }
        guard visible else { return }
        justDone = step.title
        doneTask?.cancel()
        doneTask = Task {
            try? await Task.sleep(for: .seconds(2.5))
            guard !Task.isCancelled else { return }
            justDone = nil
        }
    }

    func skip(_ s: Step) {
        skipped.insert(s.id)
        if picked == s.id { picked = nil }
        save()
    }

    /// A repository window opened: the guide shows unless it was closed or is finished.
    func windowOpened() {
        if !closed && !finished { visible = true }
    }

    func show() {
        visible = true
        collapsed = false
        if closed { closed = false; save() }
    }

    func close() {
        visible = false
        picked = nil
        closed = true
        save()
    }

    func restart() {
        events = []
        skipped = []
        picked = nil
        justDone = nil
        closed = false
        visible = true
        collapsed = false
        save()
    }
}
