import Foundation
import Observation

/// The Search tab: a ripgrep search over the working copy that reruns as the query or its options
/// change. Typing waits for a short pause; a search still running is cancelled by the next one.
@MainActor @Observable
final class SearchModel {
    let root: URL

    var query = "" { didSet { if query != oldValue { schedule() } } }
    var matchCase = false { didSet { if matchCase != oldValue { schedule(now: true) } } }
    var wholeWord = false { didSet { if wholeWord != oldValue { schedule(now: true) } } }
    var regex = false { didSet { if regex != oldValue { schedule(now: true) } } }
    var definitionsOnly = false { didSet { if definitionsOnly != oldValue { schedule(now: true) } } }
    /// Files to search, as comma- or space-separated globs: `*.rs`, `src/sys/`, `!tests/`. Empty: all
    /// files ripgrep does not ignore.
    var files = "" { didSet { if files != oldValue { schedule() } } }

    private(set) var groups: [Group] = []
    private(set) var matchCount = 0
    private(set) var truncated = false
    private(set) var error: String?
    private(set) var searching = false
    /// The query the results are for; empty before the first search.
    private(set) var searched = ""
    var collapsed: Set<String> = []
    /// Bumped to focus the query field.
    var focusRequest = 0

    struct Group: Identifiable {
        var path: String
        var matches: [TextMatch]
        var id: String { path }
    }

    @ObservationIgnored private var task: Task<Void, Never>?

    init(root: URL) { self.root = root }

    /// Queries shorter than this wait for Return, since they match nearly every line.
    static let minimumLength = 2
    static let typingDelay: Duration = .milliseconds(180)
    static let limit = 2000

    /// Runs the search after a typing pause, or at once.
    func schedule(now: Bool = false) {
        task?.cancel()
        guard query.count >= Self.minimumLength else {
            if query.isEmpty { clear() }
            searching = false
            return
        }
        start(after: now ? nil : Self.typingDelay)
    }

    /// Return in the query field: search now, whatever the length.
    func submit() {
        task?.cancel()
        guard !query.isEmpty else { clear(); return }
        start(after: nil)
    }

    func clear() {
        task?.cancel()
        groups = []
        matchCount = 0
        truncated = false
        error = nil
        searched = ""
        searching = false
    }

    private func start(after delay: Duration?) {
        searching = true
        let q = query
        let pattern = definitionsOnly ? Self.definitionPattern(q, regex: regex) : q
        var opts = TextSearch.Options()
        opts.regex = regex || definitionsOnly
        opts.wholeWord = wholeWord && !definitionsOnly
        opts.caseSensitive = matchCase
        opts.globs = Self.globs(files)
        opts.limit = Self.limit
        let root = root
        task = Task {
            if let delay { try? await Task.sleep(for: delay) }
            guard !Task.isCancelled else { return }
            let outcome = await TextSearch.run(root: root, query: pattern, options: opts)
            guard !Task.isCancelled else { return }
            apply(outcome, query: q)
        }
    }

    private func apply(_ o: TextSearch.Outcome, query q: String) {
        var order: [String] = []
        var byPath: [String: [TextMatch]] = [:]
        for m in o.matches {
            if byPath[m.path] == nil { order.append(m.path) }
            byPath[m.path, default: []].append(m)
        }
        groups = order.sorted().map { Group(path: $0, matches: byPath[$0]!.sorted { ($0.line, $0.col) < ($1.line, $1.col) }) }
        matchCount = o.matches.count
        truncated = o.truncated
        error = o.error
        searched = q
        searching = false
    }

    /// The declaration keywords of the languages Spelunk reads, followed by a name containing the query.
    static func definitionPattern(_ q: String, regex: Bool) -> String {
        let keywords = "fn|struct|enum|trait|type|const|static|mod|union|impl|macro_rules!|def|class|func|function|interface|protocol|extension|actor|theorem|lemma|structure|inductive|abbrev|instance"
        let name = regex ? q : NSRegularExpression.escapedPattern(for: q)
        return #"\b("# + keywords + #")\s+\w*"# + name + #"\w*"#
    }

    /// ripgrep globs from the files field. A folder (ending in `/`) means everything under it; `!`
    /// excludes.
    static func globs(_ field: String) -> [String] {
        field.split(whereSeparator: { $0 == "," || $0 == " " }).map(String.init).filter { !$0.isEmpty }.map { g in
            var g = g
            if g.hasSuffix("/") { g += "**" }
            return g
        }
    }
}
