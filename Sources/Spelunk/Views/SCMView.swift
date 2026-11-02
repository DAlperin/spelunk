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
                    if let c = row.change {
                        VStack(alignment: .leading, spacing: 0) {
                            ChangeRow(graph: row.graph, change: c, kind: scm.kind)
                            if scm.selectedID == c.id { selectedDetail(c, graph: row.graph) }
                        }
                        .tag(c.id)
                        .contextMenu { changeMenu(c) }
                    } else {
                        Text(row.graph).font(.system(size: 11, design: .monospaced)).foregroundStyle(.tertiary)
                            .lineLimit(1).frame(height: 12)
                            .selectionDisabled()
                    }
                }
            }
            .listStyle(.sidebar)
            .environment(\.defaultMinListRowHeight, 12)
        }
        .task { await scm.refresh(kind: ws.vcs.kind) }
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

    @ViewBuilder
    func selectedDetail(_ c: SCMService.Change, graph: String) -> some View {
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
        .padding(.leading, CGFloat(graph.count) * 6.5 + 4)
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
    let graph: String
    let change: SCMService.Change
    let kind: VCSKind

    var body: some View {
        HStack(alignment: .firstTextBaseline, spacing: 4) {
            Text(graph).font(.system(size: 11, design: .monospaced)).foregroundStyle(change.isWorkingCopy ? Color.green : .secondary)
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
                Button { ws.startReview(.githubPR(pr.number)) } label: { PRRow(pr: pr) }.buttonStyle(.plain)
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
            } catch {
                self.error = error.localizedDescription
            }
            loading = false
        }
    }
}

struct PRRow: View {
    let pr: GitHubService.PullRequestSummary

    var body: some View {
        VStack(alignment: .leading, spacing: 2) {
            HStack(spacing: 4) {
                Text(verbatim: "#\(pr.number)").font(.caption.monospaced()).foregroundStyle(.secondary)
                if pr.isDraft { Text("draft").font(.system(size: 9)).foregroundStyle(.secondary) }
                Spacer()
                let c = pr.checkSummary
                if c.failed > 0 { Label("\(c.failed)", systemImage: "xmark.circle.fill").font(.caption2).foregroundStyle(.red) }
                else if c.pending > 0 { Label("\(c.pending)", systemImage: "clock").font(.caption2).foregroundStyle(.orange) }
                else if c.passed > 0 { Image(systemName: "checkmark.circle.fill").font(.caption2).foregroundStyle(.green) }
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
