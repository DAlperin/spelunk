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
                Button("Quick Open…") { model.workspace?.sidebarTab = .files; model.focusFilter.toggle() }.keyboardShortcut("p")
                Button("Find in Repository…") { model.workspace?.sidebarTab = .search }.keyboardShortcut("f", modifiers: [.command, .shift])
            }
            CommandMenu("Trace") {
                Button("Add Location to Trace") { model.workspace?.addCurrentToTrace() }.keyboardShortcut("t", modifiers: [.command, .shift])
                Button("Toggle Recording") {
                    guard let ws = model.workspace else { return }
                    if ws.traces.isRecording { ws.traces.isRecording = false } else { ws.traces.startRecording(from: nil) }
                }.keyboardShortcut("r", modifiers: [.command, .shift])
                Divider()
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
                Button("Previous Hunk") { model.workspace.map(ReviewNav.previous) }.keyboardShortcut("k", modifiers: [.command])
                Button("Mark Hunk Viewed") {
                    if let ws = model.workspace, let id = ws.selectedHunkID { ws.review?.toggleViewed(id); ReviewNav.next(ws) }
                }.keyboardShortcut("v", modifiers: [.command, .shift])
            }
            CommandMenu("Claude") {
                Button("Ask…") { model.workspace?.showAsk = true }.keyboardShortcut("l", modifiers: [.command])
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
    var recent: [String] = UserDefaults.standard.stringArray(forKey: "recentRepos") ?? []

    init() {
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
    @MainActor static func ordered(_ ws: Workspace) -> [Hunk] {
        guard let r = ws.review else { return [] }
        return ChangeTier.allCases.filter { !r.hideTiers.contains($0) }.flatMap { r.hunks(in: $0) }
    }

    @MainActor static func next(_ ws: Workspace) {
        let hs = ordered(ws)
        guard !hs.isEmpty else { return }
        let i = hs.firstIndex { $0.id == ws.selectedHunkID } ?? -1
        ws.selectHunk(hs[min(hs.count - 1, i + 1)])
    }

    @MainActor static func previous(_ ws: Workspace) {
        let hs = ordered(ws)
        guard !hs.isEmpty else { return }
        let i = hs.firstIndex { $0.id == ws.selectedHunkID } ?? 1
        ws.selectHunk(hs[max(0, i - 1)])
    }
}
