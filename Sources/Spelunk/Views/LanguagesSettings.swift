import AppKit
import SwiftUI

extension Notification.Name {
    static let grammarsChanged = Notification.Name("spelunk.grammarsChanged")
}

/// Installs and manages tree-sitter grammars for languages other than Rust.
struct LanguagesSettings: View {
    @State private var grammars: [LoadedGrammar] = GrammarRegistry.shared.all
    @State private var url = ""
    @State private var subdirectory = ""
    @State private var revision = ""
    @State private var installing = false
    @State private var log: [String] = []

    var body: some View {
        Form {
            Section("Installed grammars") {
                if grammars.isEmpty {
                    Text("None yet. Rust is built in; other languages use a basic highlighter until a grammar is installed.")
                        .font(.caption).foregroundStyle(.secondary)
                }
                ForEach(grammars, id: \.spec.name) { g in
                    HStack(alignment: .firstTextBaseline) {
                        Circle().fill(g.language != nil && g.error == nil ? Color.green : Color.orange).frame(width: 7, height: 7)
                        VStack(alignment: .leading, spacing: 2) {
                            HStack {
                                Text(g.spec.displayName).fontWeight(.medium)
                                Text(g.spec.extensions.map { ".\($0)" }.joined(separator: " ")).font(.caption.monospaced()).foregroundStyle(.secondary)
                            }
                            Text(statusLine(g)).font(.caption).foregroundStyle(g.error == nil ? Color.secondary : Color.orange)
                        }
                        Spacer()
                        Menu("Edit") {
                            Button("Edit highlights.scm") { NSWorkspace.shared.open(g.highlightsURL) }
                            Button("Edit tags.scm (outline)") { NSWorkspace.shared.open(g.tagsURL) }
                            Button("Reveal in Finder") { NSWorkspace.shared.activateFileViewerSelecting([g.directory]) }
                        }.fixedSize()
                        Button("Remove", role: .destructive) {
                            GrammarRegistry.shared.remove(g.spec.name)
                            refresh()
                        }
                    }
                }
                HStack {
                    Button("Reload queries") { GrammarRegistry.shared.reload(); refresh() }
                    Button("Open grammars folder") { NSWorkspace.shared.open(GrammarRegistry.shared.directory) }
                }
            }
            Section("Add a grammar") {
                HStack {
                    TextField("Git URL", text: $url, prompt: Text("https://github.com/tree-sitter/tree-sitter-python"))
                    Menu("Presets") {
                        ForEach(GrammarRegistry.presets) { p in
                            Button(p.label) { url = p.url; subdirectory = p.subdirectory ?? ""; revision = p.revision ?? "" }
                        }
                    }.fixedSize()
                }
                HStack {
                    TextField("Subdirectory (optional)", text: $subdirectory)
                    TextField("Tag or branch (optional)", text: $revision)
                }
                HStack {
                    Button(installing ? "Installing…" : "Install") { install() }
                        .disabled(url.isEmpty || installing)
                    if installing { ProgressView().controlSize(.small) }
                }
                Text("Clones the repository, compiles src/parser.c (and any scanner) into a dylib with the system compiler, and copies queries/highlights.scm and queries/tags.scm. Grammars declared in tree-sitter.json are installed together with their file types.")
                    .font(.caption).foregroundStyle(.secondary)
                if !log.isEmpty {
                    ScrollView {
                        VStack(alignment: .leading, spacing: 2) {
                            ForEach(Array(log.enumerated()), id: \.offset) { _, l in Text(l).font(.caption.monospaced()).textSelection(.enabled) }
                        }.frame(maxWidth: .infinity, alignment: .leading)
                    }.frame(height: 140)
                }
            }
        }
        .formStyle(.grouped)
    }

    private func statusLine(_ g: LoadedGrammar) -> String {
        if let e = g.error { return e }
        var parts = ["ABI \(g.language?.ABIVersion ?? 0)"]
        parts.append(g.highlights == nil ? "no highlights" : "highlights")
        parts.append(g.tags == nil ? "no outline" : "outline")
        parts.append(g.spec.repository.replacingOccurrences(of: "https://github.com/", with: ""))
        return parts.joined(separator: " · ")
    }

    private func refresh() {
        grammars = GrammarRegistry.shared.all
        NotificationCenter.default.post(name: .grammarsChanged, object: nil)
    }

    private func install() {
        installing = true
        log = []
        let u = url, sub = subdirectory, rev = revision
        Task {
            do {
                let specs = try await GrammarRegistry.shared.install(url: u, subdirectory: sub.isEmpty ? nil : sub, revision: rev.isEmpty ? nil : rev) { line in
                    Task { @MainActor in log.append(line) }
                }
                log.append(specs.isEmpty ? "Nothing installed." : "Done: \(specs.map(\.displayName).joined(separator: ", "))")
                url = ""; subdirectory = ""; revision = ""
            } catch {
                log.append("Error: \(error.localizedDescription)")
            }
            installing = false
            refresh()
        }
    }
}
