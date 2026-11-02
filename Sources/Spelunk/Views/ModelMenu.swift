import SwiftUI

/// Compact picker for the model and effort a Claude feature uses.
struct ModelMenu: View {
    let task: ClaudeTask
    @AppStorage private var model: String
    @AppStorage private var effort: String

    init(task: ClaudeTask) {
        self.task = task
        _model = AppStorage(wrappedValue: "", task.modelKey)
        _effort = AppStorage(wrappedValue: "", task.effortKey)
    }

    var current: String { model.isEmpty ? task.defaultModel : model }

    var body: some View {
        Menu {
            Section("Model for \(task.label.lowercased())") {
                ForEach(ClaudeModels.aliases, id: \.id) { m in
                    Button { model = m.id } label: {
                        if current == m.id { Label(m.label, systemImage: "checkmark") } else { Text(m.label) }
                    }
                }
            }
            Section("Effort") {
                Button { effort = "" } label: { effort.isEmpty ? Label("Default", systemImage: "checkmark") : Label("Default", systemImage: "") }
                ForEach(ClaudeModels.efforts, id: \.self) { e in
                    Button { effort = e } label: {
                        if effort == e { Label(e, systemImage: "checkmark") } else { Text(e) }
                    }
                }
            }
        } label: {
            Text(ClaudeModels.label(current) + (effort.isEmpty ? "" : " · \(effort)"))
                .font(.caption)
        }
        .menuStyle(.borderlessButton)
        .fixedSize()
        .help("Claude model and effort for \(task.label.lowercased())")
    }
}

/// Per-task model settings, including full model names.
struct ClaudeSettingsSection: View {
    var body: some View {
        Section("Claude models") {
            ForEach(ClaudeTask.allCases) { t in ClaudeTaskRow(task: t) }
            Text("Aliases (fable, opus, sonnet, haiku) resolve to the latest model in each family. Full model names such as claude-opus-5-5 also work.")
                .font(.caption).foregroundStyle(.secondary)
        }
    }
}

private struct ClaudeTaskRow: View {
    let task: ClaudeTask
    @AppStorage private var model: String
    @AppStorage private var effort: String

    init(task: ClaudeTask) {
        self.task = task
        _model = AppStorage(wrappedValue: "", task.modelKey)
        _effort = AppStorage(wrappedValue: "", task.effortKey)
    }

    var body: some View {
        HStack {
            Text(task.label).frame(width: 110, alignment: .leading)
            TextField("model", text: $model, prompt: Text(task.defaultModel))
                .frame(width: 150)
            Menu("Presets") {
                ForEach(ClaudeModels.aliases, id: \.id) { m in Button(m.label) { model = m.id } }
            }.fixedSize()
            Picker("", selection: $effort) {
                Text("default effort").tag("")
                ForEach(ClaudeModels.efforts, id: \.self) { Text($0).tag($0) }
            }.labelsHidden().frame(width: 130)
        }
    }
}
