import SwiftUI

struct AskSheet: View {
    @Bindable var ws: Workspace
    @Environment(\.dismiss) var dismiss
    @State private var question = ""
    @State private var anchor = true

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack {
                Label("Ask Claude", systemImage: "sparkles").font(.headline)
                Spacer()
                ModelMenu(task: .ask)
                Button("Done") { dismiss() }.keyboardShortcut(.cancelAction)
            }
            ScrollViewReader { proxy in
                ScrollView {
                    VStack(alignment: .leading, spacing: 14) {
                        ForEach(ws.askEntries) { e in AskEntryView(ws: ws, entry: e).id(e.id) }
                    }
                    .frame(maxWidth: .infinity, alignment: .leading)
                }
                .onChange(of: ws.askEntries.count) { if let last = ws.askEntries.last { proxy.scrollTo(last.id, anchor: .bottom) } }
            }
            if ws.askEntries.isEmpty {
                Text("Claude reads the repository with read-only tools. Answers cite `file:line` locations you can click.")
                    .font(.callout).foregroundStyle(.secondary)
                Spacer()
            }
            if let a = ws.anchorDescription() {
                Toggle("Include context: \(a)", isOn: $anchor).font(.caption).lineLimit(1)
            }
            HStack {
                TextField("What does this do? Where is X handled? Why would Y happen?", text: $question, axis: .vertical)
                    .textFieldStyle(.roundedBorder)
                    .lineLimit(1...5)
                    .onSubmit(send)
                Button("Ask", action: send).keyboardShortcut(.return, modifiers: .command).disabled(question.isEmpty)
                Button("Trace") {
                    ws.generateTrace(question, includeAnchor: anchor)
                    question = ""
                    dismiss()
                }
                .disabled(question.isEmpty)
                .help("Turn this question into a step-by-step trace instead of prose")
            }
        }
        .padding(16)
        .frame(width: 720, height: 560)
    }

    private func send() {
        guard !question.isEmpty else { return }
        ws.ask(question, includeAnchor: anchor)
        question = ""
    }
}

struct AskEntryView: View {
    @Bindable var ws: Workspace
    let entry: AskEntry

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            Text(entry.question).font(.callout.weight(.semibold))
            if let a = entry.anchor { Text(a).font(.caption).foregroundStyle(.secondary) }
            if entry.running {
                HStack {
                    ProgressView().controlSize(.small)
                    Text(entry.activity.last ?? "Thinking…").font(.caption).foregroundStyle(.purple).lineLimit(1)
                }
            }
            if let e = entry.error { Text(e).foregroundStyle(.red).font(.caption) }
            if !entry.answer.isEmpty {
                CitedText(text: entry.answer) { ws.openCitation($0) }
            }
            if !entry.running && !entry.activity.isEmpty {
                DisclosureGroup("\(entry.activity.count) tool calls · $\(String(format: "%.3f", entry.cost))") {
                    ForEach(Array(entry.activity.enumerated()), id: \.offset) { _, a in
                        Text(a).font(.caption2.monospaced()).foregroundStyle(.secondary)
                    }
                }.font(.caption)
            }
        }
        .padding(10)
        .background(Color.secondary.opacity(0.06), in: RoundedRectangle(cornerRadius: 8))
    }
}

/// Markdown text where `path.rs:123` citations become clickable links.
struct CitedText: View {
    let text: String
    let open: (String) -> Void

    var body: some View {
        Text(attributed)
            .textSelection(.enabled)
            .font(.callout)
            .environment(\.openURL, OpenURLAction { url in
                if url.scheme == "spelunk" {
                    open(url.path.removingPercentEncoding.map { String($0.dropFirst()) } ?? "")
                    return .handled
                }
                return .systemAction
            })
    }

    var attributed: AttributedString {
        let pattern = #"`?([A-Za-z0-9_\-./]+\.(?:rs|toml|md|proto|sql|py|ts|go|swift)):(\d+)(?:-\d+)?`?"#
        let linked = (try? NSRegularExpression(pattern: pattern)).map { re -> String in
            let ns = text as NSString
            var out = ""
            var last = 0
            for m in re.matches(in: text, range: NSRange(location: 0, length: ns.length)) {
                out += ns.substring(with: NSRange(location: last, length: m.range.location - last))
                let path = ns.substring(with: m.range(at: 1)), line = ns.substring(with: m.range(at: 2))
                let enc = "\(path):\(line)".addingPercentEncoding(withAllowedCharacters: .urlPathAllowed) ?? ""
                out += "[\(path.lastPathComponent):\(line)](spelunk:///\(enc))"
                last = NSMaxRange(m.range)
            }
            out += ns.substring(from: last)
            return out
        } ?? text
        return (try? AttributedString(markdown: linked, options: .init(interpretedSyntax: .inlineOnlyPreservingWhitespace)))
            ?? AttributedString(text)
    }
}

struct SettingsView: View {
    @AppStorage("rustAnalyzerPath") var raPath = ""
    @AppStorage("claudePath") var claudePath = ""
    @AppStorage("fontSize") var fontSize = 13.0
    @AppStorage("autoStartRA") var autoStart = true
    @AppStorage("review.autoClassify") var autoClassify = true
    @AppStorage("settings.tab") var tab = "general"
    @State private var detected = "…"

    var body: some View {
        TabView(selection: $tab) {
            general.tabItem { Label("General", systemImage: "gearshape") }.tag("general")
            LanguagesSettings().tabItem { Label("Languages", systemImage: "chevron.left.forwardslash.chevron.right") }.tag("languages")
        }
        .frame(width: 680, height: 560)
    }

    var general: some View {
        Form {
            Section("rust-analyzer") {
                TextField("Path (empty = auto-detect)", text: $raPath)
                Text(verbatim: "Detected: \(detected)").font(.caption).foregroundStyle(.secondary)
                    .task { detected = await RustAnalyzer.resolveBinary() ?? "none" }
                Toggle("Start automatically for Cargo workspaces", isOn: $autoStart)
            }
            Section("Review") {
                HStack {
                    Button("Edit My Rules…") { RulesFiles.openUserRules() }
                    Button("View Default Rules") { RulesFiles.openDefaults() }
                }
                Text("Rules decide each hunk's tier. Your rules (and a repository's .spelunk/review.rules) run before the defaults; the first match wins. Edits apply on the next refresh.")
                    .font(.caption).foregroundStyle(.secondary)
                Toggle("Classify new hunks with Claude automatically", isOn: $autoClassify)
                Text("Runs the quick classification model on hunks the static rules cannot settle. Results are cached by hunk content.")
                    .font(.caption).foregroundStyle(.secondary)
            }
            ClaudeSettingsSection()
            Section("Claude CLI") {
                TextField("claude CLI path (empty = PATH)", text: $claudePath)
            }
            Section("Editor") {
                Stepper("Font size: \(Int(fontSize))", value: $fontSize, in: 9...24)
            }
        }
        .formStyle(.grouped)
    }
}
