import SwiftUI

struct SidebarView: View {
    @Bindable var ws: Workspace

    var body: some View {
        VStack(spacing: 0) {
            Picker("", selection: $ws.sidebarTab) {
                ForEach(SidebarTab.allCases) { t in Text(t.rawValue).tag(t) }
            }
            .pickerStyle(.segmented)
            .labelsHidden()
            .padding(8)
            switch ws.sidebarTab {
            case .changes:
                ReviewTabsView(ws: ws)
            case .files: FileTreeView(ws: ws)
            case .search: SearchView(ws: ws)
            case .scm: SCMView(ws: ws)
            }
        }
    }
}

struct FileTreeView: View {
    @Bindable var ws: Workspace
    @Environment(AppModel.self) var model
    @State private var filter = ""
    @State private var expanded: Set<String> = []
    @FocusState private var filterFocused: Bool

    var body: some View {
        VStack(spacing: 0) {
            HStack(spacing: 6) {
                TextField(ws.childRepos.isEmpty ? "Filter files" : "Filter repositories", text: $filter)
                    .textFieldStyle(.roundedBorder)
                    .focused($filterFocused)
                if !pathSteps.isEmpty {
                    Toggle("Path files", isOn: $ws.pathFilesOnly).toggleStyle(.button).controlSize(.small)
                        .help("Show only the files that hold steps of the open code path")
                }
            }
            .padding(.horizontal, 8).padding(.bottom, 6)
                .onChange(of: model.focusFilter) { filterFocused = true }
                .onSubmit {
                    if !ws.childRepos.isEmpty {
                        if let first = NotARepoView.filtered(ws.childRepos, filter).first { model.open(first) }
                    } else if let first = matches.first {
                        open(first)
                    }
                }
            if ws.loadingFiles {
                ProgressView("Listing files…").frame(maxWidth: .infinity, maxHeight: .infinity)
            } else if !ws.childRepos.isEmpty {
                NotARepoView(ws: ws, filter: filter)
            } else if ws.pathFilesOnly && !pathSteps.isEmpty && filter.isEmpty {
                List(selection: Binding(get: { ws.document?.path }, set: { if let p = $0 { open(p) } })) {
                    ForEach(pathSteps.keys.sorted { (pathSteps[$0]?.first ?? 0) < (pathSteps[$1]?.first ?? 0) }, id: \.self) { p in
                        HStack(spacing: 5) {
                            VStack(alignment: .leading, spacing: 1) {
                                Text(p.lastPathComponent)
                                Text(p.deletingLastPathComponent).font(.caption).foregroundStyle(.secondary).lineLimit(1).truncationMode(.head)
                            }
                            Spacer()
                            StepBadges(steps: pathSteps[p] ?? [], current: ws.traces.currentStep.map { $0 + 1 })
                        }
                        .tag(p)
                    }
                }
                .listStyle(.sidebar)
            } else if filter.isEmpty {
                List(selection: Binding(get: { ws.document?.path }, set: { p in if let p, !isDir(p) { open(p) } })) {
                    OutlineGroup(ws.tree.children ?? [], children: \.children) { node in
                        FileRow(node: node, changed: changedTier(node.path), steps: node.isDirectory ? [] : (pathSteps[node.path] ?? []),
                                currentStep: ws.traces.currentStep.map { $0 + 1 })
                            .tag(node.path)
                    }
                }
                .listStyle(.sidebar)
            } else {
                List(matches, id: \.self, selection: Binding(get: { ws.document?.path }, set: { if let p = $0 { open(p) } })) { p in
                    VStack(alignment: .leading, spacing: 1) {
                        Text(p.lastPathComponent)
                        Text(p.deletingLastPathComponent).font(.caption).foregroundStyle(.secondary).lineLimit(1).truncationMode(.head)
                    }.tag(p)
                }
                .listStyle(.sidebar)
            }
            Divider()
            HStack {
                if ws.pathFilesOnly && !pathSteps.isEmpty {
                    Text(verbatim: "Showing files on the path · \(pathSteps.count) files of \(ws.allFiles.count)").font(.caption).foregroundStyle(.secondary)
                } else {
                Text(verbatim: "\(ws.visibleFileCount) of \(ws.allFiles.count) files · \(ws.sourceOnly ? "Source only" : "All") · \(ws.showTests ? "Tests shown" : "Tests hidden")")
                    .font(.caption).foregroundStyle(.secondary).lineLimit(2)
                }
                Spacer()
                Menu {
                    Toggle("Source files only", isOn: $ws.sourceOnly)
                    Toggle("Show tests", isOn: $ws.showTests)
                } label: { Image(systemName: "line.3.horizontal.decrease.circle") }
                .menuStyle(.borderlessButton).fixedSize()
            }
            .padding(8)
        }
    }

    private func isDir(_ p: String) -> Bool { !ws.allFileSet.contains(p) }

    /// Step numbers (1-based) of the active code path, by file.
    var pathSteps: [String: [Int]] {
        guard let t = ws.traces.active else { return [:] }
        var out: [String: [Int]] = [:]
        for (i, s) in t.steps.enumerated() { out[s.location.path, default: []].append(i + 1) }
        return out
    }

    private func open(_ p: String) { ws.open(CodeLocation(path: p, range: SourceRange(line: 0))) }

    private func changedTier(_ path: String) -> ChangeTier? {
        guard let r = ws.review else { return nil }
        let fs = r.files.filter { $0.path == path || $0.path.hasPrefix(path + "/") }
        return fs.map(r.fileTier).min()
    }

    var matches: [String] {
        let q = filter.lowercased()
        let scored: [(String, Int)] = ws.allFiles.compactMap { p in
            guard let s = Fuzzy.score(q, p.lowercased()) else { return nil }
            return (p, s)
        }
        return scored.sorted { $0.1 > $1.1 }.prefix(200).map(\.0)
    }
}

enum Fuzzy {
    /// Space-separated fragments must appear in order. Each fragment prefers to start at a word
    /// boundary (after `/`, `_`, `-`, `.`), consecutive runs score more, and a last fragment that
    /// lands in the file name earns a bonus.
    static func score(_ q: String, _ s: String) -> Int? {
        let fragments = q.split(separator: " ").map { Array($0) }.filter { !$0.isEmpty }
        guard !fragments.isEmpty else { return 0 }
        let sa = Array(s)
        let nameStart = (sa.lastIndex(of: "/") ?? -1) + 1
        func isBoundary(_ i: Int) -> Bool { i == 0 || "/_-. ".contains(sa[i - 1]) }

        /// Greedy subsequence match of `frag` starting exactly at `start`; returns (score, end).
        func match(_ frag: [Character], from start: Int) -> (Int, Int)? {
            var qi = 0, i = start, score = 0, run = 0
            while i < sa.count && qi < frag.count {
                if sa[i] == frag[qi] {
                    run += 1
                    score += 1 + run * 2 + (i >= nameStart ? 3 : 0) + (isBoundary(i) ? 6 : 0)
                    qi += 1
                } else {
                    run = 0
                }
                i += 1
            }
            return qi == frag.count ? (score, i) : nil
        }

        var pos = 0, total = 0
        for (fi, frag) in fragments.enumerated() {
            var best: (Int, Int)?
            // Try boundary starts first; fall back to the earliest possible start.
            var i = pos
            while i < sa.count {
                if sa[i] == frag[0], isBoundary(i), let m = match(frag, from: i) {
                    if best == nil || m.0 > best!.0 { best = m }
                    if fi == fragments.count - 1 && i >= nameStart { break }
                }
                i += 1
            }
            if best == nil, let first = sa[pos...].firstIndex(of: frag[0]) { best = match(frag, from: first) }
            guard let (sc, end) = best else { return nil }
            total += sc
            if fi == fragments.count - 1 && end > nameStart && end - frag.count >= nameStart - 1 { total += 25 }
            pos = end
        }
        if fragments.count == 1, s.hasSuffix(String(fragments[0])) { total += 20 }
        return total - sa.count / 10
    }
}

struct NoReviewView: View {
    @Bindable var ws: Workspace
    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 10) {
                Text("No review open").font(.headline)
                Text("Pick a change to review. Hunks are sorted by importance; mechanical changes are hidden by default.")
                    .font(.caption).foregroundStyle(.secondary)
                ReviewPicker(ws: ws, dismiss: {})
                Button("Browse pull requests") { ws.sidebarTab = .scm; ws.scmSection = .pullRequests }
                    .buttonStyle(.link).disabled(!ws.vcs.hasGit)
            }
            .padding(10)
        }
    }
}

struct NotARepoView: View {
    @Bindable var ws: Workspace
    var filter: String
    @Environment(AppModel.self) var model

    /// Repositories matching the filter, best first; all of them, by name, when it is empty.
    static func filtered(_ repos: [URL], _ filter: String) -> [URL] {
        let q = filter.lowercased().trimmingCharacters(in: .whitespaces)
        let byName = repos.sorted { $0.lastPathComponent.localizedStandardCompare($1.lastPathComponent) == .orderedAscending }
        guard !q.isEmpty else { return byName }
        return byName.compactMap { u -> (URL, Int)? in Fuzzy.score(q, u.lastPathComponent.lowercased()).map { (u, $0) } }
            .sorted { $0.1 > $1.1 }.map(\.0)
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            Text("This folder is not a repository").font(.headline)
            if let p = ws.vcs.problem { Text(p).font(.caption).foregroundStyle(.secondary).lineLimit(3) }
            HStack {
                let shown = Self.filtered(ws.childRepos, filter)
                Text(filter.isEmpty ? "\(ws.childRepos.count) repositories inside:" : "\(shown.count) of \(ws.childRepos.count) repositories")
                    .font(.caption).foregroundStyle(.secondary)
                Spacer()
                Button("Browse files anyway") { ws.childRepos = [] }.controlSize(.small)
            }
            List(Self.filtered(ws.childRepos, filter), id: \.self) { u in
                Button { model.open(u) } label: { Label(u.lastPathComponent, systemImage: "shippingbox") }
                    .buttonStyle(.plain)
            }
            .listStyle(.sidebar)
        }
        .padding(.horizontal, 10)
    }
}

struct StepBadges: View {
    let steps: [Int]
    let current: Int?
    var body: some View {
        HStack(spacing: 2) {
            ForEach(steps.prefix(6), id: \.self) { n in
                Text(verbatim: String(n)).font(.system(size: 8.5, weight: .bold))
                    .frame(width: 14, height: 14)
                    .background(Circle().fill(n == current ? Color.purple : .clear))
                    .overlay(Circle().strokeBorder(Color.purple, lineWidth: 1))
                    .foregroundStyle(n == current ? .white : .purple)
            }
        }
    }
}

struct FileRow: View {
    let node: FileNode
    let changed: ChangeTier?
    var steps: [Int] = []
    var currentStep: Int?

    var body: some View {
        HStack(spacing: 5) {
            Image(systemName: node.isDirectory ? "folder" : icon)
                .foregroundStyle(node.isDirectory ? Color.accentColor : .secondary)
                .frame(width: 16)
            Text(node.name).lineLimit(1)
            Spacer()
            if !steps.isEmpty { StepBadges(steps: steps, current: currentStep) }
            if let changed { Circle().fill(changed.color).frame(width: 6, height: 6) }
        }
    }

    var icon: String {
        switch node.name.pathExtension {
        case "rs": "doc.text"
        case "toml", "lock": "gearshape"
        case "md": "doc.richtext"
        default: "doc"
        }
    }
}

struct SearchView: View {
    @Bindable var ws: Workspace
    @State private var query = ""
    @State private var regex = false
    @State private var word = false
    @State private var caseSensitive = false
    @State private var rustOnly = true
    @State private var results: [TextMatch] = []
    @State private var searching = false
    @State private var symbolMode = false
    @State private var task: Task<Void, Never>?

    var body: some View {
        VStack(spacing: 6) {
            TextField(symbolMode ? "Find definitions (fn, struct, trait…)" : "Search repository", text: $query)
                .textFieldStyle(.roundedBorder)
                .onSubmit(run)
                .padding(.horizontal, 8)
            HStack(spacing: 10) {
                Toggle(".*", isOn: $regex).help("Regular expression")
                Toggle("W", isOn: $word).help("Whole word")
                Toggle("Aa", isOn: $caseSensitive).help("Case sensitive")
                Toggle(".rs", isOn: $rustOnly).help("Rust files only")
                Toggle("Defs", isOn: $symbolMode).help("Definitions only")
                Spacer()
                if searching { ProgressView().controlSize(.small) }
            }
            .toggleStyle(.button).controlSize(.small).padding(.horizontal, 8)
            let grouped = Dictionary(grouping: results, by: \.path)
            List {
                ForEach(grouped.keys.sorted(), id: \.self) { path in
                    Section {
                        ForEach(grouped[path]!) { m in
                            Button { ws.open(m.location, edge: .manual) } label: {
                                HStack(alignment: .firstTextBaseline) {
                                    Text(verbatim: "\(m.line + 1)").font(.caption.monospacedDigit()).foregroundStyle(.secondary).frame(width: 36, alignment: .trailing)
                                    Text(m.text.trimmingCharacters(in: .whitespaces)).font(.system(size: 11, design: .monospaced)).lineLimit(1)
                                }
                            }.buttonStyle(.plain)
                        }
                    } header: {
                        Text(path).lineLimit(1).truncationMode(.head)
                    }
                }
            }
            .listStyle(.sidebar)
            Text(verbatim: "\(results.count) matches").font(.caption).foregroundStyle(.secondary).padding(.bottom, 6)
        }
    }

    private func run() {
        task?.cancel()
        searching = true
        var opts = TextSearch.Options()
        opts.regex = regex || symbolMode
        opts.wholeWord = word
        opts.caseSensitive = caseSensitive
        if rustOnly { opts.globs = ["*.rs"] }
        let q = symbolMode
            ? #"(fn|struct|enum|trait|type|const|static|mod|union|macro_rules!)\s+\w*"# + (regex ? query : NSRegularExpression.escapedPattern(for: query)) + #"\w*"#
            : query
        let root = ws.root
        task = Task {
            let r = (try? await TextSearch.search(root: root, query: q, options: opts)) ?? []
            if !Task.isCancelled { results = r; searching = false }
        }
    }
}
