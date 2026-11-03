import SwiftUI

/// Claude runs for this workspace: a question box on top and every ask and generated path below,
/// newest first. Runs are independent, so several can be in flight while you keep reading.
struct ClaudePane: View {
    @Bindable var ws: Workspace
    @State private var question = ""
    @State private var anchor = true
    @FocusState private var focused: Bool

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            composer
            Divider()
            if ws.jobs.isEmpty {
                Text("Claude reads the repository with read-only tools. Ask answers in prose with clickable `file:line` citations; Trace turns the question into a code path. Start as many as you like.")
                    .font(.callout).foregroundStyle(.secondary).padding(12)
                Spacer()
            } else {
                List {
                    ForEach(ws.jobs.reversed()) { j in
                        ClaudeJobCard(ws: ws, job: j)
                            .listRowSeparator(.hidden)
                            .listRowInsets(EdgeInsets(top: 4, leading: 10, bottom: 4, trailing: 10))
                    }
                }
                .listStyle(.plain)
                .scrollContentBackground(.hidden)
                footer
            }
        }
        .onAppear { ws.markJobsSeen(); focused = true }
        .onChange(of: ws.askFocus) { focused = true }
        .onChange(of: ws.jobs.count) { ws.markJobsSeen() }
    }

    var composer: some View {
        VStack(alignment: .leading, spacing: 6) {
            TextField("What does this do? Where is X handled? How does a peek reach the replica?", text: $question, axis: .vertical)
                .textFieldStyle(.roundedBorder)
                .lineLimit(1...6)
                .focused($focused)
                .onSubmit(ask)
            if let a = ws.anchorDescription() {
                Toggle(isOn: $anchor) { Text(verbatim: a).lineLimit(1).truncationMode(.middle) }
                    .toggleStyle(.checkbox).font(.caption).help("Tell Claude where you are looking")
            }
            HStack(spacing: 6) {
                Button("Ask", action: ask).keyboardShortcut(.return, modifiers: .command).disabled(question.isEmpty)
                ModelMenu(task: .ask)
                Button("Trace") {
                    ws.generateTrace(question, includeAnchor: anchor)
                    question = ""
                }
                .keyboardShortcut(.return, modifiers: [.command, .shift])
                .disabled(question.isEmpty)
                .help("Turn the question into a code path (⇧⌘↩)")
                ModelMenu(task: .trace)
                Spacer()
            }
            .controlSize(.small)
        }
        .padding(10)
    }

    var footer: some View {
        HStack {
            let running = ws.runningJobs.count
            Text(verbatim: running > 0 ? "\(running) running" : "\(ws.jobs.count) finished").font(.caption).foregroundStyle(.secondary)
            Spacer()
            Button("Clear finished") { ws.clearFinishedJobs() }.disabled(ws.jobs.allSatisfy(\.running))
        }
        .buttonStyle(.link).font(.caption)
        .padding(.horizontal, 12).frame(height: 28)
    }

    private func ask() {
        guard !question.isEmpty else { return }
        ws.ask(question, includeAnchor: anchor)
        question = ""
    }
}

struct ClaudeJobCard: View {
    @Bindable var ws: Workspace
    let job: ClaudeJob
    @State private var expanded = true

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            HStack(alignment: .firstTextBaseline, spacing: 6) {
                Image(systemName: job.kind == .trace ? "point.topleft.down.to.point.bottomright.curvepath" : "sparkles")
                    .font(.caption).foregroundStyle(.purple)
                Text(job.question).font(.callout.weight(.semibold)).lineLimit(expanded ? 4 : 1)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .contentShape(Rectangle())
                    .onTapGesture { expanded.toggle() }
                if job.running {
                    Button { ws.cancelJob(job.id) } label: { Image(systemName: "stop.circle") }.help("Cancel")
                } else {
                    Menu {
                        Button("Run Again") {
                            if job.kind == .trace { ws.generateTrace(job.question, includeAnchor: false, force: true) } else { ws.ask(job.question, includeAnchor: false, force: true) }
                        }
                        Button("Copy Answer") {
                            NSPasteboard.general.clearContents()
                            NSPasteboard.general.setString(job.answer, forType: .string)
                        }.disabled(job.answer.isEmpty)
                        Divider()
                        Button("Remove", role: .destructive) { ws.removeJob(job.id) }
                    } label: { Image(systemName: "ellipsis") }
                    .menuStyle(.borderlessButton).menuIndicator(.hidden).fixedSize()
                }
            }
            .buttonStyle(.borderless)
            HStack(spacing: 4) {
                Text(verbatim: "\(job.kind.rawValue) · \(job.model)")
                if let a = job.anchor { Text("·"); Text(verbatim: a).lineLimit(1).truncationMode(.middle) }
            }
            .font(.caption2).foregroundStyle(.tertiary)
            if job.running {
                HStack(spacing: 6) {
                    ProgressView().controlSize(.small)
                    Text(job.status).font(.caption).foregroundStyle(.purple).lineLimit(1).truncationMode(.tail)
                    Spacer()
                    TimelineView(.periodic(from: job.started, by: 1)) { ctx in
                        Text(verbatim: "\(Int(ctx.date.timeIntervalSince(job.started)))s").font(.caption.monospacedDigit()).foregroundStyle(.secondary)
                    }
                }
            }
            if expanded {
                if let e = job.error { Text(e).foregroundStyle(.red).font(.caption) }
                if job.kind == .trace {
                    if job.traceID != nil {
                        HStack {
                            Text(job.answer).font(.caption).foregroundStyle(.secondary)
                            Button("Open Code Path") { ws.openJobTrace(job.id) }.controlSize(.small)
                        }
                    }
                } else if !job.answer.isEmpty {
                    CitedText(text: job.answer) { ws.openCitation($0) }
                }
                if !job.running && !job.activity.isEmpty {
                    DisclosureGroup(job.status + " · \(job.activity.count) tool calls") {
                        ForEach(Array(job.activity.enumerated()), id: \.offset) { _, a in
                            Text(a).font(.caption2.monospaced()).foregroundStyle(.secondary).lineLimit(2)
                        }
                    }.font(.caption).foregroundStyle(.secondary)
                } else if !job.running {
                    Text(job.status).font(.caption).foregroundStyle(.secondary)
                }
            }
        }
        .padding(10)
        .background(Color.secondary.opacity(0.06), in: RoundedRectangle(cornerRadius: 8))
        .overlay(RoundedRectangle(cornerRadius: 8).stroke(job.running ? Color.purple.opacity(0.35) : Color.clear))
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

