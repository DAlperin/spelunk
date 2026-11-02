import SwiftUI

struct RootView: View {
    @Environment(AppModel.self) var model

    var body: some View {
        Group {
            if let ws = model.workspace {
                MainView(ws: ws).id(ObjectIdentifier(ws))
            } else {
                WelcomeView()
            }
        }
        .onAppear { Log.debug("RootView appeared") }
    }
}

struct WelcomeView: View {
    @Environment(AppModel.self) var model

    var body: some View {
        VStack(spacing: 18) {
            Image(systemName: "point.3.connected.trianglepath.dotted").font(.system(size: 44)).foregroundStyle(.secondary)
            Text("Spelunk").font(.largeTitle.weight(.semibold))
            Text("Read, trace and review Rust code.").foregroundStyle(.secondary)
            Button("Open Repository…") { model.openPanel() }.keyboardShortcut("o").controlSize(.large)
            if !model.recent.isEmpty {
                VStack(alignment: .leading, spacing: 4) {
                    Text("Recent").font(.caption).foregroundStyle(.secondary)
                    ForEach(model.recent, id: \.self) { p in
                        Button { model.open(URL(fileURLWithPath: p)) } label: {
                            HStack {
                                Image(systemName: "folder")
                                Text(p.lastPathComponent).fontWeight(.medium)
                                Text(p.deletingLastPathComponent).foregroundStyle(.secondary).lineLimit(1)
                            }
                        }.buttonStyle(.plain)
                    }
                }
                .frame(width: 420, alignment: .leading)
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }
}

struct MainView: View {
    @Bindable var ws: Workspace
    @State private var showInspector = true
    @State private var columns = NavigationSplitViewVisibility.all

    var body: some View {
        NavigationSplitView(columnVisibility: $columns) {
            SidebarView(ws: ws)
                .navigationSplitViewColumnWidth(min: 220, ideal: 280, max: 420)
        } detail: {
            EditorColumn(ws: ws)
                .inspector(isPresented: $showInspector) {
                    InspectorView(ws: ws)
                        .inspectorColumnWidth(min: 280, ideal: 360, max: 560)
                }
        }
        .toolbar { MainToolbar(ws: ws, showInspector: $showInspector) }
        .navigationTitle(ws.name)
        .sheet(isPresented: $ws.showAsk) { AskSheet(ws: ws) }
    }
}

struct MainToolbar: ToolbarContent {
    @Bindable var ws: Workspace
    @Binding var showInspector: Bool
    @State private var showReviewPicker = false

    var body: some ToolbarContent {
        ToolbarItemGroup(placement: .navigation) {
            Button { ws.goBack() } label: { Image(systemName: "chevron.left") }
                .disabled(ws.backStack.isEmpty).help("Back (⌘[)")
            Button { ws.goForward() } label: { Image(systemName: "chevron.right") }
                .disabled(ws.forwardStack.isEmpty).help("Forward (⌘])")
        }
        ToolbarItemGroup(placement: .principal) {
            Menu {
                Text(ws.root.path)
                if ws.vcs.kind != .none { Text("\(ws.vcs.kind.rawValue) \(ws.vcs.revision) \(ws.vcs.description)") }
                Divider()
                Button("Restart rust-analyzer") { ws.ra.restart() }
                Button("Run cargo clippy") { ws.clippy.run() }
                Button("Generate SCIP index") { ws.scip.generate(revision: ws.vcs.revision, sourceFiles: ws.allFiles) }
                Button("Reveal in Finder") { NSWorkspace.shared.activateFileViewerSelecting([ws.root]) }
            } label: {
                Label(ws.name, systemImage: "shippingbox").labelStyle(.titleAndIcon)
            }
            .help("Repository")

            Button { showReviewPicker = true } label: {
                Label(ws.review?.target.label ?? "Review…", systemImage: "arrow.triangle.pull").labelStyle(.titleAndIcon)
            }
            .help("Review a change")
            .popover(isPresented: $showReviewPicker) { ReviewPicker(ws: ws, dismiss: { showReviewPicker = false }) }

            if ws.review != nil {
                Picker("Side", selection: Binding(get: { ws.reviewSide }, set: { ws.setReviewSide($0) })) {
                    ForEach(ReviewSide.allCases, id: \.self) { Text($0.rawValue).tag($0) }
                }
                .pickerStyle(.segmented)
                .frame(width: 130)
                .help("Show the file before or after the change")
            }
        }
        ToolbarItemGroup(placement: .primaryAction) {
            Button { ws.showAsk = true } label: { Image(systemName: "sparkles") }.help("Ask Claude (⌘L)")
            Button {
                if ws.traces.isRecording { ws.traces.isRecording = false } else {
                    ws.traces.startRecording(from: ws.currentLocation.map { loc in
                        TraceStep(title: ws.document?.syntax.enclosingItem(line: loc.line)?.qualifiedName ?? loc.shortDescription,
                                  location: loc, edge: .start, source: .manual,
                                  snippet: ws.document?.lineText(loc.line).trimmingCharacters(in: .whitespaces) ?? "")
                    })
                }
            } label: {
                Image(systemName: ws.traces.isRecording ? "record.circle.fill" : "record.circle")
                    .foregroundStyle(ws.traces.isRecording ? .red : .primary)
            }
            .help(ws.traces.isRecording ? "Stop recording trace" : "Record navigation as a trace")
            Button { showInspector.toggle() } label: { Image(systemName: "sidebar.right") }.help("Toggle context pane")
        }
    }
}

struct ReviewPicker: View {
    @Bindable var ws: Workspace
    var dismiss: () -> Void
    @State private var from = "trunk()"
    @State private var to = "@"
    @State private var gitBase = "origin/main"
    @State private var pr = ""

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            Text("Review a change").font(.headline)
            if ws.vcs.kind == .jj {
                Button { go(.jj(from: "@-", to: "@")) } label: { Label("Working copy (@- → @)", systemImage: "pencil.and.outline") }
                Button { go(.jj(from: "trunk()", to: "@")) } label: { Label("Stack since trunk()", systemImage: "square.stack") }
                HStack {
                    TextField("from", text: $from).frame(width: 110)
                    Image(systemName: "arrow.right")
                    TextField("to", text: $to).frame(width: 110)
                    Button("Review") { go(.jj(from: from, to: to)) }
                }
                .textFieldStyle(.roundedBorder)
            }
            if ws.vcs.hasGit {
                Divider()
                Button { go(.git(base: "HEAD", head: nil)) } label: { Label("Uncommitted git changes", systemImage: "doc.badge.ellipsis") }
                HStack {
                    TextField("base", text: $gitBase).frame(width: 140).textFieldStyle(.roundedBorder)
                    Text("→ working tree").foregroundStyle(.secondary)
                    Button("Review") {
                        Task {
                            let mb = (try? await Shell.output("git", ["merge-base", gitBase, "HEAD"], cwd: ws.root))?
                                .trimmingCharacters(in: .whitespacesAndNewlines)
                            go(.git(base: mb ?? gitBase, head: nil))
                        }
                    }
                }
                Divider()
                HStack {
                    TextField("PR number", text: $pr).frame(width: 110).textFieldStyle(.roundedBorder)
                    Button("Review GitHub PR") { if let n = Int(pr.trimmingCharacters(in: CharacterSet(charactersIn: "# "))) { go(.githubPR(n)) } }
                }
            }
            if ws.review != nil {
                Divider()
                Button("Close review", role: .destructive) { ws.review = nil; ws.sidebarTab = .files; dismiss() }
            }
        }
        .buttonStyle(.borderless)
        .padding(16)
        .frame(width: 400)
    }

    private func go(_ t: ReviewTarget) { ws.startReview(t); dismiss() }
}

struct EditorColumn: View {
    @Bindable var ws: Workspace

    var body: some View {
        VStack(spacing: 0) {
            BreadcrumbBar(ws: ws)
            Divider()
            if let r = ws.review, let id = ws.selectedHunkID, let h = r.allHunks.first(where: { $0.id == id }),
               ws.document?.path == h.path || ws.document?.path == r.file(for: h)?.oldPath {
                HunkStrip(ws: ws, review: r, hunk: h)
                Divider()
            }
            if let t = ws.traces.active, let i = ws.traces.currentStep, i < t.steps.count, ws.document?.path == t.steps[i].location.path {
                TraceStepBanner(ws: ws, trace: t, index: i)
                Divider()
            }
            if let doc = ws.document {
                CodeView(ws: ws, document: doc)
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
            } else {
                ContentUnavailableView("No file open", systemImage: "doc.text", description: Text("Pick a file from the sidebar."))
            }
            Divider()
            StatusBar(ws: ws)
        }
    }
}

struct BreadcrumbBar: View {
    @Bindable var ws: Workspace

    var body: some View {
        HStack(spacing: 4) {
            Image(systemName: "externaldrive").foregroundStyle(.secondary)
            Text(ws.name).foregroundStyle(.secondary)
            if let d = ws.document {
                ForEach(Array(d.path.split(separator: "/").enumerated()), id: \.offset) { _, c in
                    Image(systemName: "chevron.right").font(.caption2).foregroundStyle(.tertiary)
                    Text(String(c)).foregroundStyle(.secondary)
                }
                if let line = ws.cursor?.line, let item = d.syntax.enclosingItem(line: line) {
                    Image(systemName: "chevron.right").font(.caption2).foregroundStyle(.tertiary)
                    Text(item.qualifiedName).fontWeight(.medium)
                }
                if let label = d.revisionLabel {
                    Text(label).font(.caption.weight(.semibold))
                        .padding(.horizontal, 6).padding(.vertical, 1)
                        .background(label == "Before" ? Color.red.opacity(0.15) : Color.green.opacity(0.15), in: Capsule())
                }
            }
            Spacer()
            if ws.traces.isRecording {
                Label("Recording trace", systemImage: "record.circle.fill").foregroundStyle(.red).font(.caption)
            }
        }
        .font(.system(size: 12))
        .lineLimit(1)
        .padding(.horizontal, 10)
        .frame(height: 28)
    }
}

struct StatusBar: View {
    @Bindable var ws: Workspace
    @State private var showIndex = false

    var body: some View {
        HStack(spacing: 10) {
            if let d = ws.document {
                Text(d.language.displayName)
                Text("\(d.lines.lineCount) lines").foregroundStyle(.secondary)
                if d.language == .rust {
                    if d.syntax.errorCount > 0 {
                        Label("Partial structure", systemImage: "exclamationmark.triangle").foregroundStyle(.orange)
                            .help("tree-sitter recovered from \(d.syntax.errorCount) syntax errors")
                    }
                    let tests = d.syntax.testLineRanges.count
                    if tests > 0 { Text("\(tests) test region\(tests == 1 ? "" : "s")").foregroundStyle(.secondary) }
                }
            }
            if let msg = ws.statusMessage {
                Text(msg).foregroundStyle(.secondary).lineLimit(1)
                    .onTapGesture { ws.statusMessage = nil }
            }
            if let g = ws.traceGenerating {
                ProgressView().controlSize(.mini)
                Text("Tracing: \(g)").foregroundStyle(.purple).lineLimit(1)
            }
            Spacer()
            clippyStatus
            Button { showIndex.toggle() } label: {
                HStack(spacing: 4) {
                    Circle().fill(raColor).frame(width: 7, height: 7)
                    Text(raLabel)
                    Text("·").foregroundStyle(.tertiary)
                    Text(ws.scip.summary)
                }
            }
            .buttonStyle(.plain)
            .popover(isPresented: $showIndex, arrowEdge: .top) { IndexPopover(ws: ws) }
            if let c = ws.cursor { Text("Line \(c.line + 1)").foregroundStyle(.secondary) }
            Text("UTF-8 · Read Only").foregroundStyle(.secondary)
        }
        .font(.system(size: 11))
        .lineLimit(1)
        .padding(.horizontal, 10)
        .frame(height: 24)
    }

    @ViewBuilder var clippyStatus: some View {
        switch ws.clippy.state {
        case .idle: EmptyView()
        case .running(let s):
            HStack(spacing: 4) { ProgressView().controlSize(.mini); Text("clippy: \(s)").lineLimit(1).frame(maxWidth: 220) }
        case .done:
            let errs = ws.clippy.diagnostics.filter { $0.level == .error }.count
            let warns = ws.clippy.diagnostics.count - errs
            Label("\(errs) \(warns)", systemImage: errs > 0 ? "xmark.octagon" : "exclamationmark.triangle")
                .foregroundStyle(errs > 0 ? .red : .secondary)
                .help("cargo clippy: \(errs) errors, \(warns) warnings")
        case .failed(let e): Text("clippy failed").foregroundStyle(.red).help(e)
        }
    }

    var raLabel: String {
        switch ws.ra.status {
        case .ready: "rust-analyzer"
        case .indexing(let s): s.isEmpty ? "rust-analyzer indexing" : "RA: \(s.prefix(40))"
        case .starting: "rust-analyzer starting"
        case .off: "rust-analyzer off"
        case .failed: "rust-analyzer failed"
        }
    }

    var raColor: Color {
        switch ws.ra.status {
        case .ready: .green
        case .indexing, .starting: .yellow
        case .off: .gray
        case .failed: .red
        }
    }
}

struct IndexPopover: View {
    @Bindable var ws: Workspace
    @State private var showUncovered = false

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            Text("Code Intelligence").font(.headline)
            Text("Navigation asks providers in order of precision and falls back when one cannot answer. Each result in the context pane shows which provider produced it.")
                .font(.caption).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
            Divider()
            row("rust-analyzer (LSP)", ws.ra.status.label, color: ws.ra.status == .ready ? .green : (ws.ra.status.isUsable ? .yellow : .red)) {
                if let b = ws.ra.binaryPath { Text(b).font(.caption2).foregroundStyle(.secondary).lineLimit(1).truncationMode(.middle) }
                HStack {
                    Button(ws.ra.status == .off ? "Start" : "Restart") { ws.ra.restart() }
                    if ws.ra.status != .off { Button("Stop") { ws.ra.stop() } }
                }
            }
            Divider()
            row("SCIP index", scipLabel, color: ws.scip.index == nil ? .gray : (ws.scip.uncoveredFiles.isEmpty ? .green : .yellow)) {
                if let m = ws.scip.meta {
                    Text("Generated \(m.generatedAt.formatted(date: .abbreviated, time: .shortened)) at \(m.revision) · \(m.tool)")
                        .font(.caption).foregroundStyle(.secondary)
                }
                if let idx = ws.scip.index {
                    Text("\(idx.documents.count) files · \(idx.occurrencesBySymbol.count) symbols").font(.caption).foregroundStyle(.secondary)
                }
                if !ws.scip.uncoveredFiles.isEmpty {
                    DisclosureGroup("\(ws.scip.uncoveredFiles.count) Rust files not covered", isExpanded: $showUncovered) {
                        ScrollView {
                            VStack(alignment: .leading) {
                                ForEach(ws.scip.uncoveredFiles.prefix(300), id: \.self) { Text($0).font(.caption2.monospaced()) }
                            }
                        }.frame(maxHeight: 120)
                    }.font(.caption)
                }
                HStack {
                    if case .generating = ws.scip.state { Button("Cancel") { ws.scip.cancel() } } else {
                        Button(ws.scip.index == nil ? "Generate" : "Reindex") {
                            ws.scip.generate(revision: ws.vcs.revision, sourceFiles: ws.allFiles)
                        }
                    }
                    Button("Reveal Cache in Finder") {
                        NSWorkspace.shared.activateFileViewerSelecting([ws.scip.cacheURL.deletingLastPathComponent()])
                    }
                }
            }
            Divider()
            row("tree-sitter", "Rust grammar 0.23 · always on", color: .green) {
                Text("Highlighting, outline, enclosing items, test regions, change classification.").font(.caption).foregroundStyle(.secondary)
            }
            Divider()
            row("Static analysis", clippyLabel, color: ws.clippy.diagnostics.isEmpty ? .gray : .yellow) {
                HStack {
                    TextField("scope", text: Binding(get: { ws.clippy.scope }, set: {
                        ws.clippy.scope = $0; UserDefaults.standard.set($0, forKey: "clippyScope")
                    })).textFieldStyle(.roundedBorder).frame(width: 180).help("Extra cargo args, e.g. -p mz-adapter")
                    Button("Run cargo clippy") { ws.clippy.run() }
                }
            }
            Divider()
            row("Claude", Claude.binary == nil ? "claude CLI not found" : "claude CLI · \(Claude.model)", color: Claude.binary == nil ? .red : .purple) {
                Text("Questions, generated traces and review triage. Read-only tools (Read, Grep, Glob), rooted at the repository.")
                    .font(.caption).foregroundStyle(.secondary)
            }
        }
        .padding(16)
        .frame(width: 440)
    }

    var scipLabel: String {
        switch ws.scip.state {
        case .none: "Not generated"
        case .generating(let s): s
        case .loading: "Loading…"
        case .loaded: ws.scip.uncoveredFiles.isEmpty ? "Complete" : "Partial"
        case .failed(let e): e
        }
    }

    var clippyLabel: String {
        switch ws.clippy.state {
        case .idle: "Not run"
        case .running(let s): s
        case .done(let d): "\(ws.clippy.diagnostics.count) diagnostics · \(d.formatted(date: .omitted, time: .shortened))"
        case .failed(let e): e
        }
    }

    func row<C: View>(_ title: String, _ status: String, color: Color, @ViewBuilder content: () -> C) -> some View {
        VStack(alignment: .leading, spacing: 4) {
            HStack {
                Circle().fill(color).frame(width: 7, height: 7)
                Text(title).fontWeight(.medium)
                Spacer()
                Text(status).foregroundStyle(.secondary).lineLimit(1).truncationMode(.middle)
            }
            content()
        }
        .buttonStyle(.bordered)
        .controlSize(.small)
    }
}

struct HunkStrip: View {
    @Bindable var ws: Workspace
    let review: ReviewSession
    let hunk: Hunk
    @State private var showDiff = false

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            HStack(spacing: 8) {
                TierBadge(tier: review.tier(of: hunk)).fixedSize()
                Text(review.reasons(of: hunk).joined(separator: " · ")).font(.callout).lineLimit(1)
                if let e = review.analyses[hunk.id]?.enclosing {
                    Text("in \(e)").font(.callout.monospaced()).foregroundStyle(.secondary).lineLimit(1)
                }
                Spacer()
                Text("+\(hunk.addedCount) −\(hunk.removedCount)").font(.caption.monospaced()).foregroundStyle(.secondary)
                Button(showDiff ? "Hide diff" : "Show diff") { showDiff.toggle() }.fixedSize()
                Toggle("Viewed", isOn: Binding(get: { review.viewed.contains(hunk.id) }, set: { _ in review.toggleViewed(hunk.id) }))
                    .toggleStyle(.checkbox).fixedSize()
                Button { ReviewNav.previous(ws) } label: { Image(systemName: "chevron.up") }.help("Previous hunk (⌘K)")
                Button { ReviewNav.next(ws) } label: { Image(systemName: "chevron.down") }.help("Next hunk (⌘J)")
            }
            if let s = review.llm[hunk.id]?.summary {
                Label(s, systemImage: "sparkles").font(.caption).foregroundStyle(.purple)
            }
            if showDiff {
                UnifiedHunkView(hunk: hunk).frame(maxHeight: 220)
            }
        }
        .buttonStyle(.borderless)
        .controlSize(.small)
        .padding(.horizontal, 10).padding(.vertical, 6)
        .background(review.tier(of: hunk).color.opacity(0.06))
    }
}

struct UnifiedHunkView: View {
    let hunk: Hunk
    var body: some View {
        ScrollView([.vertical, .horizontal]) {
            VStack(alignment: .leading, spacing: 0) {
                ForEach(Array(hunk.lines.enumerated()), id: \.offset) { _, l in
                    HStack(spacing: 6) {
                        Text(l.oldLine.map { "\($0 + 1)" } ?? "").frame(width: 38, alignment: .trailing)
                        Text(l.newLine.map { "\($0 + 1)" } ?? "").frame(width: 38, alignment: .trailing)
                        Text((l.kind == .added ? "+ " : l.kind == .removed ? "- " : "  ") + l.text)
                    }
                    .foregroundStyle(l.kind == .context ? .secondary : .primary)
                    .background(l.kind == .added ? Color(Theme.added) : l.kind == .removed ? Color(Theme.removed) : .clear)
                }
            }
            .font(.system(size: 11, design: .monospaced))
        }
    }
}

struct TraceStepBanner: View {
    @Bindable var ws: Workspace
    let trace: Trace
    let index: Int

    var body: some View {
        let step = trace.steps[index]
        HStack(alignment: .top, spacing: 8) {
            Text("\(index + 1)/\(trace.steps.count)").font(.caption.monospaced().weight(.semibold))
                .padding(.horizontal, 6).padding(.vertical, 2).background(Color.purple.opacity(0.15), in: Capsule())
            VStack(alignment: .leading, spacing: 2) {
                HStack {
                    Text(step.title).font(.callout.monospaced().weight(.semibold))
                    if !step.verified {
                        Label("unverified location", systemImage: "questionmark.circle").font(.caption).foregroundStyle(.orange)
                    }
                    Text(trace.title).font(.caption).foregroundStyle(.secondary).lineLimit(1)
                }
                if !step.note.isEmpty { Text(step.note).font(.callout).lineLimit(4).help(step.note) }
            }
            Spacer()
            Button { ws.playStep(index - 1) } label: { Image(systemName: "chevron.up") }.disabled(index == 0)
            Button { ws.playStep(index + 1) } label: { Image(systemName: "chevron.down") }.disabled(index + 1 >= trace.steps.count)
            Button { ws.traces.currentStep = nil } label: { Image(systemName: "xmark") }
        }
        .buttonStyle(.borderless)
        .padding(.horizontal, 10).padding(.vertical, 6)
        .background(Color.purple.opacity(0.05))
    }
}
