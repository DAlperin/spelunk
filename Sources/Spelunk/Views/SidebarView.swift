import SwiftUI

struct SidebarView: View {
    @Bindable var ws: Workspace

    var body: some View {
        VStack(spacing: 0) {
            Picker("", selection: $ws.sidebarTab) {
                ForEach(SidebarTab.allCases) { t in
                    if t != .changes || ws.review != nil { Text(t.rawValue).tag(t) }
                }
            }
            .pickerStyle(.segmented)
            .labelsHidden()
            .padding(8)
            switch ws.sidebarTab {
            case .changes:
                if let r = ws.review { ChangesView(ws: ws, review: r) } else { FileTreeView(ws: ws) }
            case .files: FileTreeView(ws: ws)
            case .search: SearchView(ws: ws)
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
            TextField("Filter files", text: $filter)
                .textFieldStyle(.roundedBorder)
                .focused($filterFocused)
                .padding(.horizontal, 8).padding(.bottom, 6)
                .onChange(of: model.focusFilter) { filterFocused = true }
                .onSubmit { if let first = matches.first { open(first) } }
            if filter.isEmpty {
                List(selection: Binding(get: { ws.document?.path }, set: { p in if let p, !isDir(p) { open(p) } })) {
                    OutlineGroup(ws.tree.children ?? [], children: \.children) { node in
                        FileRow(node: node, changed: changedTier(node.path))
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
                Text("\(ws.visibleFileCount) of \(ws.allFiles.count) files · \(ws.sourceOnly ? "Source only" : "All") · \(ws.showTests ? "Tests shown" : "Tests hidden")")
                    .font(.caption).foregroundStyle(.secondary).lineLimit(2)
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

    private func isDir(_ p: String) -> Bool { !ws.allFiles.contains(p) }

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
    /// Subsequence match; rewards matches in the file name and consecutive runs.
    static func score(_ q: String, _ s: String) -> Int? {
        guard !q.isEmpty else { return 0 }
        let qa = Array(q), sa = Array(s)
        let nameStart = (s.lastIndex(of: "/").map { s.distance(from: s.startIndex, to: $0) } ?? -1) + 1
        var qi = 0, score = 0, run = 0
        for (i, c) in sa.enumerated() where qi < qa.count {
            if c == qa[qi] {
                qi += 1; run += 1
                score += 1 + run * 2 + (i >= nameStart ? 3 : 0)
            } else { run = 0 }
        }
        guard qi == qa.count else { return nil }
        if s.hasSuffix(q) { score += 20 }
        return score - sa.count / 10
    }
}

struct FileRow: View {
    let node: FileNode
    let changed: ChangeTier?

    var body: some View {
        HStack(spacing: 5) {
            Image(systemName: node.isDirectory ? "folder" : icon)
                .foregroundStyle(node.isDirectory ? Color.accentColor : .secondary)
                .frame(width: 16)
            Text(node.name).lineLimit(1)
            Spacer()
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
                                    Text("\(m.line + 1)").font(.caption.monospacedDigit()).foregroundStyle(.secondary).frame(width: 36, alignment: .trailing)
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
            Text("\(results.count) matches").font(.caption).foregroundStyle(.secondary).padding(.bottom, 6)
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
