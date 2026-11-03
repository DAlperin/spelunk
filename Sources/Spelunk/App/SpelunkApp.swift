import AppKit
import SwiftUI

@main
struct SpelunkApp: App {
    @NSApplicationDelegateAdaptor(AppDelegate.self) var delegate
    @State private var model = AppModel()

    var body: some Scene {
        WindowGroup("Spelunk") {
            RootView()
                .environment(model)
                .frame(minWidth: 1000, minHeight: 640)
        }
        .defaultSize(width: 1560, height: 980)
        .windowToolbarStyle(.unified(showsTitle: false))
        .commands {
            CommandGroup(replacing: .newItem) {
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
            }
            CommandMenu("Code Paths") {
                Button("Add Location to Code Path") { model.workspace?.addCurrentToTrace() }.keyboardShortcut("t", modifiers: [.command, .shift])
                Button("New Code Path") { model.workspace?.newCodePath(fromCursor: false) }
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

@MainActor @Observable
final class AppModel {
    var workspace: Workspace?
    var focusFilter = false
    @ObservationIgnored var openSettings: (() -> Void)?
    var recent: [String] = UserDefaults.standard.stringArray(forKey: "recentRepos") ?? []

    init() {
        // Writes to a child process that has exited must fail with EPIPE, not kill the app.
        signal(SIGPIPE, SIG_IGN)
        Log.debug("AppModel.init")
        DebugBridge.shared.install(self)
        let args = CommandLine.arguments.dropFirst().filter { !$0.hasPrefix("-") }
        if let p = args.first {
            let url = URL(fileURLWithPath: (p as NSString).expandingTildeInPath)
            if FileManager.default.fileExists(atPath: url.path) { open(url) }
        }
    }

    func openPanel() {
        let panel = NSOpenPanel()
        panel.canChooseDirectories = true
        panel.canChooseFiles = false
        panel.prompt = "Open"
        if panel.runModal() == .OK, let url = panel.url { open(url) }
    }

    func open(_ url: URL) {
        workspace?.shutdown()
        let ws = Workspace(root: url)
        workspace = ws
        recent.removeAll { $0 == url.path }
        recent.insert(url.path, at: 0)
        recent = Array(recent.prefix(10))
        UserDefaults.standard.set(recent, forKey: "recentRepos")
        Task { await ws.start() }
    }
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
        case "c":
            guard ws.review?.pullRequest != nil else { return false }
            ws.draftComment()
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
        if let tv = r as? NSTextView { return tv.isEditable }
        return r is NSTextField
    }
}
