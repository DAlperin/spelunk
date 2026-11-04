import AppKit
import SwiftUI

@main
struct SpelunkApp: App {
    @NSApplicationDelegateAdaptor(AppDelegate.self) var delegate
    @State private var model = AppModel()

    init() {
        // A child process launched to check a third-party grammar does only that.
        GrammarProbe.runIfRequested()
    }

    var body: some Scene {
        // One repository per window; opening a repository that already has a window brings it
        // forward. AppModel reopens the repositories that were open at quit, so SwiftUI's own
        // window restoration is off.
        WindowGroup("Spelunk", id: "main") {
            RootView()
                .environment(model)
                .frame(minWidth: 1000, minHeight: 640)
        }
        .restorationBehavior(.disabled)

        .defaultSize(width: 1560, height: 980)
        .windowToolbarStyle(.unified(showsTitle: false))
        .commands {
            CommandGroup(replacing: .newItem) {
                Button("New Window") { model.newWindow() }.keyboardShortcut("n")
                Button("Open Repository…") { model.openPanel() }.keyboardShortcut("o")
            }
            CommandMenu("Navigate") {
                Button("Back") { model.workspace?.goBack() }.keyboardShortcut("[")
                Button("Forward") { model.workspace?.goForward() }.keyboardShortcut("]")
                Divider()
                Button("Go to Definition") {
                    if let ws = model.workspace, let p = ws.cursor { ws.goToDefinition(at: p) }
                }.keyboardShortcut("d", modifiers: [.command, .shift])
                Button("Go to File…") { model.workspace?.palette = .files }.keyboardShortcut("k")
                Button("Command Palette…") { model.workspace?.palette = .commands }.keyboardShortcut("k", modifiers: [.command, .shift])
                Button("Filter File Tree") { model.workspace?.sidebarTab = .files; model.focusFilter.toggle() }.keyboardShortcut("p")
                Button("Find in Repository…") { model.workspace?.sidebarTab = .search }.keyboardShortcut("f", modifiers: [.command, .shift])
                Divider()
                Button("Fold Function") { model.workspace?.setFold(true) }.keyboardShortcut(.leftArrow, modifiers: [.command, .option])
                Button("Unfold Function") { model.workspace?.setFold(false) }.keyboardShortcut(.rightArrow, modifiers: [.command, .option])
                Button("Fold All Functions") { model.workspace?.foldAll(true) }.keyboardShortcut(.leftArrow, modifiers: [.command, .option, .shift])
                Button("Unfold All Functions") { model.workspace?.foldAll(false) }.keyboardShortcut(.rightArrow, modifiers: [.command, .option, .shift])
            }
            CommandMenu("Code Paths") {
                Button("Add Location to Code Path") { model.workspace?.addCurrentToTrace() }.keyboardShortcut("t", modifiers: [.command, .shift])
                Button("New Code Path") { model.workspace?.newCodePath(fromCursor: false) }
                Button("Import Code Path from Clipboard") {
                    model.workspace?.importCodePath(NSPasteboard.general.string(forType: .string) ?? "")
                }
                Button("Copy Code Path as Text") {
                    guard let t = model.workspace?.traces.active else { return }
                    NSPasteboard.general.clearContents()
                    NSPasteboard.general.setString(t.plainText(), forType: .string)
                }.disabled(model.workspace?.traces.active == nil)
                Button("Close Code Path") { model.workspace?.closeCodePath() }.disabled(model.workspace?.traces.active == nil)
                Divider()
                Button("Next Step ") {
                    guard let ws = model.workspace else { return }
                    ws.playStep((ws.traces.currentStep ?? -1) + 1)
                }.keyboardShortcut("]", modifiers: [.option])
                Button("Previous Step ") {
                    guard let ws = model.workspace else { return }
                    ws.playStep((ws.traces.currentStep ?? 1) - 1)
                }.keyboardShortcut("[", modifiers: [.option])
                Button("Next Step") {
                    guard let ws = model.workspace else { return }
                    ws.playStep((ws.traces.currentStep ?? -1) + 1)
                }.keyboardShortcut(.downArrow, modifiers: [.command, .option])
                Button("Previous Step") {
                    guard let ws = model.workspace else { return }
                    ws.playStep((ws.traces.currentStep ?? 1) - 1)
                }.keyboardShortcut(.upArrow, modifiers: [.command, .option])
                Divider()
                Button("Toggle Bookmark") { model.workspace?.toggleBookmark() }.keyboardShortcut("b", modifiers: [.command, .shift])
            }
            CommandMenu("Review") {
                Button("Close Review, Back to Working Copy") { model.workspace?.closeActiveReview() }
                    .keyboardShortcut("w", modifiers: [.command, .option])
                    .disabled(model.workspace?.activeReviewKey == nil)
                Divider()
                Button("Next Hunk") { model.workspace.map(ReviewNav.next) }.keyboardShortcut("j", modifiers: [.command])
                Button("Previous Hunk") { model.workspace.map(ReviewNav.previous) }.keyboardShortcut("j", modifiers: [.command, .shift])
                Button("Mark Hunk Viewed") {
                    if let ws = model.workspace, let id = ws.selectedHunkID { ws.review?.toggleViewed(id); ReviewNav.next(ws) }
                }.keyboardShortcut("v", modifiers: [.command, .shift])
            }
            CommandMenu("Claude") {
                Button("Ask…") { model.workspace?.openAsk() }.keyboardShortcut("l", modifiers: [.command])
            }
        }
        Settings { SettingsView() }
    }
}

final class AppDelegate: NSObject, NSApplicationDelegate {
    func applicationDidFinishLaunching(_ notification: Notification) {
        Log.debug("didFinishLaunching windows=\(NSApp.windows.count)")
        NSApp.setActivationPolicy(.regular)
        NSApp.activate(ignoringOtherApps: true)
    }
    func applicationShouldTerminateAfterLastWindowClosed(_ sender: NSApplication) -> Bool { true }
}

/// App-wide state: the open workspaces (one per repository window), the window in front, and
/// recently opened repositories.
@MainActor @Observable
final class AppModel {
    /// Open workspaces by repository path.
    private(set) var workspaces: [String: Workspace] = [:]
    /// The repository of the key window.
    var activePath: String?
    /// The key window's workspace; menu commands act on it.
    var workspace: Workspace? { activePath.flatMap { workspaces[$0] } }
    var focusFilter = false
    @ObservationIgnored var openSettings: (() -> Void)?
    @ObservationIgnored var openBlankWindow: (() -> Void)?
    /// Repositories waiting for a new window to take them.
    @ObservationIgnored private var pendingOpens: [String] = []
    /// Each repository's window, to bring forward instead of opening a second one.
    @ObservationIgnored var windows: [String: NSWindow] = [:]
    /// A repository passed on the command line, taken by the first window that appears.
    @ObservationIgnored private var launchPath: String?
    var recent: [String] = UserDefaults.standard.stringArray(forKey: "recentRepos") ?? []

    /// Windows asked for with New Window, which show the welcome screen; any other window that
    /// ends up without a repository is one macOS opened for a launch event and closes itself.
    @ObservationIgnored private var blankRequests = 0

    func newWindow() {
        blankRequests += 1
        openBlankWindow?()
    }

    func takeBlankRequest() -> Bool {
        guard blankRequests > 0 else { return false }
        blankRequests -= 1
        return true
    }

    init() {
        // Writes to a child process that has exited must fail with EPIPE, not kill the app.
        signal(SIGPIPE, SIG_IGN)
        Prefs.register()
        Log.debug("AppModel.init")
        DebugBridge.shared.install(self)
        NotificationCenter.default.addObserver(forName: NSApplication.willTerminateNotification, object: nil, queue: .main) { [weak self] _ in
            MainActor.assumeIsolated {
                self?.terminating = true
                self?.workspaces.values.forEach { $0.shutdown() }
            }
        }
        // Repositories open at the last quit come back, one window each.
        pendingOpens = (UserDefaults.standard.stringArray(forKey: "openRepos") ?? []).filter { FileManager.default.fileExists(atPath: $0) }
        // `-repo <path>` arrives through the arguments defaults domain. A bare path argument is
        // treated by AppKit as a document to open, which suppresses the first window.
        let args = CommandLine.arguments.dropFirst().filter { !$0.hasPrefix("-") }
        if let p = UserDefaults.standard.string(forKey: "repo") ?? args.first {
            let url = URL(fileURLWithPath: (p as NSString).expandingTildeInPath)
            if FileManager.default.fileExists(atPath: url.path) { launchPath = url.standardizedFileURL.path }
        }
        if let l = launchPath { pendingOpens.removeAll { $0 == l } }
    }

    /// A repository for a window that has none: the command-line one, then any queued by `open`.
    /// It stays pending until a window registers it, because SwiftUI may build a window's view more
    /// than once and discard the first.
    func pendingPath() -> String? {
        if let p = launchPath, windows[p] == nil { return p }
        return pendingOpens.first { windows[$0] == nil }
    }

    /// A window now shows `path`. Any repositories still waiting for a window get one.
    func registerWindow(_ window: NSWindow, for path: String) {
        windows[path] = window
        NotificationCenter.default.post(name: .spelunkWindowRegistered, object: nil)
        if launchPath == path { launchPath = nil }
        if pendingOpens.contains(path) {
            pendingOpens.removeAll { $0 == path }
            openingWindow = false
        }
        saveOpenRepositories()
        openNextPending()
    }

    /// A new window has been requested and has not yet taken its repository; one at a time, since a
    /// window may register more than once.
    @ObservationIgnored private var openingWindow = false

    private func openNextPending() {
        guard !pendingOpens.isEmpty, !openingWindow, let open = openBlankWindow else { return }
        openingWindow = true
        DispatchQueue.main.async { open() }
    }

    @ObservationIgnored private var terminating = false

    private func saveOpenRepositories() {
        guard !terminating else { return }
        UserDefaults.standard.set(windows.keys.sorted(), forKey: "openRepos")
    }

    /// Another live window already shows `path`.
    func hasOtherWindow(for path: String, than window: NSWindow?) -> Bool {
        guard let w = windows[path], w.isVisible else { return false }
        return w !== window
    }

    /// The workspace for a repository window, created and started on first use.
    func workspace(for path: String) -> Workspace {
        if let ws = workspaces[path] { return ws }
        let ws = Workspace(root: URL(fileURLWithPath: path))
        workspaces[path] = ws
        remember(path)
        Task { await ws.start() }
        return ws
    }

    /// Called when a repository's window closes.
    func release(_ path: String) {
        workspaces.removeValue(forKey: path)?.shutdown()
        windows[path] = nil
        if activePath == path { activePath = nil }
        saveOpenRepositories()
    }

    func isOpen(_ path: String) -> Bool { workspaces[path] != nil }

    private func remember(_ path: String) {
        recent.removeAll { $0 == path }
        recent.insert(path, at: 0)
        recent = Array(recent.prefix(10))
        UserDefaults.standard.set(recent, forKey: "recentRepos")
    }

    func chooseRepository() -> URL? {
        let panel = NSOpenPanel()
        panel.canChooseDirectories = true
        panel.canChooseFiles = false
        panel.prompt = "Open"
        return panel.runModal() == .OK ? panel.url : nil
    }

    /// Opens a repository in its own window (or brings its window forward).
    func openPanel() {
        if let url = chooseRepository() { open(url) }
    }

    func open(_ url: URL) {
        let path = url.standardizedFileURL.path
        if let w = windows[path] {
            w.makeKeyAndOrderFront(nil)
            return
        }
        if launchPath == path { return }
        if !pendingOpens.contains(path) { pendingOpens.append(path) }
        openNextPending()
    }
}

extension Notification.Name {
    /// A window took a repository; empty windows macOS opened for launch events can now close.
    static let spelunkWindowRegistered = Notification.Name("spelunkWindowRegistered")
}

enum ReviewNav {
    /// Every hunk in the order the review list shows it: by file, or by importance with related
    /// hunks kept together, then low-signal ones.
    @MainActor static func ordered(_ ws: Workspace, importantOnly: Bool = false) -> [Hunk] {
        guard let r = ws.review else { return [] }
        if r.listMode == .files {
            let hs = r.files.sorted { r.fileTier($0) < r.fileTier($1) }.flatMap(\.hunks)
            return importantOnly ? hs.filter { !r.tier(of: $0).isLowSignal } : hs
        }
        let main = r.tierSections.flatMap(\.hunks)
        return importantOnly ? main : main + ChangeTier.lowSignal.flatMap { r.hunks(in: $0) }
    }

    @MainActor static func next(_ ws: Workspace) { step(ws, 1, importantOnly: false) }
    @MainActor static func previous(_ ws: Workspace) { step(ws, -1, importantOnly: false) }

    /// Next important hunk not yet viewed, wrapping around.
    @MainActor static func nextImportant(_ ws: Workspace) {
        guard let r = ws.review else { return }
        let hs = ordered(ws, importantOnly: true)
        guard !hs.isEmpty else { return }
        let i = hs.firstIndex { $0.id == ws.selectedHunkID } ?? -1
        let rotated = Array(hs[(i + 1)...]) + Array(hs[...max(0, i)])
        if let h = rotated.first(where: { !r.isViewed($0) }) ?? rotated.first { ws.selectHunk(h) }
    }

    @MainActor private static func step(_ ws: Workspace, _ d: Int, importantOnly: Bool) {
        let hs = ordered(ws, importantOnly: importantOnly)
        guard !hs.isEmpty else { return }
        guard let i = hs.firstIndex(where: { $0.id == ws.selectedHunkID }) else { ws.selectHunk(hs[d > 0 ? 0 : hs.count - 1]); return }
        ws.selectHunk(hs[max(0, min(hs.count - 1, i + d))])
    }

    /// Position of the selected hunk among important hunks, as (index, count).
    @MainActor static func importantPosition(_ ws: Workspace) -> (Int, Int)? {
        let hs = ordered(ws, importantOnly: true)
        guard let i = hs.firstIndex(where: { $0.id == ws.selectedHunkID }) else { return nil }
        return (i + 1, hs.count)
    }
}

/// Single-key review commands, active while a review is open and focus is not in a text field.
enum ReviewKeys {
    /// Several monitors can briefly coexist while SwiftUI rebuilds the window; handle each event once.
    @MainActor private static var lastHandled: TimeInterval = -1

    @MainActor static func handle(_ event: NSEvent, ws: Workspace) -> Bool {
        if event.timestamp == lastHandled { return true }
        guard ws.review != nil, ws.palette == nil, ws.commentDraft == nil else { return false }
        // With vim navigation the code view's own bindings apply there (]h, [h, space v, ...).
        if Prefs.vim, event.window?.firstResponder is SourceTextView { return false }
        let mods = event.modifierFlags.intersection([.command, .option, .control])
        guard mods.isEmpty, let chars = event.charactersIgnoringModifiers?.lowercased(), chars.count == 1 else { return false }
        let shift = event.modifierFlags.contains(.shift)
        switch chars {
        case "j": shift ? ReviewNav.nextImportant(ws) : ReviewNav.next(ws)
        case "k": ReviewNav.previous(ws)
        case "v":
            guard let id = ws.selectedHunkID else { return false }
            ws.review?.toggleViewed(id)
            ReviewNav.nextImportant(ws)
        case "c": ws.draftComment()
        case "n": ws.moveThread(1)
        case "p": ws.moveThread(-1)
        case "r": ws.resolveCurrentThread()
        case "\u{1b}":
            guard ws.changeContext != nil, !ws.showsHunkContext || ws.inspectorPane != .context else { return false }
            ws.showHunkContext()
        default: return false
        }
        lastHandled = event.timestamp
        return true
    }

    /// Whether the key window's focus accepts typing, in which case letters must go to it.
    @MainActor static func focusIsTextInput() -> Bool {
        guard let r = (NSApp.keyWindow ?? NSApp.mainWindow ?? NSApp.windows.first { $0.isVisible })?.firstResponder else { return false }
        // The code view takes a caret but refuses edits, so review keys still apply there.
        if let tv = r as? NSTextView { return tv.isEditable && !(tv is SourceTextView) }
        return r is NSTextField
    }
}
