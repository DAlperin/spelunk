import SwiftUI

struct SidebarView: View {
    @Bindable var ws: Workspace
    @Environment(AppModel.self) var model

    var body: some View {
        VStack(spacing: 0) {
            Picker("", selection: $ws.sidebarTab) {
                ForEach(SidebarTab.allCases) { t in Text(t.rawValue).tag(t) }
            }
            .pickerStyle(.segmented)
            .labelsHidden()
            .padding(8)
            KeptTabs(selection: ws.sidebarTab, owner: ws, model: model) { [ws] tab in
                // Content that does not fill the column stays at the top instead of centering.
                AnyView(Self.content(tab, ws).frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .top))
            }
        }
        .frame(maxHeight: .infinity, alignment: .top)
    }

    @ViewBuilder static func content(_ tab: SidebarTab, _ ws: Workspace) -> some View {
        switch tab {
        case .changes: ReviewTabsView(ws: ws)
        case .files: FileTreeView(ws: ws)
        case .search: SearchView(ws: ws)
        case .scm: SCMView(ws: ws)
        }
    }
}

struct FileTreeView: View {
    @Bindable var ws: Workspace
    @Environment(AppModel.self) var model
    @State private var filter = ""
    @FocusState private var filterFocused: Bool
    @AppStorage(Prefs.Key.followFile) private var follow = true

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
                if ws.childRepos.isEmpty {
                    Toggle(isOn: $follow) { Image(systemName: "scope") }
                        .toggleStyle(.button).controlSize(.small)
                        .help(follow ? "Following the open file: the tree expands to it and selects it. Click to stop." : "Follow the open file: expand the tree to it and select it")
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
                FileOutline(root: ws.tree, expanded: ws.treeExpanded, selectedPath: ws.document?.path, tiers: tiers,
                            steps: pathSteps, currentStep: ws.traces.currentStep.map { $0 + 1 },
                            follow: follow, revealRequested: ws.revealInTreePending,
                            setExpanded: { [ws] path, open in if open { ws.treeExpanded.insert(path) } else { ws.treeExpanded.remove(path) } },
                            open: { open($0) },
                            didReveal: { [ws] in ws.revealInTreePending = false })
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

    private func open(_ p: String) { ws.open(CodeLocation(path: p, range: SourceRange(line: 0)), reason: .browse) }

    /// Review tier of each changed file, and of each folder the most important tier inside it.
    private var tiers: [String: ChangeTier] {
        guard let r = ws.review else { return [:] }
        var out: [String: ChangeTier] = [:]
        for f in r.files {
            let t = r.fileTier(f)
            var p = f.path
            while !p.isEmpty {
                out[p] = min(out[p] ?? t, t)
                p = p.deletingLastPathComponent
            }
        }
        return out
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

struct SearchView: View {
    @Bindable var ws: Workspace
    @FocusState private var queryFocused: Bool

    private var search: SearchModel { ws.search }

    var body: some View {
        @Bindable var search = ws.search
        VStack(spacing: 0) {
            VStack(spacing: 6) {
                HStack(spacing: 4) {
                    Image(systemName: "magnifyingglass").foregroundStyle(.secondary).font(.system(size: 11))
                    TextField(search.definitionsOnly ? "Find definitions" : "Search the working copy", text: $search.query)
                        .textFieldStyle(.plain)
                        .focused($queryFocused)
                        .onSubmit { search.submit() }
                        .onKeyPress(.escape) { search.query = ""; return .handled }
                    if search.searching {
                        ProgressView().controlSize(.mini)
                    } else if !search.query.isEmpty {
                        Button { search.query = "" } label: { Image(systemName: "xmark.circle.fill") }
                            .buttonStyle(.borderless).foregroundStyle(.secondary).help("Clear")
                    }
                    OptionToggle(label: "Aa", help: "Match case", isOn: $search.matchCase)
                    OptionToggle(label: "ab", help: "Whole word", isOn: $search.wholeWord, underline: true)
                    OptionToggle(label: ".*", help: "Regular expression", isOn: $search.regex)
                }
                .padding(.horizontal, 7).padding(.vertical, 5)
                .background(RoundedRectangle(cornerRadius: 6).fill(Color(nsColor: .textBackgroundColor)))
                .overlay(RoundedRectangle(cornerRadius: 6).strokeBorder(queryFocused ? Color.accentColor.opacity(0.7) : Color.secondary.opacity(0.25)))
                .background(FocusRequest(request: search.focusRequest))
                HStack(spacing: 4) {
                    Image(systemName: "doc.text.magnifyingglass").foregroundStyle(.secondary).font(.system(size: 10))
                    TextField("Files: *.rs, src/sys/, !tests/", text: $search.files)
                        .textFieldStyle(.plain).font(.system(size: 11))
                        .help("Comma- or space-separated globs. A folder ends in /, and ! excludes. Empty searches every file not ignored by .gitignore.")
                    Toggle("Definitions", isOn: $search.definitionsOnly)
                        .toggleStyle(.button).controlSize(.mini)
                        .help("Only lines that declare a name containing the query (fn, struct, class, def, theorem, …)")
                }
                .padding(.horizontal, 7).padding(.vertical, 3)
                .background(RoundedRectangle(cornerRadius: 6).fill(Color.secondary.opacity(0.07)))
            }
            .padding(.horizontal, 8).padding(.top, 2).padding(.bottom, 6)
            Divider()
            content
        }
    }

    @ViewBuilder private var content: some View {
        if let e = search.error {
            SidebarMessage(icon: "exclamationmark.triangle", title: "Search failed", detail: e) { EmptyView() }
        } else if search.searched.isEmpty {
            if search.query.isEmpty {
                SidebarMessage(icon: "magnifyingglass", title: "Search the working copy",
                               detail: "Results update as you type. Files ignored by .gitignore are skipped.") { EmptyView() }
            } else if search.query.count < SearchModel.minimumLength {
                SidebarMessage(icon: "return", title: "Press Return to search for one character", detail: nil) { EmptyView() }
            } else {
                Spacer()
            }
        } else if search.groups.isEmpty {
            SidebarMessage(icon: "magnifyingglass", title: "No matches", detail: noMatchesHint) { EmptyView() }
        } else {
            summary
            results
        }
    }

    private var noMatchesHint: String? {
        var hints: [String] = []
        if !search.files.isEmpty { hints.append("only files matching \(search.files)") }
        if search.matchCase { hints.append("matching case") }
        if search.wholeWord { hints.append("whole words") }
        if search.definitionsOnly { hints.append("definitions only") }
        return hints.isEmpty ? nil : "Searched " + hints.joined(separator: ", ") + "."
    }

    private var summary: some View {
        HStack(spacing: 6) {
            Text(verbatim: "\(search.matchCount) match\(search.matchCount == 1 ? "" : "es") in \(search.groups.count) file\(search.groups.count == 1 ? "" : "s")"
                 + (search.truncated ? " · first \(SearchModel.limit) shown" : ""))
            Spacer()
            let allCollapsed = search.collapsed.count == search.groups.count
            Button(allCollapsed ? "Expand All" : "Collapse All") {
                search.collapsed = allCollapsed ? [] : Set(search.groups.map(\.path))
            }
            .buttonStyle(.link)
        }
        .font(.caption).foregroundStyle(.secondary)
        .padding(.horizontal, 10).padding(.vertical, 5)
    }

    private var results: some View {
        ScrollView {
            LazyVStack(alignment: .leading, spacing: 0, pinnedViews: [.sectionHeaders]) {
                ForEach(search.groups) { g in
                    Section {
                        if !search.collapsed.contains(g.path) {
                            ForEach(g.matches) { m in
                                Button { ws.open(m.location, edge: .manual, reason: .browse) } label: { MatchRow(match: m) }
                                    .buttonStyle(.plain)
                            }
                        }
                    } header: {
                        FileHeader(group: g, collapsed: search.collapsed.contains(g.path)) {
                            if search.collapsed.contains(g.path) { search.collapsed.remove(g.path) } else { search.collapsed.insert(g.path) }
                        }
                    }
                }
            }
            .padding(.bottom, 8)
        }
    }
}

/// A search option as a small toggle inside the query field.
private struct OptionToggle: View {
    let label: String
    let help: String
    @Binding var isOn: Bool
    var underline = false

    var body: some View {
        Button { isOn.toggle() } label: {
            Text(label).underline(underline)
                .font(.system(size: 11, weight: .semibold, design: .monospaced))
                .frame(width: 22, height: 18)
                .foregroundStyle(isOn ? Color.white : Color.secondary)
                .background(RoundedRectangle(cornerRadius: 4).fill(isOn ? Color.accentColor : Color.clear))
        }
        .buttonStyle(.plain)
        .help(help + (isOn ? " (on)" : ""))
    }
}

private struct FileHeader: View {
    let group: SearchModel.Group
    let collapsed: Bool
    let toggle: () -> Void

    var body: some View {
        Button(action: toggle) {
            HStack(spacing: 5) {
                Image(systemName: collapsed ? "chevron.right" : "chevron.down").font(.system(size: 9, weight: .semibold)).foregroundStyle(.secondary).frame(width: 10)
                Text(group.path.lastPathComponent).fontWeight(.semibold).lineLimit(1)
                let dir = (group.path as NSString).deletingLastPathComponent
                if !dir.isEmpty { Text(dir).foregroundStyle(.secondary).lineLimit(1).truncationMode(.head) }
                Spacer(minLength: 4)
                Text(verbatim: "\(group.matches.count)").font(.caption2.monospacedDigit()).foregroundStyle(.secondary)
                    .padding(.horizontal, 5).padding(.vertical, 1)
                    .background(Capsule().fill(Color.secondary.opacity(0.15)))
            }
            .font(.system(size: 12))
            .padding(.horizontal, 8).padding(.vertical, 4)
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .background(.bar)
        .help(group.path)
    }
}

/// One matching line: its number and the line's text with the match highlighted, scrolled so the
/// match stays visible in a narrow sidebar.
private struct MatchRow: View {
    let match: TextMatch
    @State private var hover = false

    var body: some View {
        HStack(alignment: .firstTextBaseline, spacing: 6) {
            Text(verbatim: "\(match.line + 1)").font(.system(size: 10).monospacedDigit()).foregroundStyle(.tertiary)
                .frame(width: 34, alignment: .trailing)
            Text(snippet).font(.system(size: 11, design: .monospaced)).lineLimit(1)
        }
        .padding(.vertical, 2).padding(.trailing, 8)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(hover ? Color.accentColor.opacity(0.1) : .clear)
        .contentShape(Rectangle())
        .onHover { hover = $0 }
    }

    private var snippet: AttributedString {
        let ns = match.text as NSString
        var start = 0
        while start < ns.length, [32, 9].contains(ns.character(at: start)) { start += 1 }
        // Keep the match in view: show up to 24 characters before it.
        if match.col - start > 30 { start = match.col - 24 }
        let lead = start > 0 && start > leadingSpaces(ns) ? "…" : ""
        let col = max(0, min(match.col, ns.length))
        let end = max(col, min(col + match.length, ns.length))
        var out = AttributedString(lead + ns.substring(with: NSRange(location: start, length: max(0, col - start))))
        var hit = AttributedString(ns.substring(with: NSRange(location: col, length: end - col)))
        hit.backgroundColor = Color.yellow.opacity(0.35)
        hit.inlinePresentationIntent = .stronglyEmphasized
        out += hit
        out += AttributedString(ns.substring(from: end))
        return out
    }

    private func leadingSpaces(_ ns: NSString) -> Int {
        var i = 0
        while i < ns.length, [32, 9].contains(ns.character(at: i)) { i += 1 }
        return i
    }
}
