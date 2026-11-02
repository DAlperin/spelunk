import SwiftUI

enum InspectorTab: String, CaseIterable, Identifiable {
    case trace = "Trace", outline = "Outline", bookmarks = "Bookmarks", problems = "Problems"
    var id: String { rawValue }
}

struct InspectorView: View {
    @Bindable var ws: Workspace
    @State private var tab: InspectorTab = .trace

    @State private var split: CGFloat = 0.5
    @State private var dragStart: CGFloat?

    var body: some View {
        GeometryReader { geo in
            let total = geo.size.height
            let topHeight = max(140, min(total - 180, total * split))
            VStack(spacing: 0) {
                ScrollView {
                    if let c = ws.context { ContextSection(ws: ws, ctx: c) } else {
                        Text("Click a symbol to see its definition, references and call paths. ⌘-click jumps to the definition.")
                            .font(.callout).foregroundStyle(.secondary).padding()
                    }
                }
                .frame(height: topHeight)
                Divider()
                    .overlay(Color.secondary.opacity(0.001).frame(height: 8).contentShape(Rectangle()))
                    .gesture(DragGesture(minimumDistance: 1)
                        .onChanged { v in
                            if dragStart == nil { dragStart = split }
                            split = min(0.85, max(0.15, (dragStart ?? split) + v.translation.height / max(1, total)))
                        }
                        .onEnded { _ in dragStart = nil })
                    .onHover { inside in if inside { NSCursor.resizeUpDown.push() } else { NSCursor.pop() } }
                VStack(spacing: 0) {
                    Picker("", selection: $tab) {
                        ForEach(InspectorTab.allCases) { Text($0.rawValue).tag($0) }
                    }
                    .pickerStyle(.segmented).labelsHidden().padding(8)
                    switch tab {
                    case .trace: TracePanel(ws: ws, traces: ws.traces)
                    case .outline: OutlinePanel(ws: ws)
                    case .bookmarks: BookmarksPanel(ws: ws)
                    case .problems: ProblemsPanel(ws: ws)
                    }
                }
                .frame(height: max(0, total - topHeight - 1))
                .clipped()
            }
        }
    }
}

struct SectionHeader: View {
    let title: String
    var count: Int?
    var source: IntelSource?
    var loading = false
    var body: some View {
        HStack(spacing: 6) {
            Text(title).font(.caption.weight(.semibold)).foregroundStyle(.secondary)
            if let count { Text("\(count)").font(.caption).foregroundStyle(.secondary) }
            if loading { ProgressView().controlSize(.mini) }
            Spacer()
            if let source { SourceBadge(source: source) }
        }
    }
}

struct ContextSection: View {
    @Bindable var ws: Workspace
    @Bindable var ctx: SymbolContext
    @State private var refsExpanded = true

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            // Symbol
            VStack(alignment: .leading, spacing: 4) {
                HStack {
                    Text(ctx.name).font(.title3.monospaced().weight(.semibold)).textSelection(.enabled)
                    Spacer()
                    if let d = ctx.details { SourceBadge(source: d.source) } else { ProgressView().controlSize(.mini) }
                }
                if let d = ctx.details {
                    HStack(spacing: 4) {
                        Text(d.kindLabel).foregroundStyle(.secondary)
                        if let def = d.definition {
                            Text("·").foregroundStyle(.tertiary)
                            Button(def.shortDescription) { ws.open(def, edge: .definition, title: ctx.name, source: d.source) }
                                .buttonStyle(.link)
                        }
                    }.font(.caption)
                    if let sig = d.signature {
                        Text(sig).font(.system(size: 11, design: .monospaced)).textSelection(.enabled)
                            .padding(6).frame(maxWidth: .infinity, alignment: .leading)
                            .background(Color.secondary.opacity(0.08), in: RoundedRectangle(cornerRadius: 5))
                    }
                    if let docs = d.docs {
                        Text(LocalizedStringKey(String(docs.prefix(800)))).font(.caption).foregroundStyle(.secondary)
                            .textSelection(.enabled).lineLimit(8)
                    }
                }
            }

            // Calls
            VStack(alignment: .leading, spacing: 4) {
                HStack {
                    Picker("", selection: Binding(get: { ctx.callDirection }, set: { d in
                        ctx.callDirection = d
                        Task { await ws.loadCalls(ctx) }
                    })) {
                        ForEach(CallDirection.allCases) { Text($0.rawValue).tag($0) }
                    }.pickerStyle(.segmented).labelsHidden().frame(width: 150)
                    if ctx.loadingCalls { ProgressView().controlSize(.mini) }
                    Spacer()
                    if let s = ctx.calls.first?.source { SourceBadge(source: s) }
                }
                if ctx.calls.isEmpty && !ctx.loadingCalls {
                    Text(ctx.callDirection == .incoming ? "No callers found" : "No calls found").font(.caption).foregroundStyle(.secondary)
                }
                let visible = ws.showTests ? ctx.calls : ctx.calls.filter { !$0.isTest }
                ForEach(visible) { n in CallNodeRow(ws: ws, node: n, direction: ctx.callDirection, depth: 0) }
                if visible.count < ctx.calls.count {
                    Button("\(ctx.calls.count - visible.count) test \(ctx.callDirection == .incoming ? "callers" : "callees") hidden") { ws.showTests = true }
                        .buttonStyle(.link).font(.caption)
                }
            }

            // Implementations
            if !ctx.implementations.isEmpty || ctx.loadingImpls {
                VStack(alignment: .leading, spacing: 4) {
                    SectionHeader(title: "Implementations", count: ctx.implementations.count, source: ctx.implementationsSource, loading: ctx.loadingImpls)
                    ForEach(ctx.implementations.prefix(100)) { h in
                        Button { ws.open(h.location, edge: .implementation, title: h.enclosing ?? ctx.name, source: h.source) } label: {
                            HStack {
                                Text(h.enclosing ?? h.preview).font(.system(size: 11, design: .monospaced)).lineLimit(1)
                                Spacer()
                                Text(h.location.shortDescription).font(.caption2).foregroundStyle(.secondary)
                            }
                        }.buttonStyle(.plain)
                    }
                }
            }

            // References
            VStack(alignment: .leading, spacing: 4) {
                SectionHeader(title: "References", count: ctx.references.count, source: ctx.referencesSource, loading: ctx.loadingReferences)
                let grouped = Dictionary(grouping: ctx.references, by: { $0.location.path })
                ForEach(grouped.keys.sorted().prefix(80), id: \.self) { path in
                    VStack(alignment: .leading, spacing: 1) {
                        Text(path).font(.caption2).foregroundStyle(.secondary).lineLimit(1).truncationMode(.head)
                        ForEach(grouped[path]!.sorted { $0.location.line < $1.location.line }) { h in
                            Button { ws.followReference(h) } label: {
                                HStack(alignment: .firstTextBaseline, spacing: 6) {
                                    Text("\(h.location.displayLine)").font(.caption2.monospacedDigit()).foregroundStyle(.secondary).frame(width: 34, alignment: .trailing)
                                    VStack(alignment: .leading, spacing: 0) {
                                        Text(h.preview).font(.system(size: 11, design: .monospaced)).lineLimit(1)
                                        if let e = h.enclosing { Text("in \(e)").font(.caption2).foregroundStyle(.tertiary) }
                                    }
                                    if h.isDefinition { Text("def").font(.caption2.weight(.bold)).foregroundStyle(.green) }
                                }
                                .contentShape(Rectangle())
                            }.buttonStyle(.plain)
                        }
                    }
                }
            }
        }
        .padding(12)
    }
}

struct CallNodeRow: View {
    @Bindable var ws: Workspace
    @Bindable var node: CallNode
    let direction: CallDirection
    let depth: Int
    @State private var expanded = false

    var body: some View {
        VStack(alignment: .leading, spacing: 2) {
            HStack(spacing: 4) {
                Button {
                    expanded.toggle()
                    if expanded { Task { await ws.intel.expand(node, direction) } }
                } label: {
                    Image(systemName: expanded ? "chevron.down" : "chevron.right").font(.caption2).frame(width: 12)
                }.buttonStyle(.plain)
                Button { ws.followCall(node, direction: direction) } label: {
                    VStack(alignment: .leading, spacing: 0) {
                        HStack {
                            Text(node.name).font(.system(size: 12, weight: .medium, design: .monospaced)).lineLimit(1)
                            Spacer()
                            if node.callSites.count > 1 { Text("×\(node.callSites.count)").font(.caption2).foregroundStyle(.secondary) }
                            Text("\(node.location.displayLine)").font(.caption2.monospacedDigit()).foregroundStyle(.secondary)
                        }
                        Text(node.location.path.lastPathComponent).font(.caption2).foregroundStyle(.secondary)
                    }
                    .padding(.horizontal, 8).padding(.vertical, 4)
                    .background(RoundedRectangle(cornerRadius: 8).fill(node.isRecursive ? Color.orange.opacity(0.12) : Color.accentColor.opacity(0.08)))
                    .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
                .contextMenu {
                    Button("Add to Trace") {
                        ws.traces.append(TraceStep(title: node.name, location: node.location, edge: direction == .incoming ? .caller : .callee, source: node.source))
                    }
                    if node.callSites.count > 1 {
                        ForEach(node.callSites, id: \.self) { s in
                            Button("Call site \(s.shortDescription)") { ws.open(s, edge: direction == .incoming ? .caller : .callee, title: node.name, source: node.source) }
                        }
                    }
                }
            }
            if expanded {
                if node.isLoading { ProgressView().controlSize(.mini).padding(.leading, 24) }
                if let note = node.note { Text(note).font(.caption2).foregroundStyle(.secondary).padding(.leading, 24) }
                if let children = node.children, depth < 12 {
                    ForEach(ws.showTests ? children : children.filter { !$0.isTest }) { c in
                        CallNodeRow(ws: ws, node: c, direction: direction, depth: depth + 1).padding(.leading, 14)
                    }
                }
            }
        }
    }
}

struct TracePanel: View {
    @Bindable var ws: Workspace
    @Bindable var traces: TraceStore
    @State private var question = ""
    @State private var renaming = false
    @State private var editingNote: UUID?

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            HStack {
                Menu {
                    ForEach(traces.traces) { t in
                        Button {
                            traces.activeID = t.id; traces.currentStep = nil
                        } label: {
                            Label("\(t.title) (\(t.steps.count))", systemImage: t.origin == .claude ? "sparkles" : t.origin == .recorded ? "record.circle" : "list.number")
                        }
                    }
                    Divider()
                    Button("New empty trace") { traces.create(title: "Untitled trace", origin: .manual) }
                    if let t = traces.active {
                        Button("Copy as Markdown") {
                            NSPasteboard.general.clearContents()
                            NSPasteboard.general.setString(t.markdown(), forType: .string)
                        }
                        Button("Rename…") { renaming = true }
                        Button("Delete", role: .destructive) { traces.delete(t.id) }
                    }
                } label: {
                    Text(traces.active?.title ?? "No trace").lineLimit(1)
                }
                .menuStyle(.borderlessButton)
                Spacer()
                if let t = traces.active { Text("\(t.steps.count) steps").font(.caption).foregroundStyle(.secondary) }
            }
            .padding(.horizontal, 10)

            HStack {
                TextField("Ask Claude to trace… e.g. how a peek reaches the replica", text: $question)
                    .textFieldStyle(.roundedBorder)
                    .onSubmit(generate)
                Button(action: generate) { Image(systemName: "sparkles") }
                    .disabled(question.isEmpty || ws.traceGenerating != nil)
                    .help("Generate a trace with Claude, anchored at the cursor")
            }
            .padding(.horizontal, 10)
            if let g = ws.traceGenerating {
                HStack { ProgressView().controlSize(.mini); Text(g).font(.caption).foregroundStyle(.purple).lineLimit(1) }.padding(.horizontal, 10)
            }

            if let t = traces.active {
                if let s = t.summary, !s.isEmpty {
                    Text(s).font(.caption).foregroundStyle(.secondary).padding(.horizontal, 10).lineLimit(4)
                }
                List {
                    ForEach(Array(t.steps.enumerated()), id: \.element.id) { i, step in
                        TraceStepRow(ws: ws, step: step, index: i, current: traces.currentStep == i, editing: editingNote == step.id,
                                     onEdit: { editingNote = editingNote == step.id ? nil : step.id })
                            .contentShape(Rectangle())
                            .onTapGesture { ws.playStep(i) }
                            .contextMenu {
                                Button("Edit note") { editingNote = step.id }
                                Button("Remove step", role: .destructive) { traces.removeStep(step.id) }
                            }
                    }
                    .onMove { traces.moveSteps(from: $0, to: $1) }
                    .onDelete { idx in idx.map { t.steps[$0].id }.forEach(traces.removeStep) }
                }
                .listStyle(.plain)
            } else {
                Text("Record a trace with the ● button (each go-to-definition, reference or call you follow becomes a step), add locations with ⇧⌘T, or ask Claude to trace a flow.")
                    .font(.caption).foregroundStyle(.secondary).padding(10)
                Spacer()
            }
        }
        .alert("Rename trace", isPresented: $renaming) {
            TextField("Title", text: Binding(get: { traces.active?.title ?? "" }, set: { v in
                if var t = traces.active { t.title = v; traces.active = t }
            }))
            Button("Done") {}
        }
    }

    private func generate() {
        guard !question.isEmpty else { return }
        ws.generateTrace(question, includeAnchor: ws.document != nil)
        question = ""
    }
}

struct TraceStepRow: View {
    @Bindable var ws: Workspace
    let step: TraceStep
    let index: Int
    let current: Bool
    let editing: Bool
    var onEdit: () -> Void
    @State private var draft = ""

    var body: some View {
        HStack(alignment: .top, spacing: 8) {
            ZStack {
                Circle().fill(current ? Color.purple : Color.secondary.opacity(0.2)).frame(width: 20, height: 20)
                Text("\(index + 1)").font(.system(size: 10, weight: .bold)).foregroundStyle(current ? .white : .primary)
            }
            VStack(alignment: .leading, spacing: 2) {
                HStack(spacing: 4) {
                    Text(step.title).font(.system(size: 12, weight: .semibold, design: .monospaced)).lineLimit(1)
                    if !step.verified { Image(systemName: "questionmark.circle").foregroundStyle(.orange).help("Claude's location could not be matched to a symbol") }
                    Spacer()
                    Image(systemName: step.edge.glyph).font(.caption2).foregroundStyle(.secondary).help(step.edge.label)
                }
                if editing {
                    TextField("Note", text: $draft, axis: .vertical)
                        .textFieldStyle(.roundedBorder).font(.caption)
                        .onAppear { draft = step.note }
                        .onSubmit { ws.traces.updateStep(step.id) { $0.note = draft }; onEdit() }
                } else if !step.note.isEmpty {
                    Text(step.note).font(.caption).foregroundStyle(.secondary).lineLimit(current ? nil : 3)
                        .onTapGesture(count: 2, perform: onEdit)
                } else if !step.snippet.isEmpty {
                    Text(step.snippet).font(.system(size: 10, design: .monospaced)).foregroundStyle(.secondary).lineLimit(1)
                }
                Text("\(step.location.path):\(step.location.displayLine)").font(.system(size: 10, design: .monospaced))
                    .foregroundStyle(.tertiary).lineLimit(1).truncationMode(.head)
            }
        }
        .padding(.vertical, 3)
        .listRowBackground(current ? Color.purple.opacity(0.08) : Color.clear)
    }
}

struct OutlinePanel: View {
    @Bindable var ws: Workspace
    var body: some View {
        if let d = ws.document {
            List {
                OutlineGroup(d.syntax.outline, children: \.childrenOrNil) { item in
                    Button { ws.open(CodeLocation(path: d.path, range: item.nameRange)) } label: {
                        HStack {
                            Text(item.kind.symbolGlyph).font(.system(size: 9, weight: .bold, design: .monospaced)).foregroundStyle(.blue).frame(width: 26)
                            Text(item.kind == .impl ? item.detail : item.name).font(.system(size: 12, design: .monospaced)).lineLimit(1)
                            if item.isTest { Text("test").font(.caption2).foregroundStyle(.teal) }
                            Spacer()
                            Text("\(item.lineCount) L").font(.caption2).foregroundStyle(.secondary)
                        }
                    }.buttonStyle(.plain)
                }
            }.listStyle(.plain)
        } else { Spacer() }
    }
}

extension OutlineItem { var childrenOrNil: [OutlineItem]? { children.isEmpty ? nil : children } }

struct BookmarksPanel: View {
    @Bindable var ws: Workspace
    var body: some View {
        if ws.bookmarks.items.isEmpty {
            Text("No bookmarks. ⇧⌘B or double-click the gutter.").font(.caption).foregroundStyle(.secondary).padding()
            Spacer()
        } else {
            List {
                ForEach(Array(ws.bookmarks.items.enumerated()), id: \.element.id) { i, b in
                    Button { ws.open(b.location) } label: {
                        VStack(alignment: .leading, spacing: 1) {
                            HStack {
                                Text(b.title).font(.system(size: 12, weight: .semibold, design: .monospaced))
                                Spacer()
                                if i < 10 { Text("⌘\(i)").font(.caption2).foregroundStyle(.secondary) }
                            }
                            Text("\(b.location.path):\(b.location.displayLine)").font(.caption2).foregroundStyle(.secondary).lineLimit(1).truncationMode(.head)
                            if !b.context.isEmpty { Text(b.context).font(.caption2).foregroundStyle(.tertiary) }
                        }
                    }
                    .buttonStyle(.plain)
                    .contextMenu { Button("Remove", role: .destructive) { ws.bookmarks.remove(b.id) } }
                    .keyboardShortcut(i < 10 ? KeyboardShortcut(KeyEquivalent(Character("\(i)")), modifiers: .command) : nil)
                }
            }.listStyle(.plain)
        }
    }
}

struct ProblemsPanel: View {
    @Bindable var ws: Workspace
    var body: some View {
        VStack(alignment: .leading) {
            HStack {
                Button("Run cargo clippy") { ws.clippy.run() }
                if case .running = ws.clippy.state { Button("Cancel") { ws.clippy.cancel() } }
            }.padding(.horizontal, 10).controlSize(.small)
            List(ws.clippy.diagnostics) { d in
                Button { ws.open(d.location) } label: {
                    VStack(alignment: .leading, spacing: 1) {
                        HStack {
                            Image(systemName: d.level == .error ? "xmark.octagon.fill" : "exclamationmark.triangle.fill")
                                .foregroundStyle(d.level == .error ? .red : .yellow)
                            Text(d.message).font(.caption).lineLimit(2)
                        }
                        Text("\(d.location.path):\(d.location.displayLine)\(d.code.map { " · \($0)" } ?? "")")
                            .font(.caption2).foregroundStyle(.secondary).lineLimit(1).truncationMode(.head)
                    }
                }.buttonStyle(.plain)
            }.listStyle(.plain)
        }
    }
}
