import SwiftUI

/// The Settings window: every preference from `Prefs`, grouped by area.
struct SettingsView: View {
    @AppStorage("settings.tab") var tab = "general"

    var body: some View {
        TabView(selection: $tab) {
            GeneralSettings().tabItem { Label("General", systemImage: "gearshape") }.tag("general")
            EditorSettings().tabItem { Label("Editor", systemImage: "text.alignleft") }.tag("editor")
            ReviewSettings().tabItem { Label("Review", systemImage: "checklist") }.tag("review")
            ClaudeSettings().tabItem { Label("Claude", systemImage: "sparkles") }.tag("claude")
            IntelligenceSettings().tabItem { Label("Code Intelligence", systemImage: "point.3.connected.trianglepath.dotted") }.tag("intel")
            LanguagesSettings().tabItem { Label("Languages", systemImage: "chevron.left.forwardslash.chevron.right") }.tag("languages")
        }
        .frame(width: 700, height: 580)
    }
}

/// A caption under a setting.
private struct Note: View {
    let text: String
    init(_ text: String) { self.text = text }
    var body: some View { Text(text).font(.caption).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true) }
}

private struct GeneralSettings: View {
    var body: some View {
        Form {
            Section("Review rules") {
                HStack {
                    Button("Edit My Rules…") { RulesFiles.openUserRules() }
                    Button("View Default Rules") { RulesFiles.openDefaults() }
                }
                Note("Rules decide each hunk's tier. Your rules run first, then a repository's .spelunk/review.rules, then the defaults; the first match wins.")
            }
            Section("Windows") {
                Note("Each repository opens in its own window (⌘O). ⌘N opens a new window. Windows come back on relaunch.")
            }
        }
        .formStyle(.grouped)
    }
}

private struct EditorSettings: View {
    @AppStorage(Prefs.Key.fontSize) var fontSize = 13.0
    @AppStorage(Prefs.Key.lineSpacing) var lineSpacing = 1.18
    @AppStorage(Prefs.Key.tabWidth) var tabWidth = 4
    @AppStorage(Prefs.Key.minimap) var minimap = true
    @AppStorage(Prefs.Key.minimapWidth) var minimapWidth = 70.0
    @AppStorage(Prefs.Key.hunkBoundary) var hunkBoundary = true
    @AppStorage(Prefs.Key.hoverEnabled) var hover = true
    @AppStorage(Prefs.Key.hoverDelay) var hoverDelay = 0.6
    @AppStorage(Prefs.Key.vim) var vim = false
    @AppStorage(Prefs.Key.foldMode) var foldMode = "review"

    var body: some View {
        Form {
            Section("Text") {
                Stepper(value: $fontSize, in: 9...24) { Text(verbatim: "Font size: \(Int(fontSize)) pt") }
                Stepper(value: $lineSpacing, in: 1.0...1.8, step: 0.04) { Text(verbatim: String(format: "Line spacing: %.2f", lineSpacing)) }
                Stepper(value: $tabWidth, in: 1...8) { Text(verbatim: "Tab width: \(tabWidth) spaces") }
                Note("Text settings apply when a file is next opened.")
            }
            Section("Review aids") {
                Toggle("Draw the selected hunk's boundary", isOn: $hunkBoundary)
                Toggle("Show the minimap", isOn: $minimap)
                if minimap {
                    Slider(value: $minimapWidth, in: 40...140) { Text(verbatim: "Minimap width: \(Int(minimapWidth)) pt") }
                }
            }
            Section("Folding") {
                Picker("Start with function bodies folded", selection: $foldMode) {
                    ForEach(FoldMode.allCases) { Text($0.label).tag($0.rawValue) }
                }
                Note("Folds apply to files opened after the change. A jump into a folded function unfolds it; click a fold's placeholder to open it, or use Navigate › Fold Function (⌥⌘←) and Unfold Function (⌥⌘→).")
            }
            Section("Keyboard") {
                Toggle("Vim navigation in the code view", isOn: $vim)
                Note("Motions (hjkl, w b e, 0 ^ $, gg G, H M L, Ctrl-d/u, { } %, f t ; ,), search (/ n N * #), visual v V with y to copy, gd definition, gh hover, Ctrl-o / Ctrl-i back and forward, za zo zc zM zR folds. In a review, J and K move between hunks and c comments; ]u is the next unviewed hunk, ]t [t move between threads, and space v, space r, space a and space p mark viewed, resolve, ask and add to the code path.")
            }
            Section("Hover") {
                Toggle("Show symbol details on hover", isOn: $hover)
                if hover {
                    Slider(value: $hoverDelay, in: 0.2...2.0) { Text(verbatim: String(format: "Delay: %.1f s", hoverDelay)) }
                }
            }
        }
        .formStyle(.grouped)
    }
}

private struct ReviewSettings: View {
    @AppStorage(Prefs.Key.autoClassify) var autoClassify = true
    @AppStorage(Prefs.Key.ignoreWhitespace) var ignoreWhitespace = true
    @AppStorage(Prefs.Key.quickBatch) var quickBatch = 120
    @AppStorage(Prefs.Key.groupRelated) var groupRelated = true
    @AppStorage(Prefs.Key.groupMaxGroups) var maxGroups = 80
    @AppStorage(Prefs.Key.groupOverlap) var overlap = 0.6
    @AppStorage(Prefs.Key.groupDistinctLength) var plainLength = 14
    @AppStorage(Prefs.Key.refreshDelay) var refreshDelay = 0.6
    @AppStorage(Prefs.Key.autoAttachments) var autoAttachments = true

    var body: some View {
        Form {
            Section("Diff") {
                Toggle("Ignore whitespace changes", isOn: Binding(get: { ignoreWhitespace }, set: { Prefs.setIgnoreWhitespace($0) }))
                Note("Hunks that only change whitespace are left out, and changed lines are compared without it. A pull request whose commits cannot be fetched uses GitHub's diff, which always includes whitespace.")
            }
            Section("Classification") {
                Toggle("Classify new hunks with Claude automatically", isOn: $autoClassify)
                Stepper(value: $quickBatch, in: 20...400, step: 20) { Text(verbatim: "Hunks per classification request: \(quickBatch)") }
                Note("The quick pass sends hunks the rules cannot settle. Results are cached by hunk content and never resent.")
            }
            Section("Grouping") {
                Toggle("Keep related hunks together in the list", isOn: $groupRelated)
                Stepper(value: $maxGroups, in: 10...200, step: 10) { Text(verbatim: "Most groups per review: \(maxGroups)") }
                Slider(value: $overlap, in: 0.3...0.9) { Text(verbatim: String(format: "Merge groups sharing %.0f%% of hunks", overlap * 100)) }
                Stepper(value: $plainLength, in: 8...30) { Text(verbatim: "Plain words group only when \(plainLength)+ characters") }
                Note("Groups form around identifiers a change adds or removes in several places. Snake case, camel case and names with digits always count; plain words only when long.")
            }
            Section("Live review") {
                Slider(value: $refreshDelay, in: 0.2...3.0) { Text(verbatim: String(format: "Refresh %.1f s after files change", refreshDelay)) }
                Toggle("Run attachments marked auto", isOn: $autoAttachments)
                Note("Commands from a repository's own rules file still need that repository to be trusted.")
            }
        }
        .formStyle(.grouped)
    }
}

private struct ClaudeSettings: View {
    @AppStorage(Prefs.Key.claudePath) var claudePath = ""
    @AppStorage(Prefs.Key.claudeConcurrency) var concurrency = 4
    @AppStorage(Prefs.Key.claudeTimeoutMinutes) var timeout = 30
    @AppStorage(Prefs.Key.keepJobs) var keepJobs = 60
    @AppStorage(Prefs.Key.cacheDays) var cacheDays = 90

    var body: some View {
        Form {
            ClaudeSettingsSection()
            Section("Runs") {
                Stepper(value: $concurrency, in: 1...12) { Text(verbatim: "At most \(concurrency) Claude sessions at once") }
                Stepper(value: $timeout, in: 2...120, step: 2) { Text(verbatim: "Stop a session after \(timeout) min") }
                Stepper(value: $keepJobs, in: 10...500, step: 10) { Text(verbatim: "Keep the last \(keepJobs) asks and traces") }
                Stepper(value: $cacheDays, in: 7...365, step: 7) { Text(verbatim: "Forget cached results unused for \(cacheDays) days") }
            }
            Section("Claude CLI") {
                TextField("Path (empty: found on PATH)", text: $claudePath)
                Note("Sessions load your user settings only, with hooks disabled, since they often run in a checkout of someone else's change.")
            }
        }
        .formStyle(.grouped)
    }
}

private struct IntelligenceSettings: View {
    @AppStorage(Prefs.Key.autoStartServers) var autoStart = true
    @AppStorage(Prefs.Key.rustAnalyzerPath) var raPath = ""
    @AppStorage(Prefs.Key.sourceKitPath) var skPath = ""
    @AppStorage(Prefs.Key.lakePath) var lakePath = ""
    @AppStorage(Prefs.Key.scipFirst) var scipFirst = true
    @AppStorage(Prefs.Key.openDocuments) var openDocuments = 24
    @AppStorage(Prefs.Key.documentCacheSize) var cacheSize = 300
    @AppStorage(Prefs.Key.headServer) var headServer = false
    @State private var detectedRA = "…"
    @State private var detectedSK = "…"
    @State private var detectedLake = "…"

    var body: some View {
        Form {
            Section("Language servers") {
                Toggle("Start language servers automatically", isOn: $autoStart)
                TextField("rust-analyzer path (empty: detect)", text: $raPath)
                Note("Detected: \(detectedRA)")
                TextField("sourcekit-lsp path (empty: detect)", text: $skPath)
                Note("Detected: \(detectedSK)")
                TextField("lake path for Lean (empty: detect)", text: $lakePath)
                Note("Detected: \(detectedLake). Runs `lake serve` in the folder holding the lakefile.")
                Stepper(value: $openDocuments, in: 4...100, step: 4) { Text(verbatim: "Keep \(openDocuments) files open in each server") }
            }
            .task {
                detectedRA = await LanguageServer.resolveBinary(.rust) ?? "none"
                detectedSK = await LanguageServer.resolveBinary(.swift) ?? "none"
                detectedLake = await LanguageServer.resolveBinary(.lean) ?? "none"
            }
            Section("Reviews") {
                Toggle("Index pull request heads with their own rust-analyzer", isOn: $headServer)
                Note("Answers for code in a pull request then come from the PR's own code instead of the working copy at the matching position. Costs a second full index (memory and a few minutes) per open PR; it can also be started from the PR header.")
            }
            Section("Fallbacks") {
                Toggle("Answer from the SCIP index while rust-analyzer warms up", isOn: $scipFirst)
                Stepper(value: $cacheSize, in: 50...2000, step: 50) { Text(verbatim: "Keep \(cacheSize) parsed files in memory") }
                Note("Without a language server, answers come from SCIP, tree-sitter and text search, and are labelled with their source.")
            }
        }
        .formStyle(.grouped)
    }
}
