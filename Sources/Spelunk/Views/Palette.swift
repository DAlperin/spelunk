import AppKit
import SwiftUI

enum PaletteMode: Equatable { case files, commands }

struct PaletteItem: Identifiable {
    let id: String
    var title: String
    var subtitle: String?
    var detail: String?
    var icon: String
    var action: @MainActor () -> Void
}

/// ⌘K file switcher and ⇧⌘K command palette.
///
/// File mode prefixes: `@name` for symbols in the current file, `#name` for workspace symbols,
/// and `path:line` to jump to a line.
struct PaletteView: View {
    @Bindable var ws: Workspace
    let mode: PaletteMode
    @Environment(AppModel.self) private var model
    @Environment(\.openSettings) private var openSettings
    @State private var selection = 0
    @State private var symbolResults: [PaletteItem] = []
    @State private var symbolTask: Task<Void, Never>?
    @FocusState private var focused: Bool

    private var query: String { ws.paletteQuery }

    var body: some View {
        VStack(spacing: 0) {
            HStack(spacing: 8) {
                Image(systemName: mode == .files ? "doc.text.magnifyingglass" : "command").foregroundStyle(.secondary)
                TextField(mode == .files ? "Go to file   (@ symbol in file, # workspace symbol, :line)" : "Run a command",
                          text: $ws.paletteQuery)
                    .textFieldStyle(.plain)
                    .font(.system(size: 16))
                    .focused($focused)
                    .onSubmit(run)
                    .onKeyPress(.downArrow) { move(1); return .handled }
                    .onKeyPress(.upArrow) { move(-1); return .handled }
                    .onKeyPress(.escape) { ws.palette = nil; return .handled }
                Text(mode == .files ? "⌘K" : "⇧⌘K").font(.caption).foregroundStyle(.tertiary)
            }
            .padding(12)
            Divider()
            let list = items
            ScrollViewReader { proxy in
                ScrollView {
                    LazyVStack(alignment: .leading, spacing: 0) {
                        ForEach(list.indices, id: \.self) { i in
                            row(list[i], selected: i == selection)
                                .contentShape(Rectangle())
                                .onTapGesture { selection = i; run() }
                        }
                        if list.isEmpty {
                            Text(emptyText).font(.callout).foregroundStyle(.secondary).padding(12)
                        }
                    }
                    .id(ws.paletteQuery + (mode == .files ? "f" : "c") + "\(symbolResults.count)")
                }
                .frame(maxHeight: 380)
                .onChange(of: selection) { proxy.scrollTo(selection, anchor: .center) }
            }
        }
        .frame(width: 640)
        .background(.regularMaterial, in: RoundedRectangle(cornerRadius: 12))
        .overlay(RoundedRectangle(cornerRadius: 12).strokeBorder(Color.secondary.opacity(0.25)))
        .shadow(color: .black.opacity(0.25), radius: 24, y: 8)
        .onAppear { focused = true }
        .onChange(of: ws.paletteQuery) {
            selection = 0
            if mode == .files && query.hasPrefix("#") { searchWorkspaceSymbols() }
        }
    }

    private var emptyText: String {
        if mode == .files && query.hasPrefix("#") {
            return ws.ra.status.isUsable ? "Type a symbol name" : "Workspace symbols need rust-analyzer (\(ws.ra.status.label.lowercased()))"
        }
        return "No matches"
    }

    @ViewBuilder
    private func row(_ item: PaletteItem, selected: Bool) -> some View {
        HStack(spacing: 10) {
            Image(systemName: item.icon).frame(width: 18).foregroundStyle(selected ? .white : .secondary)
            VStack(alignment: .leading, spacing: 1) {
                Text(item.title).lineLimit(1)
                if let s = item.subtitle {
                    Text(s).font(.caption).foregroundStyle(selected ? .white.opacity(0.8) : .secondary).lineLimit(1).truncationMode(.head)
                }
            }
            Spacer()
            if let d = item.detail { Text(d).font(.caption.monospaced()).foregroundStyle(selected ? .white.opacity(0.8) : .secondary) }
        }
        .padding(.horizontal, 12).padding(.vertical, 6)
        .foregroundStyle(selected ? .white : .primary)
        .background(selected ? Color.accentColor : Color.clear)
    }

    private func move(_ d: Int) {
        let n = items.count
        guard n > 0 else { return }
        selection = (selection + d + n) % n
    }

    private func run() {
        let all = items
        guard selection < all.count else { return }
        let item = all[selection]
        ws.palette = nil
        item.action()
    }

    // MARK: Items

    private var items: [PaletteItem] {
        mode == .files ? fileItems : commandItems
    }

    private var fileItems: [PaletteItem] {
        let q = query.trimmingCharacters(in: .whitespaces)
        if q.hasPrefix("@") { return fileSymbolItems(String(q.dropFirst())) }
        if q.hasPrefix("#") { return symbolResults }
        if q.hasPrefix(":"), let line = Int(q.dropFirst()), let d = ws.document {
            return [PaletteItem(id: "line", title: "Go to line \(line)", subtitle: d.path, icon: "arrow.right.to.line") { [ws] in
                ws.open(CodeLocation(path: d.path, range: SourceRange(line: max(0, line - 1))))
            }]
        }
        var path = q
        var line: Int?
        if let colon = q.lastIndex(of: ":"), let n = Int(q[q.index(after: colon)...]) {
            path = String(q[..<colon]); line = n
        }
        let candidates: [String]
        if path.isEmpty {
            candidates = ws.recentFiles + ws.allFiles.prefix(200).filter { !ws.recentFiles.contains($0) }
        } else {
            let lower = path.lowercased()
            var scored: [(String, Int)] = []
            scored.reserveCapacity(256)
            for p in ws.allFiles {
                guard var s = Fuzzy.score(lower, p.lowercased()) else { continue }
                if ws.recentFiles.contains(p) { s += 15 }
                scored.append((p, s))
            }
            candidates = scored.sorted { $0.1 > $1.1 }.prefix(80).map(\.0)
        }
        return candidates.prefix(80).map { p in
            PaletteItem(id: p, title: p.lastPathComponent, subtitle: p.deletingLastPathComponent,
                        detail: line.map { ":\($0)" } ?? (ws.recentFiles.contains(p) && path.isEmpty ? "recent" : nil),
                        icon: icon(for: p)) { [ws] in
                ws.open(CodeLocation(path: p, range: SourceRange(line: max(0, (line ?? 1) - 1))))
            }
        }
    }

    private func fileSymbolItems(_ q: String) -> [PaletteItem] {
        guard let d = ws.document else { return [] }
        let lower = q.lowercased()
        return d.syntax.flatOutline
            .compactMap { item -> (OutlineItem, Int)? in
                guard let s = Fuzzy.score(lower, item.qualifiedName.lowercased()) else { return nil }
                return (item, s)
            }
            .sorted { lower.isEmpty ? $0.0.range.start < $1.0.range.start : $0.1 > $1.1 }
            .prefix(100)
            .map { item, _ in
                PaletteItem(id: item.id.uuidString, title: item.kind == .impl ? item.detail : item.qualifiedName, subtitle: item.kind.label,
                            detail: "\(item.nameRange.start.line + 1)", icon: "function") { [ws] in
                    ws.open(CodeLocation(path: d.path, range: item.nameRange))
                }
            }
    }

    private func searchWorkspaceSymbols() {
        symbolTask?.cancel()
        let q = String(query.dropFirst()).trimmingCharacters(in: .whitespaces)
        guard !q.isEmpty else { symbolResults = []; return }
        symbolTask = Task {
            try? await Task.sleep(nanoseconds: 120_000_000)
            guard !Task.isCancelled else { return }
            var out: [PaletteItem] = []
            if ws.ra.status.isUsable, let syms = try? await ws.ra.workspaceSymbols(q) {
                out = syms.prefix(100).map { s in
                    PaletteItem(id: "\(s.location.id)#\(s.name)", title: s.name, subtitle: "\(s.location.path):\(s.location.displayLine)",
                                detail: s.container, icon: "number") { [ws] in ws.open(s.location, edge: .manual, source: .rustAnalyzer) }
                }
            } else {
                out = await ws.intel.syntaxDefinitions(name: q, near: ws.document?.path ?? "").prefix(50).map { loc in
                    PaletteItem(id: loc.id, title: q, subtitle: "\(loc.path):\(loc.displayLine)", detail: "tree-sitter", icon: "number") { [ws] in
                        ws.open(loc, edge: .manual, source: .treeSitter)
                    }
                }
            }
            if !Task.isCancelled { symbolResults = out }
        }
    }

    private func icon(for p: String) -> String {
        switch p.pathExtension {
        case "rs": "doc.text"
        case "toml", "lock": "gearshape"
        case "md": "doc.richtext"
        default: "doc"
        }
    }

    private var commandItems: [PaletteItem] {
        let all = PaletteCommands.all(ws: ws, model: model, openSettings: { openSettings() })
        let q = query.lowercased().trimmingCharacters(in: .whitespaces)
        guard !q.isEmpty else { return all }
        return all.compactMap { c -> (PaletteItem, Int)? in
            if let s = Fuzzy.score(q, c.title.lowercased()) { return (c, s + 20) }
            // Subtitles help ("jj new", "rust-analyzer"), but paths would match almost anything.
            if let sub = c.subtitle, !sub.hasPrefix("/"), let s = Fuzzy.score(q, sub.lowercased()) { return (c, s) }
            return nil
        }
        .sorted { $0.1 > $1.1 }
        .map(\.0)
    }
}

/// Every action reachable from the command palette.
@MainActor
enum PaletteCommands {
    static func all(ws: Workspace, model: AppModel, openSettings: @escaping @MainActor () -> Void) -> [PaletteItem] {
        var c: [PaletteItem] = []
        func add(_ title: String, _ subtitle: String? = nil, _ shortcut: String? = nil, icon: String = "command",
                 when: Bool = true, _ action: @escaping @MainActor () -> Void) {
            guard when else { return }
            c.append(PaletteItem(id: title, title: title, subtitle: subtitle, detail: shortcut, icon: icon, action: action))
        }
        let hasReview = ws.review != nil

        add("Go to File…", nil, "⌘K", icon: "doc.text.magnifyingglass") { ws.palette = .files }
        add("Go to Symbol in Workspace…", "rust-analyzer workspace symbols", icon: "number") {
            ws.palette = .files
        }
        add("Go Back", nil, "⌘[", icon: "chevron.left", when: !ws.backStack.isEmpty) { ws.goBack() }
        add("Go Forward", nil, "⌘]", icon: "chevron.right", when: !ws.forwardStack.isEmpty) { ws.goForward() }
        add("Go to Definition", nil, "⇧⌘D", icon: "arrow.right.circle", when: ws.cursor != nil) {
            if let p = ws.cursor { ws.goToDefinition(at: p) }
        }
        add("Show Files", icon: "folder") { ws.sidebarTab = .files }
        add("Show Search", nil, "⇧⌘F", icon: "magnifyingglass") { ws.sidebarTab = .search }
        add("Show Source Control", icon: "arrow.triangle.branch") { ws.sidebarTab = .scm }
        add("Show Changes", icon: "list.bullet.indent", when: hasReview) { ws.sidebarTab = .changes }

        // Review
        if ws.vcs.kind == .jj {
            add("Review Working Copy", "jj @- → @", icon: "arrow.triangle.pull") { ws.startReview(.jj(from: "@-", to: "@")) }
            add("Review Stack Since trunk()", "jj trunk() → @", icon: "square.stack") { ws.startReview(.jj(from: "trunk()", to: "@")) }
        }
        if ws.vcs.hasGit {
            add("Review Uncommitted Git Changes", "HEAD → working tree", icon: "doc.badge.ellipsis") { ws.startReview(.git(base: "HEAD", head: nil)) }
            add("Review GitHub Pull Request…", "list open PRs", icon: "arrow.triangle.pull") { ws.sidebarTab = .scm; ws.scmSection = .pullRequests }
        }
        add("Triage Review with Claude", ws.review?.title, icon: "sparkles", when: hasReview) {
            if let r = ws.review { Task { await r.triageWithClaude() } }
        }
        add("Next Hunk", nil, "⌘J", icon: "chevron.down", when: hasReview) { ReviewNav.next(ws) }
        add("Previous Hunk", nil, "⇧⌘J", icon: "chevron.up", when: hasReview) { ReviewNav.previous(ws) }
        add("Mark Hunk Viewed", nil, "⇧⌘V", icon: "checkmark.circle", when: hasReview && ws.selectedHunkID != nil) {
            if let id = ws.selectedHunkID { ws.review?.toggleViewed(id); ReviewNav.next(ws) }
        }
        for m in DiffMode.allCases {
            add("Diff: \(m.rawValue)", m == .inline ? "new version with removed lines in place" : m == .split ? "old and new side by side" : "\(m.rawValue.lowercased()) version only",
                icon: "rectangle.split.2x1", when: hasReview && ws.diffMode != m) { ws.setDiffMode(m) }
        }
        add("Submit GitHub Review…", "\(ws.review?.pendingForCurrentPR.count ?? 0) pending comments", icon: "paperplane",
            when: ws.review?.pullRequest != nil) { ws.showSubmitReview = true }
        add("Close Review", ws.review?.target.label, icon: "xmark.circle", when: ws.activeReviewKey != nil) { ws.review = nil }

        // Code paths
        add("Add Location to Code Path", nil, "⇧⌘T", icon: "plus", when: ws.document != nil) { ws.addCurrentToTrace() }
        add("New Code Path", icon: "point.topleft.down.to.point.bottomright.curvepath") { ws.newCodePath(fromCursor: false) }
        add("New Code Path from Cursor", icon: "point.topleft.down.to.point.bottomright.curvepath", when: ws.document != nil) {
            ws.newCodePath(fromCursor: true)
        }
        add("Next Code Path Step", nil, "⌥⌘↓", icon: "chevron.down", when: ws.traces.active != nil) { ws.playStep((ws.traces.currentStep ?? -1) + 1) }
        add("Previous Code Path Step", nil, "⌥⌘↑", icon: "chevron.up", when: ws.traces.active != nil) { ws.playStep((ws.traces.currentStep ?? 1) - 1) }
        add("Copy Code Path as Markdown", ws.traces.active?.title, icon: "doc.on.doc", when: ws.traces.active != nil) {
            if let t = ws.traces.active {
                NSPasteboard.general.clearContents()
                NSPasteboard.general.setString(t.markdown(), forType: .string)
            }
        }
        for t in ws.traces.traces.prefix(20) {
            add("Open Code Path: \(t.title)", "\(t.steps.count) steps", icon: "list.number") {
                ws.traces.activeID = t.id
                ws.playStep(0)
            }
        }

        // Claude
        add("Ask Claude…", nil, "⌘L", icon: "sparkles") { ws.openAsk() }
        if ws.activeReviewKey != nil {
            add("Close Review, Back to Working Copy", ws.review?.shortLabel, "⌥⌘W", icon: "xmark.circle") { ws.closeActiveReview() }
        }
        if let r = ws.review, !r.rangeCommits.isEmpty {
            add("Next Commit in Review", r.selectedCommitInfo?.title, nil, icon: "chevron.right") { r.stepCommit(1) }
            add("Previous Commit in Review", nil, nil, icon: "chevron.left") { r.stepCommit(-1) }
            add("Review All Commits Together", "\(r.rangeCommits.count) commits", nil, icon: "list.number") { r.selectCommit(nil) }
        }
        add("New Review Rule from Description…", nil, nil, icon: "wand.and.stars") { ws.showRuleWriter = true }

        // Navigation aids
        add("Toggle Bookmark", nil, "⇧⌘B", icon: "bookmark", when: ws.document != nil) { ws.toggleBookmark() }
        add("Copy File Path", ws.document?.path, icon: "doc.on.clipboard", when: ws.document != nil) {
            NSPasteboard.general.clearContents()
            NSPasteboard.general.setString("\(ws.document!.path):\((ws.cursor?.line ?? 0) + 1)", forType: .string)
        }
        add("Copy GitHub Link", "permalink to the current line", icon: "link", when: ws.document != nil && ws.vcs.hasGit) {
            Task {
                if let url = await ws.github.permalink(path: ws.document!.path, line: (ws.cursor?.line ?? 0) + 1) {
                    NSPasteboard.general.clearContents()
                    NSPasteboard.general.setString(url, forType: .string)
                    ws.statusMessage = "Copied \(url)"
                } else {
                    ws.statusMessage = "No GitHub remote found"
                }
            }
        }
        add("Open on GitHub", icon: "safari", when: ws.document != nil && ws.vcs.hasGit) {
            Task {
                if let url = await ws.github.permalink(path: ws.document!.path, line: (ws.cursor?.line ?? 0) + 1), let u = URL(string: url) {
                    NSWorkspace.shared.open(u)
                }
            }
        }
        add("Reveal File in Finder", icon: "folder", when: ws.document != nil) {
            NSWorkspace.shared.activateFileViewerSelecting([ws.docs.url(for: ws.document!.path)])
        }

        // Tools
        add("Run cargo clippy", ws.clippy.scope, icon: "stethoscope") { ws.clippy.run() }
        add("Generate SCIP Index", "rust-analyzer scip", icon: "archivebox") { ws.scip.generate(revision: ws.vcs.revision, sourceFiles: ws.allFiles) }
        add("Restart \(ws.activeServer.spec.name)", ws.activeServer.status.label, icon: "arrow.clockwise") { ws.activeServer.restart() }
        add(ws.showTests ? "Hide Tests in File Tree" : "Show Tests in File Tree", icon: "testtube.2") { ws.showTests.toggle() }
        add(ws.sourceOnly ? "Show All Files in Tree" : "Show Source Files Only", icon: "line.3.horizontal.decrease.circle") { ws.sourceOnly.toggle() }

        // jj
        if ws.vcs.kind == .jj {
            add("jj: New Change", "jj new", icon: "plus.square") { Task { await ws.scm.run(["new"]) } }
            add("jj: Describe Working Copy…", icon: "text.cursor") { ws.sidebarTab = .scm; ws.scmSection = .changes; ws.scm.focusDescription = true }
            add("jj: Git Fetch", "jj git fetch", icon: "arrow.down.circle") { Task { await ws.scm.run(["git", "fetch"]) } }
            add("jj: Undo Last Operation", "jj undo", icon: "arrow.uturn.backward") { Task { await ws.scm.run(["undo"]) } }
        }

        add("Open Repository…", nil, "⌘O", icon: "folder.badge.plus") { model.openPanel() }
        for r in model.recent.prefix(6) where r != ws.root.path {
            add("Open Recent: \(r.lastPathComponent)", r, icon: "clock") { model.open(URL(fileURLWithPath: r)) }
        }
        add("Edit My Review Rules", "~/Library/Application Support/Spelunk/review.rules", icon: "list.bullet.rectangle") { RulesFiles.openUserRules() }
        add("Edit Repository Review Rules", ".spelunk/review.rules", icon: "list.bullet.rectangle") { RulesFiles.openRepoRules(ws.root) }
        add("View Default Review Rules", icon: "list.bullet.rectangle") { RulesFiles.openDefaults() }
        add("Settings…", nil, "⌘,", icon: "gearshape") { openSettings() }
        add("Install Language Grammar…", "Settings › Languages", icon: "chevron.left.forwardslash.chevron.right") { openSettings() }
        return c
    }
}
