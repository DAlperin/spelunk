import AppKit
import SwiftUI

struct SCMView: View {
    @Bindable var ws: Workspace

    var body: some View {
        VStack(spacing: 0) {
            Picker("", selection: $ws.scmSection) {
                ForEach(SCMSection.allCases) { Text($0.rawValue).tag($0) }
            }
            .pickerStyle(.segmented).labelsHidden().padding(.horizontal, 8).padding(.bottom, 6)
            switch ws.scmSection {
            case .changes: ChangeGraphView(ws: ws, scm: ws.scm)
            case .pullRequests: PullRequestListView(ws: ws)
            }
        }
    }
}

struct ChangeGraphView: View {
    @Bindable var ws: Workspace
    @Bindable var scm: SCMService
    @FocusState private var descriptionFocused: Bool
    @State private var confirm: ConfirmAction?
    @State private var bookmarkTarget: SCMService.Change?
    @State private var bookmarkName = ""

    struct ConfirmAction: Identifiable {
        var id = UUID()
        var title: String
        var message: String
        var destructive: Bool
        var args: [String]
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            if scm.kind == .jj { workingCopyBox }
            if let e = scm.lastError {
                Text(e).font(.caption).foregroundStyle(.red).textSelection(.enabled).lineLimit(4)
                    .padding(.horizontal, 10).padding(.vertical, 4)
            } else if let o = scm.lastOutput {
                Text(o).font(.caption).foregroundStyle(.secondary).lineLimit(2)
                    .padding(.horizontal, 10).padding(.vertical, 2)
                    .onTapGesture { scm.lastOutput = nil }
            }
            HStack(spacing: 6) {
                TextField(scm.kind == .jj ? "revset (default log)" : "git log args (default --all)", text: $scm.revset)
                    .textFieldStyle(.roundedBorder).font(.caption.monospaced())
                    .onSubmit { Task { await scm.refresh(kind: ws.vcs.kind) } }
                if scm.kind == .jj {
                    Menu {
                        Button("Default log") { setRevset("") }
                        Button("My stack: trunk()..@") { setRevset("trunk()..@") }
                        Button("Mine: mine() ~ ::trunk()") { setRevset("mine() ~ ::trunk()") }
                        Button("Recent: latest(all(), 50)") { setRevset("latest(all(), 50)") }
                        Divider()
                        Button("jj git fetch") { Task { await scm.run(["git", "fetch"], label: "Fetching") } }
                        Button("jj undo") { Task { await scm.run(["undo"]) } }
                    } label: { Image(systemName: "ellipsis.circle") }
                    .menuStyle(.borderlessButton).fixedSize()
                }
                Button { Task { await scm.refresh(kind: ws.vcs.kind) } } label: { Image(systemName: "arrow.clockwise") }
                    .buttonStyle(.borderless)
                if scm.busy != nil { ProgressView().controlSize(.mini) }
            }
            .padding(.horizontal, 8).padding(.vertical, 4)
            Divider()
            List(selection: Binding(get: { scm.selectedID }, set: { id in
                Task { await scm.select(scm.rows.first { $0.change?.id == id }?.change) }
            })) {
                ForEach(scm.rows) { row in
                    if let c = row.change { graphRow(row.layout, c) }
                }
            }
            .listStyle(.sidebar)
            .environment(\.defaultMinListRowHeight, 12)
        }
        .task(id: ws.sidebarTab == .scm) { if ws.sidebarTab == .scm { await scm.refresh(kind: ws.vcs.kind) } }
        .onChange(of: scm.focusDescription) { if scm.focusDescription { descriptionFocused = true } }
        .alert(item: $confirm) { c in
            Alert(title: Text(c.title), message: Text(c.message),
                  primaryButton: c.destructive ? .destructive(Text("Run")) { Task { await scm.run(c.args) } } : .default(Text("Run")) { Task { await scm.run(c.args) } },
                  secondaryButton: .cancel())
        }
        .alert("Set bookmark", isPresented: Binding(get: { bookmarkTarget != nil }, set: { if !$0 { bookmarkTarget = nil } })) {
            TextField("name", text: $bookmarkName)
            Button("Set") {
                if let t = bookmarkTarget, !bookmarkName.isEmpty {
                    Task { await scm.run(["bookmark", "set", bookmarkName, "-r", t.rev, "--allow-backwards"]) }
                }
                bookmarkTarget = nil
            }
            Button("Cancel", role: .cancel) { bookmarkTarget = nil }
        }
    }

    private func setRevset(_ r: String) {
        scm.revset = r
        Task { await scm.refresh(kind: ws.vcs.kind) }
    }

    var workingCopyBox: some View {
        VStack(alignment: .leading, spacing: 6) {
            HStack {
                Text("Working copy").font(.caption.weight(.semibold)).foregroundStyle(.secondary)
                if let wc = scm.workingCopy {
                    Text(wc.changeId).font(.caption.monospaced()).foregroundStyle(.purple)
                    if wc.hasConflict { Text("conflict").font(.caption2).foregroundStyle(.red) }
                }
                Spacer()
                Text(verbatim: "\(scm.workingCopyFiles.count) files").font(.caption).foregroundStyle(.secondary)
            }
            TextField("Describe the working copy", text: $scm.descriptionDraft, axis: .vertical)
                .textFieldStyle(.roundedBorder).font(.callout)
                .lineLimit(1...5)
                .focused($descriptionFocused)
                .onChange(of: descriptionFocused) { scm.focusDescription = descriptionFocused }
            HStack(spacing: 6) {
                Button("Describe") { Task { await scm.describeWorkingCopy() } }
                Button("Commit") { Task { await scm.commit() } }.help("jj commit: describe @ and start a new change on top")
                Button("New") { Task { await scm.run(["new"]) } }.help("jj new: start an empty change on top of @")
                Spacer()
                Button("Review") { ws.startReview(.jj(from: "@-", to: "@")) }.disabled(scm.workingCopyFiles.isEmpty)
            }
            .controlSize(.small)
            if !scm.workingCopyFiles.isEmpty {
                VStack(alignment: .leading, spacing: 1) {
                    ForEach(scm.workingCopyFiles.prefix(40)) { f in
                        FileStatusRow(file: f) { ws.open(CodeLocation(path: f.path, range: SourceRange(line: 0))) }
                    }
                    if scm.workingCopyFiles.count > 40 {
                        Text(verbatim: "+\(scm.workingCopyFiles.count - 40) more").font(.caption2).foregroundStyle(.secondary)
                    }
                }
            }
        }
        .padding(.horizontal, 10).padding(.bottom, 8)
    }

    func graphRow(_ layout: GraphLayout, _ c: SCMService.Change) -> some View {
        VStack(alignment: .leading, spacing: 0) {
            ChangeRow(change: c, kind: scm.kind)
            if scm.selectedID == c.id { selectedDetail(c) }
        }
        .padding(.leading, GraphLanes.width(layout) + 4)
        .padding(.vertical, 3)
        .background(alignment: .leading) {
            GraphLanes(layout: layout, workingCopy: c.isWorkingCopy, immutable: c.isImmutable)
                .frame(width: GraphLanes.width(layout))
        }
        .listRowInsets(EdgeInsets(top: 0, leading: 6, bottom: 0, trailing: 8))
        .tag(c.id)
        .contextMenu { changeMenu(c) }
    }

    @ViewBuilder
    func selectedDetail(_ c: SCMService.Change) -> some View {
        VStack(alignment: .leading, spacing: 4) {
            HStack(spacing: 6) {
                Button("Review") { ws.reviewChange(c) }
                if scm.kind == .jj {
                    Button("Edit") { Task { await scm.run(["edit", c.rev]) } }.disabled(c.isImmutable)
                    Button("New on top") { Task { await scm.run(["new", c.rev]) } }
                }
            }
            .controlSize(.small).buttonStyle(.bordered)
            ForEach(scm.selectedFiles.prefix(60)) { f in
                FileStatusRow(file: f) { ws.reviewChange(c, focusPath: f.path) }
            }
        }
        .padding(.vertical, 4)
    }

    @ViewBuilder
    func changeMenu(_ c: SCMService.Change) -> some View {
        Button("Review This Change") { ws.reviewChange(c) }
        if scm.kind == .jj {
            Button("Review from Here to @") { ws.startReview(.jj(from: c.rev, to: "@")) }
            Divider()
            Button("Edit (jj edit)") { Task { await scm.run(["edit", c.rev]) } }.disabled(c.isImmutable)
            Button("New Change on Top (jj new)") { Task { await scm.run(["new", c.rev]) } }
            Button("Squash into Parent") {
                Task { await scm.run(["squash", "-r", c.rev, "--use-destination-message"]) }
            }.disabled(c.isImmutable)
            Button("Set Bookmark…") { bookmarkName = c.bookmarks.first?.replacingOccurrences(of: "*", with: "") ?? ""; bookmarkTarget = c }
            ForEach(c.bookmarks.filter { !$0.contains("@") }, id: \.self) { b in
                let name = b.replacingOccurrences(of: "*", with: "").replacingOccurrences(of: "?", with: "")
                Button("Push Bookmark \(name)…") {
                    confirm = ConfirmAction(title: "Push \(name)?", message: "Runs jj git push -b \(name), updating the remote branch.", destructive: false, args: ["git", "push", "-b", name])
                }
            }
            Divider()
            Button("Abandon…", role: .destructive) {
                confirm = ConfirmAction(title: "Abandon \(c.changeId)?", message: c.description.isEmpty ? "(no description)" : c.description, destructive: true, args: ["abandon", c.rev])
            }.disabled(c.isImmutable)
        }
        Divider()
        Button("Copy \(scm.kind == .jj ? "Change" : "Commit") ID") {
            NSPasteboard.general.clearContents()
            NSPasteboard.general.setString(scm.kind == .jj ? c.changeId : c.commitId, forType: .string)
        }
    }
}

struct ChangeRow: View {
    let change: SCMService.Change
    let kind: VCSKind

    var body: some View {
        HStack(alignment: .firstTextBaseline, spacing: 4) {
            VStack(alignment: .leading, spacing: 1) {
                HStack(spacing: 4) {
                    Text(kind == .jj ? change.changeId : change.commitId)
                        .font(.system(size: 11, weight: .semibold, design: .monospaced))
                        .foregroundStyle(change.isImmutable ? Color.secondary : Color.purple)
                    ForEach(change.bookmarks.prefix(3), id: \.self) { b in
                        Text(b).font(.system(size: 9, weight: .medium)).lineLimit(1)
                            .padding(.horizontal, 4).padding(.vertical, 1)
                            .background(Color.blue.opacity(0.15), in: Capsule()).foregroundStyle(.blue)
                    }
                    if change.hasConflict { Text("conflict").font(.system(size: 9, weight: .bold)).foregroundStyle(.red) }
                    if change.isEmpty { Text("empty").font(.system(size: 9)).foregroundStyle(.secondary) }
                    Spacer(minLength: 0)
                    Text(change.ago.replacingOccurrences(of: " ago", with: "")).font(.system(size: 9)).foregroundStyle(.tertiary).lineLimit(1)
                }
                Text(change.description.isEmpty ? "(no description)" : change.description)
                    .font(.system(size: 12)).italic(change.description.isEmpty)
                    .foregroundStyle(change.description.isEmpty ? .secondary : .primary)
                    .lineLimit(1)
            }
        }
        .padding(.vertical, 1)
    }
}

struct FileStatusRow: View {
    let file: SCMService.FileStatus
    let action: () -> Void

    var body: some View {
        Button(action: action) {
            HStack(spacing: 6) {
                Text(file.status).font(.system(size: 10, weight: .bold, design: .monospaced)).foregroundStyle(color).frame(width: 12)
                Text(file.path.lastPathComponent).font(.caption)
                Text(file.path.deletingLastPathComponent).font(.caption2).foregroundStyle(.secondary).lineLimit(1).truncationMode(.head)
                Spacer(minLength: 0)
            }
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
    }

    var color: Color {
        switch file.status {
        case "A": .green
        case "D": .red
        case "R", "C": .blue
        default: .orange
        }
    }
}

struct PullRequestListView: View {
    @Bindable var ws: Workspace
    @State private var filter: GitHubService.PRFilter = .reviewRequested
    @State private var query = ""
    @State private var prs: [GitHubService.PullRequestSummary] = []
    @State private var checks: [Int: String] = [:]
    @State private var loading = false
    @State private var error: String?

    var body: some View {
        VStack(spacing: 6) {
            Picker("", selection: $filter) {
                ForEach(GitHubService.PRFilter.allCases) { Text($0.rawValue).tag($0) }
            }.labelsHidden().padding(.horizontal, 8)
            HStack {
                TextField("Search (GitHub syntax) or #number", text: $query).textFieldStyle(.roundedBorder).onSubmit(load)
                Button { load() } label: { Image(systemName: "arrow.clockwise") }.buttonStyle(.borderless)
            }.padding(.horizontal, 8)
            if let r = ws.github.repo { Text(r).font(.caption).foregroundStyle(.secondary) }
            if loading { ProgressView().controlSize(.small) }
            if let e = error { Text(e).font(.caption).foregroundStyle(.red).padding(.horizontal, 8) }
            List(prs) { pr in
                Button { ws.startReview(.githubPR(pr.number)) } label: { PRRow(pr: pr, checks: checks[pr.number]) }.buttonStyle(.plain)
                    .contextMenu {
                        Button("Review in Spelunk") { ws.startReview(.githubPR(pr.number)) }
                        Button("Open on GitHub") { if let u = URL(string: pr.url) { NSWorkspace.shared.open(u) } }
                        Button("Copy URL") { NSPasteboard.general.clearContents(); NSPasteboard.general.setString(pr.url, forType: .string) }
                    }
            }
            .listStyle(.sidebar)
        }
        .task(id: filter) { load() }
    }

    private func load() {
        let q = query.trimmingCharacters(in: .whitespaces)
        if let n = Int(q.trimmingCharacters(in: CharacterSet(charactersIn: "#"))) {
            ws.startReview(.githubPR(n))
            return
        }
        loading = true
        Task {
            do {
                prs = try await ws.github.listPullRequests(filter, query: q)
                error = nil
                loading = false
                checks = await ws.github.checkStates(prs.map(\.number))
            } catch {
                self.error = error.localizedDescription
            }
            loading = false
        }
    }
}

struct PRRow: View {
    let pr: GitHubService.PullRequestSummary
    var checks: String?

    var body: some View {
        VStack(alignment: .leading, spacing: 2) {
            HStack(spacing: 4) {
                Text(verbatim: "#\(pr.number)").font(.caption.monospaced()).foregroundStyle(.secondary)
                if pr.isDraft { Text("draft").font(.system(size: 9)).foregroundStyle(.secondary) }
                Spacer()
                switch checks {
                case "SUCCESS": Image(systemName: "checkmark.circle.fill").font(.caption2).foregroundStyle(.green).help("Checks passed")
                case "FAILURE", "ERROR": Image(systemName: "xmark.circle.fill").font(.caption2).foregroundStyle(.red).help("Checks failing")
                case "PENDING", "EXPECTED": Image(systemName: "clock").font(.caption2).foregroundStyle(.orange).help("Checks running")
                default: EmptyView()
                }
                Text(verbatim: "+\(pr.additions) −\(pr.deletions)").font(.caption2.monospaced()).foregroundStyle(.secondary)
            }
            Text(pr.title).font(.callout).lineLimit(2)
            HStack(spacing: 4) {
                Text(pr.author?.login ?? "").font(.caption2).foregroundStyle(.secondary)
                if let d = pr.reviewDecision {
                    Text(d.replacingOccurrences(of: "_", with: " ").lowercased()).font(.caption2)
                        .foregroundStyle(d == "APPROVED" ? .green : d == "CHANGES_REQUESTED" ? .red : .secondary)
                }
            }
        }
        .padding(.vertical, 2)
    }
}

/// Draws one row's slice of the commit graph at the row's full height, so lanes join the rows
/// above and below. The node sits level with the row's first line.
struct GraphLanes: View {
    let layout: GraphLayout
    var workingCopy = false
    var immutable = false

    static let lane: CGFloat = 12
    static let nodeY: CGFloat = 11
    static func width(_ l: GraphLayout) -> CGFloat { CGFloat(max(1, l.width)) * lane + 2 }
    static func x(_ i: Int) -> CGFloat { CGFloat(i) * lane + lane / 2 }

    static let palette: [Color] = [.blue, .purple, .orange, .teal, .pink, .green, .yellow, .indigo]
    static func color(_ i: Int) -> Color { palette[i % palette.count].opacity(0.75) }

    var body: some View {
        Canvas { ctx, size in
            let h = size.height, y0 = Self.nodeY, nx = Self.x(layout.node)
            func stroke(_ p: Path, _ lane: Int, dashed: Bool = false) {
                ctx.stroke(p, with: .color(Self.color(lane)),
                           style: StrokeStyle(lineWidth: 1.5, lineCap: .round, dash: dashed ? [3, 3] : []))
            }
            for t in layout.through {
                stroke(Path { $0.move(to: CGPoint(x: Self.x(t), y: 0)); $0.addLine(to: CGPoint(x: Self.x(t), y: h)) }, t)
            }
            if layout.incoming {
                stroke(Path { $0.move(to: CGPoint(x: nx, y: 0)); $0.addLine(to: CGPoint(x: nx, y: y0)) }, layout.node)
            }
            for m in layout.merges {
                stroke(Path { p in
                    p.move(to: CGPoint(x: Self.x(m), y: 0))
                    p.addCurve(to: CGPoint(x: nx, y: y0), control1: CGPoint(x: Self.x(m), y: y0 * 0.7), control2: CGPoint(x: nx, y: y0 * 0.3))
                }, m)
            }
            for e in layout.outgoing {
                let ex = Self.x(e.lane)
                stroke(Path { p in
                    p.move(to: CGPoint(x: nx, y: y0))
                    if e.lane == layout.node {
                        p.addLine(to: CGPoint(x: nx, y: h))
                    } else {
                        let bend = min(h, y0 + 14)
                        p.addCurve(to: CGPoint(x: ex, y: bend), control1: CGPoint(x: nx, y: y0 + 8), control2: CGPoint(x: ex, y: bend - 8))
                        p.addLine(to: CGPoint(x: ex, y: h))
                    }
                }, e.lane, dashed: e.elided)
            }
            if layout.stub {
                stroke(Path { $0.move(to: CGPoint(x: nx, y: y0)); $0.addLine(to: CGPoint(x: nx, y: min(h, y0 + 14))) }, layout.node, dashed: true)
            }
            let r: CGFloat = workingCopy ? 4.5 : 3.5
            let dot = Path(ellipseIn: CGRect(x: nx - r, y: y0 - r, width: r * 2, height: r * 2))
            if workingCopy {
                ctx.fill(dot, with: .color(.green))
            } else if immutable {
                ctx.fill(Path(CGRect(x: nx - 3, y: y0 - 3, width: 6, height: 6)).applying(
                    CGAffineTransform(translationX: nx, y: y0).rotated(by: .pi / 4).translatedBy(x: -nx, y: -y0)), with: .color(.secondary))
            } else {
                ctx.fill(dot, with: .color(Color(nsColor: .windowBackgroundColor)))
                ctx.stroke(dot, with: .color(Self.color(layout.node)), lineWidth: 1.5)
            }
        }
    }
}
