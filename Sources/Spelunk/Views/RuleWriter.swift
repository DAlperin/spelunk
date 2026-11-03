import SwiftUI

/// Drafts a review rule from a plain-language description, validates it with the real parser, and
/// appends it to the user's or the repository's rules file.
struct RuleWriterSheet: View {
    @Bindable var ws: Workspace
    @Environment(\.dismiss) var dismiss
    @State private var description = ""
    @State private var draft = ""
    @State private var working = false
    @State private var error: String?
    @State private var toRepo = false

    var parsed: (rules: [ReviewRule], attachments: [AttachRule], disabled: Set<String>, errors: [String]) {
        RuleParser.parseAll(draft, source: "draft")
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack {
                Label("New Rule from Description", systemImage: "wand.and.stars").font(.headline)
                Spacer()
                ModelMenu(task: .rules)
            }
            TextField("e.g. for every rust benchmark file changed, attach a box plot; flag changes reachable from the peek path", text: $description, axis: .vertical)
                .textFieldStyle(.roundedBorder).lineLimit(2...5)
                .onSubmit(generate)
            HStack {
                Button(draft.isEmpty ? "Draft Rule" : "Redraft", action: generate).disabled(description.isEmpty || working)
                if working { ProgressView().controlSize(.small) }
                if let error { Text(error).font(.caption).foregroundStyle(.red).lineLimit(2) }
                Spacer()
            }
            TextEditor(text: $draft)
                .font(.system(size: 12, design: .monospaced))
                .frame(minHeight: 200)
                .overlay(RoundedRectangle(cornerRadius: 4).stroke(Color.secondary.opacity(0.3)))
            let p = parsed
            if !draft.isEmpty {
                if p.errors.isEmpty {
                    Text(verbatim: "Parses: \(p.rules.count) rules, \(p.attachments.count) attachments" + (p.disabled.isEmpty ? "" : ", disables \(p.disabled.count)"))
                        .font(.caption).foregroundStyle(.green)
                } else {
                    Text(p.errors.joined(separator: "\n")).font(.caption).foregroundStyle(.red)
                }
            }
            HStack {
                Picker("Add to", selection: $toRepo) {
                    Text("My rules").tag(false)
                    Text("This repository (.spelunk/review.rules)").tag(true)
                }
                .fixedSize()
                Spacer()
                Button("Cancel") { dismiss() }.keyboardShortcut(.cancelAction)
                Button("Add Rule") {
                    do {
                        try RulesFiles.append(draft, toRepo: toRepo ? ws.root : nil)
                        ws.statusMessage = "Rule added; re-classifying"
                        Task { await ws.review?.load() }
                        dismiss()
                    } catch { self.error = error.localizedDescription }
                }
                .keyboardShortcut(.defaultAction)
                .disabled(draft.isEmpty || !p.errors.isEmpty)
            }
        }
        .padding(16)
        .frame(width: 680, height: 560)
    }

    private func generate() {
        guard !description.isEmpty else { return }
        working = true
        error = nil
        let system = ClaudeTasks.ruleWriterSystem(reference: RulesFiles.reference, defaults: DefaultRules.text)
        var prompt = "Write rules for: \(description)"
        if !draft.isEmpty { prompt += "\n\nThe previous draft, to revise:\n\(draft)" }
        let errs = parsed.errors
        if !errs.isEmpty { prompt += "\n\nIt failed to parse:\n" + errs.joined(separator: "\n") }
        Task {
            defer { working = false }
            do {
                let r = try await Claude.run(prompt: prompt, system: system, cwd: ws.root, task: .rules, tools: ["Read", "Grep", "Glob"])
                draft = r.text.replacingOccurrences(of: "```", with: "").trimmingCharacters(in: .whitespacesAndNewlines)
            } catch {
                self.error = error.localizedDescription
            }
        }
    }
}
