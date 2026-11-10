import SwiftUI

/// One window: a repository, or the welcome screen until one is chosen.
struct RootView: View {
    @State private var path = ""
    @Environment(AppModel.self) var model
    @Environment(\.openSettings) private var openSettings
    @Environment(\.openWindow) private var openWindow
    @Environment(\.controlActiveState) private var activeState
    @State private var ws: Workspace?
    @State private var window: NSWindow?
    /// This window was asked for with New Window, so an empty one is wanted.
    @State private var requestedBlank = false

    var body: some View {
        Group {
            if let ws {
                MainView(ws: ws).id(ObjectIdentifier(ws))
            } else {
                WelcomeView(path: $path)
            }
        }
        .background(WindowReader { window = $0; register(); closeIfStray() })
        .onReceive(NotificationCenter.default.publisher(for: .spelunkWindowRegistered)) { _ in closeIfStray() }
        .onAppear {
            model.openSettings = { openSettings() }
            model.openBlankWindow = { openWindow(id: "main") }
            // A restored window whose repository has another window shows the welcome screen; a new
            // window takes a queued repository.
            if !path.isEmpty, model.hasOtherWindow(for: path, than: window) { path = "" }
            if path.isEmpty, let p = model.pendingPath() { path = p }
            if path.isEmpty { requestedBlank = model.takeBlankRequest() }
            attach()
        }
        .onChange(of: path) { old, _ in
            if !old.isEmpty, old != path { model.release(old) }
            attach()
        }
        .onChange(of: activeState) { if activeState == .key, !path.isEmpty { model.activePath = path } }
        .onDisappear {
            // A discarded duplicate view never registered a window; only the window's own view releases.
            if !path.isEmpty, let window, model.windows[path] === window { model.release(path) }
        }
    }

    private func attach() {
        guard !path.isEmpty else { ws = nil; return }
        ws = model.workspace(for: path)
        register()
        if activeState == .key || model.activePath == nil { model.activePath = path }
    }

    /// A window macOS opened for a launch event, with nothing to show while repositories are open
    /// elsewhere.
    private func closeIfStray() {
        guard path.isEmpty, !requestedBlank, let window, model.windows.values.contains(where: { $0 !== window && $0.isVisible }) else { return }
        DispatchQueue.main.async { window.close() }
    }

    private func register() {
        if let window, !path.isEmpty { model.registerWindow(window, for: path) }
    }
}

/// Hands back the NSWindow hosting a view.
struct WindowReader: NSViewRepresentable {
    let found: (NSWindow) -> Void
    init(_ found: @escaping (NSWindow) -> Void) { self.found = found }
    func makeNSView(context: Context) -> NSView { ReaderView(found: found) }
    func updateNSView(_ v: NSView, context: Context) {}

    final class ReaderView: NSView {
        let found: (NSWindow) -> Void
        init(found: @escaping (NSWindow) -> Void) {
            self.found = found
            super.init(frame: .zero)
        }
        required init?(coder: NSCoder) { fatalError() }
        override func viewDidMoveToWindow() {
            super.viewDidMoveToWindow()
            if let w = window { found(w) }
        }
    }
}

struct WelcomeView: View {
    @Environment(AppModel.self) var model
    @Binding var path: String

    /// Opens here, unless the repository already has a window, which comes forward instead.
    private func choose(_ p: String) {
        if model.isOpen(p) { model.open(URL(fileURLWithPath: p)) } else { path = p }
    }

    var body: some View {
        VStack(spacing: 18) {
            Image(systemName: "point.3.connected.trianglepath.dotted").font(.system(size: 44)).foregroundStyle(.secondary)
            Text("Spelunk").font(.largeTitle.weight(.semibold))
            Text("Read, trace and review code.").foregroundStyle(.secondary)
            Button("Open Repository…") { if let u = model.chooseRepository() { choose(u.standardizedFileURL.path) } }.controlSize(.large)
            if !model.recent.isEmpty {
                VStack(alignment: .leading, spacing: 4) {
                    Text("Recent").font(.caption).foregroundStyle(.secondary)
                    ForEach(model.recent, id: \.self) { p in
                        Button { choose(p) } label: {
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
    @State private var keyMonitor: Any?
    @State private var columns = NavigationSplitViewVisibility.all
    /// This window, so its key monitor ignores keystrokes meant for other windows.
    @State private var host = WindowBox()

    var body: some View {
        NavigationSplitView(columnVisibility: $columns) {
            SidebarView(ws: ws)
                .navigationSplitViewColumnWidth(min: 220, ideal: 280, max: 420)
        } detail: {
            EditorColumn(ws: ws)
                .inspector(isPresented: $ws.showInspector) {
                    InspectorView(ws: ws)
                        .inspectorColumnWidth(min: 280, ideal: 360, max: 560)
                }
        }
        .toolbar { MainToolbar(ws: ws, showInspector: $ws.showInspector) }
        .navigationTitle(ws.name)
        .sheet(isPresented: $ws.showRuleWriter) { RuleWriterSheet(ws: ws) }
        .onAppear {
            Guide.shared.windowOpened()
            if let m = keyMonitor { NSEvent.removeMonitor(m) }
            keyMonitor = NSEvent.addLocalMonitorForEvents(matching: .keyDown) { [ws, host] e in
                let handled = MainActor.assumeIsolated { () -> Bool in
                    // Every window installs a monitor and each sees every key; only the window the
                    // key was typed in handles it.
                    guard let w = e.window, w === host.window, w.isVisible, w.attachedSheet == nil, !w.isSheet else { return false }
                    // Ctrl-w pane moves work from anywhere in the window, text fields included.
                    if ws.palette == nil, PaneFocus.handle(e, window: w) { return true }
                    guard !ReviewKeys.focusIsTextInput() else { return false }
                    return ReviewKeys.handle(e, ws: ws)
                }
                return handled ? nil : e
            }
        }
        .onDisappear { if let m = keyMonitor { NSEvent.removeMonitor(m); keyMonitor = nil } }
        .background(WindowReader { host.window = $0 })
        .overlay(alignment: .top) {
            if let mode = ws.palette {
                ZStack(alignment: .top) {
                    Color.black.opacity(0.08).ignoresSafeArea().onTapGesture { ws.palette = nil }
                    PaletteView(ws: ws, mode: mode).padding(.top, 40)
                }
            }
        }
    }
}

struct MainToolbar: ToolbarContent {
    @Bindable var ws: Workspace
    @Binding var showInspector: Bool
    @State private var showReviewPicker = false
    @AppStorage(Prefs.Key.ignoreWhitespace) private var ignoreWhitespace = true

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
                if ws.vcs.kind != .none { Text(verbatim: "\(ws.vcs.kind.rawValue) \(ws.vcs.revision) \(ws.vcs.description)") }
                Divider()
                Button("Restart \(ws.activeServer.spec.name)") { ws.activeServer.restart() }
                Button("Run cargo clippy") { ws.clippy.run() }
                Button("Generate SCIP index") { ws.scip.generate(revision: ws.vcs.revision, sourceFiles: ws.allFiles) }
                Button("Reveal in Finder") { NSWorkspace.shared.activateFileViewerSelecting([ws.root]) }
            } label: {
                Label(ws.name, systemImage: "shippingbox").labelStyle(.titleAndIcon)
            }
            .help("Repository")

            ReviewTargetMenu(ws: ws, showPicker: $showReviewPicker)
                .popover(isPresented: $showReviewPicker) { ReviewPicker(ws: ws, dismiss: { showReviewPicker = false }) }
            if ws.activeReviewKey != nil {
                Button { ws.closeActiveReview() } label: { Image(systemName: "xmark.circle.fill").foregroundStyle(.secondary) }
                    .help("Close this review and go back to the working copy (⌥⌘W)")
            }

            if ws.diffPickerApplies {
                Picker("Diff", selection: Binding(get: { !ws.diffShown ? .plain : ws.diffMode == .before ? .after : ws.diffMode }, set: { ws.setDiffMode($0) })) {
                    ForEach(DiffMode.toolbar) { Text($0.rawValue).tag($0) }
                }
                .pickerStyle(.segmented)
                .frame(width: 220)
                .help("Plain: the file without the review's diff. Inline: new version with removed lines in place. Split: old and new side by side. After: the new version only.")
            }
            if ws.reviewing {
                Toggle(isOn: Binding(get: { ignoreWhitespace }, set: { Prefs.setIgnoreWhitespace($0) })) {
                    Image(systemName: "text.word.spacing")
                }
                .toggleStyle(.button)
                .help(ignoreWhitespace ? "Whitespace changes are hidden; click to show them" : "Whitespace changes are shown; click to hide them")
            }
        }
        ToolbarItemGroup(placement: .primaryAction) {
            Button { ws.openAsk() } label: { Label("Ask", systemImage: "sparkles").labelStyle(.titleAndIcon) }.help("Ask Claude (⌘L)")
            Button { ws.addCurrentToTrace() } label: { Label("Trace", systemImage: "point.topleft.down.to.point.bottomright.curvepath").labelStyle(.titleAndIcon) }
                .help("Add the cursor location to the code path (⇧⌘T)")
            Button { showInspector.toggle() } label: { Image(systemName: "sidebar.right") }.help("Toggle context pane")
        }
    }
}

/// The review being shown: working copy, pinned PRs and changes (⌃1…⌃9), and ways to open more.
struct ReviewTargetMenu: View {
    @Bindable var ws: Workspace
    @Binding var showPicker: Bool

    var body: some View {
        let all = [ws.workingReview].compactMap { $0 } + ws.pinnedReviews
        Menu {
            ForEach(Array(all.enumerated()), id: \.element.target.key) { i, r in
                let active = (r.tracksWorkingCopy && ws.activeReviewKey == nil) || ws.activeReviewKey == r.target.key
                Toggle(isOn: Binding(get: { active }, set: { _ in ws.activateReview(r.tracksWorkingCopy ? nil : r.target.key) })) {
                    Text(verbatim: Self.name(r) + (r.tracksWorkingCopy || r.title.isEmpty ? "" : " — " + r.title.prefix(50)))
                    Text(verbatim: Self.coverage(r))
                }
                .keyboardShortcut(i < 9 ? KeyboardShortcut(KeyEquivalent(Character(String(i + 1))), modifiers: .control) : nil)
            }
            Divider()
            Button("Review a Pull Request…") { ws.sidebarTab = .scm; ws.scmSection = .pullRequests }
            Button("Compare Revisions…") { showPicker = true }
            if ws.activeReviewKey != nil {
                Divider()
                Button("Close \(ws.review?.shortLabel ?? "Review")") { ws.closeActiveReview() }
                    .keyboardShortcut("w", modifiers: [.command, .option])
            }
        } label: {
            // A toolbar menu draws one icon and one text, so the label is a single string.
            if let r = ws.review {
                Label(Self.name(r) + (all.count > 1 ? " · \(all.count) open" : ""), systemImage: Self.icon(r)).labelStyle(.titleAndIcon)
            } else {
                Text("No review")
            }
        }
        .help(ws.review.map(Self.coverage) ?? "Choose what to review")
    }

    static func icon(_ r: ReviewSession) -> String {
        if case .githubPR = r.target { return "arrow.triangle.pull" }
        return r.tracksWorkingCopy ? "pencil.line" : "square.stack"
    }

    /// The review's kind and identity: "Working copy · qqtqomnp", "Change qqtqomnp", "PR #123".
    static func name(_ r: ReviewSession) -> String {
        if r.showsParent { return "Working copy · @ empty, showing " + (r.changeID ?? "@-") }
        if r.tracksWorkingCopy { return "Working copy" + (r.changeID.map { " · " + $0 } ?? "") }
        switch r.target {
        case .githubPR(let n): return "PR #" + String(n)
        case .jj: return r.rangeCommits.count > 1 ? "Range " + r.target.label : "Change " + (r.changeID ?? r.target.label)
        case .git(_, let h): return h.map { "Commit " + $0.prefix(8) } ?? "Uncommitted"
        }
    }

    /// What the review diffs and whether it keeps up with the repository.
    static func coverage(_ r: ReviewSession) -> String {
        let size = r.state == .ready ? " · \(r.files.count) files +\(r.addedCount) −\(r.removedCount)" : ""
        if r.showsParent { return "Follows the working copy; @ is empty, so this is its parent (@- → its parent)" + size }
        if r.tracksWorkingCopy { return "Follows the working copy (\(r.target.label))" + size }
        let loaded = r.lastLoaded.map { ", loaded " + $0.formatted(date: .omitted, time: .shortened) } ?? ""
        return r.target.label + size + " · fixed" + loaded
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
            if ws.reviewing, let r = ws.review, let id = ws.selectedHunkID, let h = r.allHunks.first(where: { $0.id == id }),
               let doc = ws.document, ws.reviewFile(for: doc) != nil, doc.path == h.path || doc.path == r.file(for: h)?.oldPath {
                HunkStrip(ws: ws, review: r, hunk: h)
                Divider()
            }
            if let t = ws.traces.active, let i = ws.traces.currentStep, i < t.steps.count, ws.document?.path == t.steps[i].location.path {
                TraceStepBanner(ws: ws, trace: t, index: i)
                Divider()
            }
            if let doc = ws.document {
                if ws.reviewing && ws.diffMode == .split, let old = ws.splitDocument, old.path == (ws.review?.files.first { $0.newPath == doc.path }?.oldPath ?? doc.path) {
                    HStack(spacing: 0) {
                        VStack(spacing: 0) {
                            SplitPaneHeader(title: "Before", color: .red)
                            CodeView(ws: ws, document: old, secondary: true).id("split-" + old.id.uuidString)
                        }
                        Divider()
                        VStack(spacing: 0) {
                            SplitPaneHeader(title: "After", color: .green)
                            CodeView(ws: ws, document: doc)
                        }
                    }
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
                } else {
                    CodeView(ws: ws, document: doc)
                        .frame(maxWidth: .infinity, maxHeight: .infinity)
                }
            } else {
                ContentUnavailableView("No file open", systemImage: "doc.text", description: Text("Pick a file from the sidebar, or press ⌘K."))
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
            }
            if let r = ws.review, r.pullRequest != nil {
                Divider()
                PendingReviewBar(ws: ws, review: r)
            }
            Divider()
            StatusBar(ws: ws)
        }
        .overlay(alignment: .bottomTrailing) {
            if Guide.shared.visible {
                GuideCard(ws: ws).padding(.trailing, 18).padding(.bottom, 36)
                    .transition(.move(edge: .bottom).combined(with: .opacity))
            }
        }
        .animation(.easeOut(duration: 0.2), value: Guide.shared.visible)
    }
}

struct SplitPaneHeader: View {
    let title: String
    let color: Color
    var body: some View {
        HStack {
            Circle().fill(color).frame(width: 6, height: 6)
            Text(title).font(.caption.weight(.semibold)).foregroundStyle(.secondary)
            Spacer()
        }
        .padding(.horizontal, 10).frame(height: 20)
        .background(Color.secondary.opacity(0.06))
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
            }
            Spacer()
            if let v = ws.versionInfo { VersionChip(info: v) }
        }
        .font(.system(size: 12))
        .lineLimit(1)
        .padding(.horizontal, 10)
        .frame(height: 28)
    }
}

/// Which text of the file is open: the working copy, or a review's Before or After. Its menu
/// switches to the other versions that exist.
struct VersionChip: View {
    let info: VersionInfo

    var body: some View {
        let label = HStack(spacing: 4) {
            Image(systemName: icon).font(.system(size: 10))
            Text(verbatim: info.title)
            if let n = info.notReviewed { Text(verbatim: "· " + n).foregroundStyle(.orange) }
        }
        .font(.system(size: 11, weight: .medium))
        .foregroundStyle(tint)
        .padding(.horizontal, 7).padding(.vertical, 2)
        .background(tint.opacity(0.12), in: Capsule())
        .overlay(Capsule().strokeBorder(info.notReviewed != nil ? Color.orange.opacity(0.6) : .clear))
        Group {
            if info.alternatives.isEmpty {
                label
            } else {
                Menu {
                    Section("Show") {
                        ForEach(info.alternatives) { a in Button(a.label) { a.open() } }
                    }
                } label: { label }
                .menuStyle(.button)
                .buttonStyle(.plain)
                .menuIndicator(.hidden)
            }
        }
        .fixedSize()
        .help(info.help)
    }

    private var icon: String {
        switch info.kind {
        case .workingCopy: "internaldrive"
        case .after: "plus.forwardslash.minus"
        case .before: "clock.arrow.circlepath"
        case .other: "number"
        }
    }

    private var tint: Color {
        switch info.kind {
        case .workingCopy: .secondary
        case .after: .green
        case .before: .red
        case .other: .purple
        }
    }
}

/// The open file's folds: how many functions are folded, with fold, unfold and reset commands.
struct FoldMenu: View {
    @Bindable var ws: Workspace
    let document: SourceDocument
    @AppStorage(Prefs.Key.foldMode) private var foldMode = FoldMode.review.rawValue

    var body: some View {
        let headers = ws.foldHeaders(for: document)
        if !headers.isEmpty {
            let folded = headers.values.filter { $0 }.count
            Menu {
                Button("Fold All Functions") { ws.foldAll(true) }
                Button("Unfold All Functions") { ws.foldAll(false) }
                Button("Reset to Default Folds") { ws.resetFolds(document) }
                Divider()
                Picker("Files Open With", selection: $foldMode) {
                    ForEach(FoldMode.allCases) { Text($0.label).tag($0.rawValue) }
                }
            } label: {
                Text(verbatim: folded > 0 ? "\(folded) of \(headers.count) folded" : "\(headers.count) foldable")
                    .font(.system(size: 11))
                    .foregroundStyle(.secondary)
            }
            .menuStyle(.borderlessButton)
            .controlSize(.small)
            .menuIndicator(.hidden)
            .fixedSize()
            .help("Folds in this file. Click a chevron in the gutter to fold or unfold one function.")
        }
    }
}

struct StatusBar: View {
    @Bindable var ws: Workspace
    @AppStorage(Prefs.Key.vim) private var vim = false

    var body: some View {
        HStack(spacing: 10) {
            if let d = ws.document {
                Text(d.languageName)
                Text(verbatim: "\(d.lines.lineCount) lines").foregroundStyle(.secondary)
                FoldMenu(ws: ws, document: d)
                if d.language == .rust {
                    if d.syntax.errorCount > 0 {
                        Label("Partial structure", systemImage: "exclamationmark.triangle").foregroundStyle(.orange)
                            .help("tree-sitter recovered from \(d.syntax.errorCount) syntax errors")
                    }
                    let tests = d.syntax.testLineRanges.count
                    if tests > 0 { Text(verbatim: "\(tests) test region\(tests == 1 ? "" : "s")").foregroundStyle(.secondary) }
                }
            }
            if vim {
                Text(ws.vimStatus ?? "NORMAL").font(.system(size: 10, weight: .bold, design: .monospaced))
                    .padding(.horizontal, 5).padding(.vertical, 1)
                    .background((ws.vimStatus ?? "").hasPrefix("VISUAL") ? Color.orange.opacity(0.25) : Color.accentColor.opacity(0.2), in: RoundedRectangle(cornerRadius: 3))
                    .fixedSize()
                    .help("Vim navigation: ]h [h hunks, ]u next unviewed, space v viewed, space c comment, ]t [t threads, gd definition, K hover, Ctrl-o back")
            }
            if let msg = ws.statusMessage {
                Text(msg).foregroundStyle(.secondary).lineLimit(1).truncationMode(.tail)
                    .help(msg)
                    .onTapGesture { ws.statusMessage = nil }
                    .layoutPriority(-1)
            }
            let running = ws.runningJobs.count, unseen = ws.unseenJobs
            if running > 0 || unseen > 0 {
                Button { ws.showInspector = true; ws.inspectorPane = .claude } label: {
                    HStack(spacing: 4) {
                        if running > 0 { ProgressView().controlSize(.mini) } else { Image(systemName: "sparkles") }
                        Text(verbatim: running > 0 ? "Claude: \(running) running" + (unseen > 0 ? ", \(unseen) new" : "") : "Claude: \(unseen) new")
                    }
                    .foregroundStyle(.purple)
                }
                .buttonStyle(.plain).fixedSize()
                .help(ws.runningJobs.map(\.question).joined(separator: "\n"))
            }
            Spacer(minLength: 8)
            StatusIndicators(ws: ws).fixedSize()
            if ws.reviewing, ws.review?.files.isEmpty == false {
                ViewThatFits(in: .horizontal) {
                    keyHints(labels: true)
                    keyHints(labels: false)
                    Color.clear.frame(width: 0)
                }
                .foregroundStyle(.secondary)
                .layoutPriority(-2)
            }
        }
        .font(.system(size: 11))
        .lineLimit(1)
        .padding(.horizontal, 10)
        .frame(height: 24)
    }

    /// The review keys; with vim navigation on, the ones that work in the code view.
    func keyHints(labels: Bool) -> some View {
        HStack(spacing: 4) {
            KeyCap("J"); KeyCap("K"); if labels { Text("hunk") }
            KeyCap(vim ? "]u" : "⇧J"); if labels { Text("next important") }
            KeyCap(vim ? "␣v" : "V"); if labels { Text("viewed") }
            if ws.review?.pullRequest != nil {
                KeyCap("C"); if labels { Text("comment") }
                if vim { KeyCap("]t"); KeyCap("[t") } else { KeyCap("N"); KeyCap("P") }
                if labels { Text("thread") }
            }
        }
        .fixedSize()
    }

}

/// Clippy, the language server and the caret line: a view of its own, so the frequent changes it
/// shows redraw only this part of the status bar.
struct StatusIndicators: View {
    @Bindable var ws: Workspace
    @State private var showIndex = false

    var body: some View {
        HStack(spacing: 10) {
            clippyStatus
            Button { showIndex.toggle() } label: {
                HStack(spacing: 4) {
                    if ws.document.map({ ws.server(for: $0.path) != nil }) ?? true {
                        Circle().fill(raColor).frame(width: 7, height: 7)
                        Text(raLabel)
                        Text("·").foregroundStyle(.tertiary)
                    }
                    Text(ws.scip.summary)
                }
            }
            .buttonStyle(.plain)
            .popover(isPresented: $showIndex, arrowEdge: .top) { IndexPopover(ws: ws) }
            if let d = ws.document, let tree = ws.intelTree(for: d) {
                Text(verbatim: "answers from the " + tree)
                    .foregroundStyle(tree == "working copy" ? Color.orange : .secondary)
                    .help(tree == "working copy"
                          ? "This file is not the working copy, but definitions, references and hover come from the working copy's code at the matching place. Index the review head (in the Review tab's header) for answers about this version."
                          : "Definitions, references and hover come from a language server running on this review's own code.")
            }
            if let r = ws.removedLineAtCaret { Text(verbatim: "Removed line \(r)").foregroundStyle(.red) }
            else if let c = ws.cursor { Text(verbatim: "Line \(c.line + 1)").foregroundStyle(.secondary) }
        }
    }

    @ViewBuilder var clippyStatus: some View {
        switch ws.clippy.state {
        case .idle: EmptyView()
        case .running(let s):
            HStack(spacing: 4) { ProgressView().controlSize(.mini); Text(verbatim: "clippy: \(s)").lineLimit(1).frame(maxWidth: 220) }
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
        let s = ws.activeServer
        switch s.status {
        case .ready: return s.spec.name
        case .indexing(let m): return m.isEmpty ? "\(s.spec.name) indexing" : "\(s.spec.name): \(m.prefix(40))"
        case .starting: return "\(s.spec.name) starting"
        case .off: return "\(s.spec.name) off"
        case .failed: return "\(s.spec.name) failed"
        }
    }

    var raColor: Color {
        switch ws.activeServer.status {
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
            ForEach(ws.servers, id: \.spec.name) { srv in
                row("\(srv.spec.name) (LSP)", srv.status.label, color: srv.status == .ready ? .green : (srv.status.isUsable ? .yellow : (srv.status == .off ? .gray : .red))) {
                    if let b = srv.binaryPath { Text(b).font(.caption2).foregroundStyle(.secondary).lineLimit(1).truncationMode(.middle) }
                    HStack {
                        Button(srv.status == .off ? "Start" : "Restart") { srv.restart() }
                        if srv.status != .off { Button("Stop") { srv.stop() } }
                    }
                }
            }
            Divider()
            row("SCIP index", scipLabel, color: ws.scip.index == nil ? .gray : (ws.scip.uncoveredFiles.isEmpty ? .green : .yellow)) {
                if let m = ws.scip.meta {
                    Text(verbatim: "Generated \(m.generatedAt.formatted(date: .abbreviated, time: .shortened)) at \(m.revision) · \(m.tool)")
                        .font(.caption).foregroundStyle(.secondary)
                }
                if let idx = ws.scip.index {
                    Text(verbatim: "\(idx.documents.count) files · \(idx.occurrencesBySymbol.count) symbols").font(.caption).foregroundStyle(.secondary)
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
            row("tree-sitter", "Rust grammar 0.24 · always on", color: .green) {
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
            row("Claude", Claude.binary == nil ? "claude CLI not found" : "claude CLI · questions \(Claude.model(for: .ask)), traces \(Claude.model(for: .trace)), triage \(Claude.model(for: .triage))", color: Claude.binary == nil ? .red : .purple) {
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

    var body: some View {
        let tier = review.tier(of: hunk)
        VStack(alignment: .leading, spacing: 6) {
            HStack(spacing: 8) {
                Image(systemName: tier.glyph).font(.system(size: 9)).foregroundStyle(tier.color)
                    .onTapGesture { ws.showHunkContext() }
                Text(tier.title).font(.callout.weight(.semibold)).foregroundStyle(tier.color).fixedSize()
                Text(review.analyses[hunk.id]?.enclosing ?? hunk.path.lastPathComponent)
                    .font(.callout.monospaced().weight(.medium)).lineLimit(1).truncationMode(.middle)
                    .frame(maxWidth: 320, alignment: .leading).fixedSize(horizontal: false, vertical: true).layoutPriority(1)
                Text(verbatim: sizeText).font(.callout.monospaced()).foregroundStyle(.secondary).fixedSize()
                if let t = review.triage(of: hunk) {
                    Image(systemName: t.isQuick ? "sparkle" : "sparkles").font(.caption).foregroundStyle(.purple)
                }
                Text(review.summary(of: hunk)).font(.callout).foregroundStyle(.secondary).lineLimit(1).truncationMode(.tail).help(ruleHelp)
                    .onTapGesture { ws.showHunkContext() }
                    .layoutPriority(-1)
                Spacer(minLength: 4)
                HStack(spacing: 8) {
                if let (i, n) = ReviewNav.importantPosition(ws) {
                    ViewThatFits { Text(verbatim: "\(i) of \(n) important"); Text(verbatim: "\(i)/\(n)") }
                        .font(.caption).foregroundStyle(.secondary)
                }
                Button { ReviewNav.previous(ws) } label: { KeyCap("K") }.help("Previous hunk (K)")
                Button { ReviewNav.next(ws) } label: { KeyCap("J") }.help("Next hunk (J); ⇧J next unviewed important hunk")
                Button { review.toggleViewed(hunk); if review.isViewed(hunk) { ReviewNav.nextImportant(ws) } } label: {
                    HStack(spacing: 4) {
                        Image(systemName: review.isViewed(hunk) ? "checkmark.circle.fill" : "circle")
                            .foregroundStyle(review.isViewed(hunk) ? .green : .secondary)
                        Text("Viewed")
                        KeyCap("V")
                    }
                    .padding(.horizontal, 6).padding(.vertical, 2)
                    .background(Color.secondary.opacity(0.12), in: RoundedRectangle(cornerRadius: 5))
                }
                .help("Mark viewed and go to the next important hunk (V)")
                }
                .fixedSize()
                .layoutPriority(2)
            }
            .lineLimit(1)
        }
        .buttonStyle(.plain)
        .controlSize(.small)
        .padding(.horizontal, 10).padding(.vertical, 6)
        .background(tier.color.opacity(0.06))
        .overlay(alignment: .leading) { Rectangle().fill(tier.color).frame(width: 3) }
    }

    var sizeText: String {
        hunk.addedCount == 0 ? "−\(hunk.removedCount)" : hunk.removedCount == 0 ? "+\(hunk.addedCount)" : "+\(hunk.addedCount) −\(hunk.removedCount)"
    }
}

/// A small keyboard-key glyph.
struct KeyCap: View {
    let key: String
    init(_ key: String) { self.key = key }
    var body: some View {
        Text(key).font(.system(size: 10, weight: .medium, design: .rounded))
            .padding(.horizontal, 4).padding(.vertical, 1)
            .background(Color.secondary.opacity(0.18), in: RoundedRectangle(cornerRadius: 3))
            .foregroundStyle(.secondary)
    }
}

extension HunkStrip {
    var ruleHelp: String {
        let a = review.analyses[hunk.id]
        var lines = ["Rules: \(a?.tier.title ?? "?") — \(a?.reasons.joined(separator: ", ") ?? "")" + (a?.rule.map { " (\($0))" } ?? "")]
        if let t = review.triage(of: hunk) { lines.append("Claude (\(t.isQuick ? "quick" : "deep")): \(t.tier.title) — \(t.reason)") }
        return lines.joined(separator: "\n")
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
        VStack(alignment: .leading, spacing: 4) {
            HStack(spacing: 8) {
                Image(systemName: "point.topleft.down.to.point.bottomright.curvepath").foregroundStyle(.purple)
                Text(trace.title).font(.callout.weight(.semibold)).lineLimit(1).truncationMode(.tail)
                    .help(trace.title)
                Spacer(minLength: 4)
                Text(verbatim: "\(index + 1) of \(trace.steps.count)").font(.caption.monospacedDigit()).foregroundStyle(.secondary).fixedSize()
                HStack(spacing: 2) {
                    Button { ws.playStep(index - 1) } label: { Image(systemName: "chevron.left") }
                        .disabled(index == 0).help("Previous step (⌥[)")
                    Button { ws.playStep(index + 1) } label: { Image(systemName: "chevron.right") }
                        .disabled(index + 1 >= trace.steps.count).help("Next step (⌥])")
                    Button { ws.closeCodePath() } label: { Image(systemName: "xmark") }.help("Close the code path")
                }
                .buttonStyle(.borderless)
                .fixedSize()
            }
            HStack(alignment: .firstTextBaseline, spacing: 6) {
                Text(verbatim: String(index + 1)).font(.callout.weight(.bold)).foregroundStyle(.purple)
                if step.note.isEmpty {
                    Text(step.title).font(.callout.monospaced())
                    Button("Add a note") { ws.inspectorPane = .paths; ws.editingStepID = step.id }.buttonStyle(.link).font(.caption)
                } else {
                    Text(step.note).font(.callout).lineLimit(3).help(step.note)
                }
                if !step.verified { Label("unverified location", systemImage: "questionmark.circle").font(.caption).foregroundStyle(.orange) }
            }
        }
        .buttonStyle(.plain)
        .font(.caption)
        .padding(.horizontal, 12).padding(.vertical, 7)
        .background(Color.purple.opacity(0.08))
    }
}

/// A weak reference to a view's window, shared with closures created before the window is known.
@MainActor
final class WindowBox {
    weak var window: NSWindow?
}
