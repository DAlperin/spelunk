import SwiftUI

/// The right pane. It follows what you are doing: the symbol under the cursor, the selected review
/// hunk's impact, or (from the Panes menu) code paths, the outline, bookmarks or problems.
struct InspectorView: View {
    @Bindable var ws: Workspace

    var showingHunk: Bool {
        ws.review != nil && ws.contextFocus == .hunk && ws.changeContext != nil && !ws.contextPinned
    }

    var body: some View {
        VStack(spacing: 0) {
            header
            Divider()
            Group {
                switch ws.inspectorPane {
                case .context:
                    List {
                        Group {
                            if showingHunk, let cc = ws.changeContext, let r = ws.review,
                               let h = r.allHunks.first(where: { $0.id == cc.hunkID }) {
                                ChangeContextSection(ws: ws, review: r, hunk: h, cc: cc)
                            } else if let c = ws.context {
                                ContextSection(ws: ws, ctx: c)
                            } else {
                                Text("Click a symbol to see its definition, callers and references. ⌘-click jumps to the definition.")
                                    .font(.callout).foregroundStyle(.secondary).padding(12)
                            }
                        }
                        .listRowInsets(EdgeInsets())
                        .listRowSeparator(.hidden)
                        .listRowBackground(Color.clear)
                    }
                    .listStyle(.plain)
                    .scrollContentBackground(.hidden)
                case .paths: TracePanel(ws: ws, traces: ws.traces)
                case .outline: OutlinePanel(ws: ws)
                case .bookmarks: BookmarksPanel(ws: ws)
                case .problems: ProblemsPanel(ws: ws)
                }
            }
            .frame(maxHeight: .infinity, alignment: .top)
            if ws.inspectorPane == .context {
                Divider()
                CollapsedRows(ws: ws)
            }
            Divider()
            ProvenanceFooter(ws: ws, showingHunk: showingHunk)
        }
    }

    var header: some View {
        HStack(spacing: 6) {
            switch ws.inspectorPane {
            case .context:
                if showingHunk {
                    Text("Change context").font(.callout.weight(.semibold))
                    if let (i, n) = ReviewNav.importantPosition(ws) { Text(verbatim: "hunk \(i) of \(n)").font(.caption).foregroundStyle(.secondary) }
                } else {
                    Text("Context").font(.callout.weight(.semibold))
                    Text(ws.contextPinned ? "pinned" : "follows cursor").font(.caption).foregroundStyle(.secondary)
                }
            default:
                Text(ws.inspectorPane.rawValue).font(.callout.weight(.semibold))
            }
            Spacer()
            if ws.inspectorPane == .context {
                if showingHunk, ws.context != nil {
                    Button("Symbol") { ws.contextFocus = .symbol }.help("Show the last clicked symbol instead")
                } else if ws.review != nil, ws.changeContext != nil, !ws.contextPinned {
                    Button("Hunk") { ws.contextFocus = .hunk }.help("Show the selected hunk's impact")
                }
                Button { ws.contextPinned.toggle() } label: {
                    Label("Pin", systemImage: ws.contextPinned ? "pin.fill" : "pin").labelStyle(.titleAndIcon)
                }
                .help(ws.contextPinned ? "Unpin: follow the cursor again" : "Keep this symbol while you click elsewhere")
                .disabled(ws.context == nil)
            }
            Menu {
                ForEach(InspectorPane.allCases) { p in
                    Button { ws.inspectorPane = p } label: {
                        if ws.inspectorPane == p { Label(p.rawValue, systemImage: "checkmark") } else { Text(p.rawValue) }
                    }
                }
            } label: { Text("Panes") }
            .menuStyle(.borderlessButton).fixedSize()
        }
        .buttonStyle(.borderless)
        .controlSize(.small)
        .padding(.horizontal, 12).frame(height: 32)
    }
}

/// Source tag shown only when an answer comes from something weaker than rust-analyzer.
struct WeakSourceTag: View {
    let source: IntelSource?
    var body: some View {
        if let s = source, s != .rustAnalyzer, s != .manual {
            Text(s.label).font(.system(size: 9, weight: .semibold))
                .padding(.horizontal, 5).padding(.vertical, 1)
                .background((s == .scip ? Color.blue : Color.orange).opacity(0.18), in: RoundedRectangle(cornerRadius: 3))
                .foregroundStyle(s == .scip ? Color.blue : Color.orange)
                .help(s == .textSearch ? "Found by text search; may include false matches" : s == .treeSitter ? "From syntax only; types are not resolved" : s == .scip ? "From the SCIP index, which may trail the working copy" : "")
        }
    }
}

struct PaneSectionHeader: View {
    let title: String
    var subtitle: String?
    var trailing: String?
    var source: IntelSource?
    var loading = false
    var body: some View {
        HStack(spacing: 6) {
            Text(title).font(.caption.weight(.semibold)).foregroundStyle(.secondary)
            if let subtitle { Text(subtitle).font(.caption).foregroundStyle(.tertiary) }
            WeakSourceTag(source: source)
            if loading { ProgressView().controlSize(.mini) }
            Spacer()
            if let trailing { Text(verbatim: trailing).font(.caption).foregroundStyle(.tertiary) }
        }
        .padding(.top, 10).padding(.bottom, 3)
    }
}

struct SectionHeader: View {
    let title: String
    var count: Int?
    var source: IntelSource?
    var loading = false
    var body: some View {
        PaneSectionHeader(title: title, trailing: count.map(String.init), source: source, loading: loading)
    }
}

extension CodeLocation {
    /// `file.rs:123`, never with digit grouping.
    var short: String { path.lastPathComponent + ":" + String(displayLine) }
}

extension IntelSource {
    var isStdLike: Bool { false }
}

/// Paths outside the repository that belong to the Rust toolchain's standard library.
func isStdPath(_ p: String) -> Bool {
    p.hasPrefix("/") && (p.contains("/rustlib/") || p.contains("/library/core/") || p.contains("/library/std/") || p.contains("/library/alloc/"))
}

/// Std callees plus trivial conversions and trait plumbing, folded into one row of the callee list.
let trivialCallees: Set<String> = ["clone", "into", "from", "to_string", "to_owned", "as_ref", "as_mut", "default", "borrow",
                                   "borrow_mut", "deref", "fmt", "eq", "hash", "cmp", "partial_cmp", "try_into", "try_from"]

@MainActor func isStdCallee(_ n: CallNode) -> Bool { isStdPath(n.location.path) || trivialCallees.contains(n.name) }

struct ContextSection: View {
    @Bindable var ws: Workspace
    @Bindable var ctx: SymbolContext
    @State private var stdOpen = false

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            symbolHeader
            callersSection
            calleesSection
            if !ctx.implementations.isEmpty { implementationsSection }
            referencesSection
            if !ctx.mentions.isEmpty { mentionsSection }
        }
        .padding(.horizontal, 12).padding(.bottom, 12).padding(.top, 8)
    }

    var kindTag: String {
        switch ctx.details?.kindLabel {
        case "Method", "Function": "fn"
        case "Struct": "struct"
        case "Enum": "enum"
        case "Trait": "trait"
        case "Module": "mod"
        case "Constant": "const"
        case "Static": "static"
        case "Type Alias": "type"
        case "Macro": "macro"
        case "Field": "field"
        case "Local": "let"
        default: "sym"
        }
    }

    var symbolHeader: some View {
        VStack(alignment: .leading, spacing: 6) {
            HStack(spacing: 6) {
                Text(kindTag).font(.system(size: 10, weight: .bold, design: .monospaced))
                    .padding(.horizontal, 4).padding(.vertical, 1)
                    .background(Color.blue.opacity(0.18), in: RoundedRectangle(cornerRadius: 3)).foregroundStyle(.blue)
                Text(ctx.name).font(.title3.monospaced().weight(.semibold)).textSelection(.enabled).lineLimit(1)
                if ctx.details == nil { ProgressView().controlSize(.mini) }
                Spacer()
                WeakSourceTag(source: ctx.details?.source)
            }
            HStack(spacing: 4) {
                Text(ctx.container ?? ctx.details?.kindLabel ?? "")
                if let def = ctx.details?.definition {
                    Text("·").foregroundStyle(.tertiary)
                    Button(def.short) { ws.open(def, edge: .definition, title: ctx.name, source: ctx.details?.source ?? .manual) }.buttonStyle(.link)
                }
                if let p = ctx.isPublic { Text("·").foregroundStyle(.tertiary); Text(p ? "pub" : "private") }
            }
            .font(.caption).foregroundStyle(.secondary)
            if let sig = ctx.details?.signature {
                Text(sig).font(.system(size: 11, design: .monospaced)).textSelection(.enabled)
                    .padding(6).frame(maxWidth: .infinity, alignment: .leading)
                    .background(Color.secondary.opacity(0.08), in: RoundedRectangle(cornerRadius: 5))
            }
            if let docs = ctx.details?.docs { RustdocView(markdown: docs) }
        }
    }

    var callersSection: some View {
        VStack(alignment: .leading, spacing: 1) {
            PaneSectionHeader(title: "Callers", subtitle: "up to entry points", trailing: ctx.callers.isEmpty ? nil : String(ctx.callers.count),
                              source: ctx.callers.first?.source, loading: ctx.loadingCallers)
            if ctx.callers.isEmpty && !ctx.loadingCallers { Text("No callers found").font(.caption).foregroundStyle(.tertiary) }
            ForEach(ctx.callers.filter { ws.showTests || !$0.isTest }) { n in CallTreeRow(ws: ws, node: n, direction: .incoming, depth: 0) }
            let hidden = ctx.callers.filter(\.isTest).count
            if hidden > 0 && !ws.showTests {
                Button("\(hidden) test callers hidden") { ws.showTests = true }.buttonStyle(.link).font(.caption)
            }
        }
    }

    var calleesSection: some View {
        let project = ctx.callees.filter { !isStdCallee($0) }
        let std = ctx.callees.filter(isStdCallee)
        return VStack(alignment: .leading, spacing: 1) {
            PaneSectionHeader(title: "Callees", subtitle: "in call order",
                              trailing: ctx.callees.isEmpty ? nil : (std.isEmpty ? String(project.count) : "\(project.count) + \(std.count) std"),
                              source: ctx.callees.first?.source, loading: ctx.loadingCallees)
            if ctx.callees.isEmpty && !ctx.loadingCallees { Text("No calls found").font(.caption).foregroundStyle(.tertiary) }
            ForEach(project) { n in CallTreeRow(ws: ws, node: n, direction: .outgoing, depth: 0) }
            if !std.isEmpty {
                Button { stdOpen.toggle() } label: {
                    HStack(spacing: 4) {
                        Image(systemName: stdOpen ? "chevron.down" : "chevron.right").font(.system(size: 8)).frame(width: 10)
                        Text(verbatim: "\(std.count) from std and core: " + Self.summarize(std)).lineLimit(1)
                    }
                    .font(.caption).foregroundStyle(.secondary).contentShape(Rectangle())
                }
                .buttonStyle(.plain).padding(.vertical, 2)
                if stdOpen { ForEach(std) { n in CallTreeRow(ws: ws, node: n, direction: .outgoing, depth: 1) } }
            }
        }
    }

    static func summarize(_ nodes: [CallNode]) -> String {
        var counts: [(String, Int)] = []
        for n in nodes {
            let k = n.name + (n.name.first?.isUppercase == false && n.name.hasSuffix("!") ? "" : "")
            let c = max(1, n.callSites.count)
            if let i = counts.firstIndex(where: { $0.0 == k }) { counts[i].1 += c } else { counts.append((k, c)) }
        }
        return counts.map { $0.1 > 1 ? "\($0.0) ×\($0.1)" : $0.0 }.joined(separator: ", ")
    }

    var implementationsSection: some View {
        VStack(alignment: .leading, spacing: 1) {
            PaneSectionHeader(title: "Implementations", trailing: String(ctx.implementations.count), source: ctx.implementationsSource)
            ForEach(ctx.implementations.prefix(60)) { h in
                Button { ws.open(h.location, edge: .implementation, title: h.enclosing ?? ctx.name, source: h.source) } label: {
                    HStack {
                        Text(h.enclosing ?? h.preview).font(.system(size: 11, design: .monospaced)).lineLimit(1)
                        Spacer()
                        Text(verbatim: h.location.short).font(.caption2.monospaced()).foregroundStyle(.tertiary)
                    }
                    .contentShape(Rectangle())
                }.buttonStyle(.plain)
            }
        }
    }

    var referencesSection: some View {
        let grouped = Dictionary(grouping: ctx.references, by: { $0.location.path })
        return VStack(alignment: .leading, spacing: 1) {
            PaneSectionHeader(title: "References", trailing: ctx.references.isEmpty ? nil : String(ctx.references.count),
                              source: ctx.referencesSource, loading: ctx.loadingReferences)
            ForEach(grouped.keys.sorted().prefix(60), id: \.self) { path in
                Text(path).font(.caption2.monospaced()).foregroundStyle(.tertiary).lineLimit(1).truncationMode(.head).padding(.top, 3)
                ForEach(grouped[path]!.sorted { $0.location.line < $1.location.line }) { h in
                    Button { ws.followReference(h) } label: {
                        HStack(alignment: .firstTextBaseline, spacing: 6) {
                            RoleTag(role: role(of: h))
                            Text(verbatim: String(h.location.displayLine)).font(.caption2.monospaced()).foregroundStyle(.secondary).frame(width: 34, alignment: .leading)
                            Text(h.preview).font(.system(size: 11, design: .monospaced)).lineLimit(1)
                            Spacer(minLength: 4)
                            if let e = h.enclosing, !h.isDefinition { Text("in \(e.split(separator: ":").last.map(String.init) ?? e)").font(.caption2).foregroundStyle(.tertiary).lineLimit(1) }
                        }
                        .contentShape(Rectangle())
                    }.buttonStyle(.plain)
                }
            }
        }
    }

    func role(of h: ReferenceHit) -> String {
        if h.isDefinition { return "def" }
        let p = h.preview
        if let r = p.range(of: ctx.name) {
            let after = p[r.upperBound...].drop { $0 == " " }
            if after.hasPrefix("(") || after.hasPrefix("::<") || after.hasPrefix("!") { return "call" }
            if after.hasPrefix("=") && !after.hasPrefix("==") { return "write" }
        }
        if p.hasPrefix("use ") || p.hasPrefix("pub use ") { return "use" }
        return "ref"
    }

    var mentionsSection: some View {
        VStack(alignment: .leading, spacing: 1) {
            HStack(spacing: 6) {
                Text("Mentions").font(.caption.weight(.semibold)).foregroundStyle(.secondary)
                WeakSourceTag(source: .textSearch)
                Text("outside Rust").font(.caption).foregroundStyle(.tertiary)
                Spacer()
            }
            .padding(.top, 10).padding(.bottom, 3)
            let byFile = Dictionary(grouping: ctx.mentions, by: \.path)
            ForEach(byFile.keys.sorted().prefix(12), id: \.self) { p in
                Button { if let m = byFile[p]?.first { ws.open(m.location, edge: .reference, source: .textSearch) } } label: {
                    HStack {
                        Text(p).font(.system(size: 11, design: .monospaced)).lineLimit(1).truncationMode(.head)
                        Spacer()
                        Text(verbatim: String((byFile[p]?.first?.line ?? 0) + 1)).font(.caption2.monospaced()).foregroundStyle(.tertiary)
                    }
                    .contentShape(Rectangle())
                }.buttonStyle(.plain)
            }
        }
    }
}

struct RoleTag: View {
    let role: String
    var body: some View {
        Text(role).font(.system(size: 9, weight: .semibold, design: .monospaced))
            .frame(width: 30)
            .padding(.vertical, 1)
            .background((role == "def" ? Color.blue : role == "write" ? .orange : .secondary).opacity(0.16), in: RoundedRectangle(cornerRadius: 3))
            .foregroundStyle(role == "def" ? Color.blue : role == "write" ? .orange : .secondary)
    }
}

/// Rustdoc with `# Panics`, `# Errors` and `# Safety` sections shown as labeled blocks.
struct RustdocView: View {
    let markdown: String
    var body: some View {
        let (summary, sections) = Self.split(markdown)
        VStack(alignment: .leading, spacing: 4) {
            if !summary.isEmpty {
                Text(LocalizedStringKey(String(summary.prefix(600)))).font(.callout).textSelection(.enabled).lineLimit(6)
            }
            ForEach(sections, id: \.0) { title, body in
                HStack(alignment: .firstTextBaseline, spacing: 6) {
                    Text(title).font(.system(size: 10, weight: .semibold))
                        .padding(.horizontal, 5).padding(.vertical, 1)
                        .background(Color.orange.opacity(0.18), in: RoundedRectangle(cornerRadius: 3)).foregroundStyle(.orange)
                    Text(LocalizedStringKey(String(body.prefix(300)))).font(.caption).foregroundStyle(.secondary).lineLimit(3)
                }
            }
        }
    }

    static func split(_ md: String) -> (String, [(String, String)]) {
        var summary: [String] = []
        var sections: [(String, [String])] = []
        for line in md.components(separatedBy: "\n") {
            let t = line.trimmingCharacters(in: .whitespaces)
            if t.hasPrefix("# ") {
                sections.append((String(t.dropFirst(2)), []))
            } else if sections.isEmpty {
                summary.append(line)
            } else if !t.isEmpty {
                sections[sections.count - 1].1.append(t)
            }
        }
        let shown: Set<String> = ["Panics", "Errors", "Safety", "Invariants", "Cancel safety"]
        return (summary.joined(separator: "\n").trimmingCharacters(in: .whitespacesAndNewlines),
                sections.filter { shown.contains($0.0) && !$0.1.isEmpty }.map { ($0.0, $0.1.joined(separator: " ")) })
    }
}

/// One-line caller/callee row; expanding peeks at the call site and lists the next level.
struct CallTreeRow: View {
    @Bindable var ws: Workspace
    @Bindable var node: CallNode
    let direction: CallDirection
    let depth: Int
    var inChange = false
    @State private var expanded = false

    var site: CodeLocation? { node.callSites.first }

    var body: some View {
        VStack(alignment: .leading, spacing: 1) {
            HStack(spacing: 4) {
                Button {
                    expanded.toggle()
                    if expanded { Task { await ws.intel.expand(node, direction) } }
                } label: {
                    Image(systemName: expanded ? "chevron.down" : "chevron.right").font(.system(size: 8, weight: .semibold))
                        .frame(width: 12, height: 16).contentShape(Rectangle())
                }
                .buttonStyle(.plain).foregroundStyle(.secondary)
                Button { ws.followCall(node, direction: direction) } label: {
                    HStack(spacing: 6) {
                        Text(node.name).font(.system(size: 12, weight: depth == 0 ? .medium : .regular, design: .monospaced)).lineLimit(1)
                            .foregroundStyle(node.isRecursive ? .orange : .primary)
                        if direction == .outgoing, let s = site, s.path == ws.context?.path {
                            Text(verbatim: "at :" + String(s.displayLine)).font(.caption2.monospaced()).foregroundStyle(.tertiary)
                        }
                        if node.callSites.count > 1 { Text(verbatim: "×\(node.callSites.count)").font(.caption2).foregroundStyle(.tertiary) }
                        if inChange || ws.isInReview(node.location) {
                            Text("in this change").font(.system(size: 9, weight: .medium)).padding(.horizontal, 4).padding(.vertical, 1)
                                .background(Color.green.opacity(0.18), in: RoundedRectangle(cornerRadius: 3)).foregroundStyle(.green)
                        }
                        Spacer(minLength: 4)
                        let loc = direction == .incoming ? (site ?? node.location) : node.location
                        Text(verbatim: loc.short).font(.caption2.monospaced()).foregroundStyle(.tertiary).lineLimit(1)
                    }
                    .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
                .contextMenu {
                    Button("Add to Code Path") {
                        ws.traces.insert(TraceStep(title: node.name, location: node.location, edge: direction == .incoming ? .caller : .callee, source: node.source,
                                                   snippet: ws.docs.document(node.location.path)?.lineText(node.location.line).trimmingCharacters(in: .whitespaces) ?? ""))
                    }
                    ForEach(node.callSites.prefix(12), id: \.self) { s in
                        Button("Call site \(s.short)") { ws.open(s, edge: direction == .incoming ? .caller : .callee, title: node.name, source: node.source) }
                    }
                }
            }
            .padding(.leading, CGFloat(depth) * 14)
            if expanded {
                if direction == .incoming, let s = site { CallSitePeek(ws: ws, site: s).padding(.leading, CGFloat(depth) * 14 + 16) }
                if node.isLoading { ProgressView().controlSize(.mini).padding(.leading, CGFloat(depth) * 14 + 16) }
                if let note = node.note { Text(note).font(.caption2).foregroundStyle(.tertiary).padding(.leading, CGFloat(depth) * 14 + 16) }
                if let children = node.children, depth < 10 {
                    ForEach(ws.showTests ? children : children.filter { !$0.isTest }) { c in
                        CallTreeRow(ws: ws, node: c, direction: direction, depth: depth + 1)
                    }
                }
            }
        }
    }
}

/// Three lines of code around a call site.
struct CallSitePeek: View {
    let ws: Workspace
    let site: CodeLocation
    var body: some View {
        if let doc = ws.docs.document(site.path) {
            let lines = Array(max(0, site.line - 1)...min(doc.lines.lineCount - 1, site.line + 1))
            VStack(alignment: .leading, spacing: 0) {
                ForEach(lines, id: \.self) { l in
                    HStack(spacing: 8) {
                        Text(verbatim: String(l + 1)).foregroundStyle(.tertiary).frame(width: 34, alignment: .trailing)
                        Text(doc.lineText(l)).lineLimit(1)
                    }
                    .padding(.vertical, 1)
                    .background(l == site.line ? Color.accentColor.opacity(0.16) : .clear)
                }
            }
            .font(.system(size: 10.5, design: .monospaced))
            .padding(4)
            .background(Color.secondary.opacity(0.07), in: RoundedRectangle(cornerRadius: 5))
            .overlay(RoundedRectangle(cornerRadius: 5).strokeBorder(Color.secondary.opacity(0.18)))
            .onTapGesture { ws.open(site, edge: .caller) }
        }
    }
}

/// The selected review hunk's impact.
struct ChangeContextSection: View {
    @Bindable var ws: Workspace
    let review: ReviewSession
    let hunk: Hunk
    @Bindable var cc: ChangeContext

    var body: some View {
        let tier = review.tier(of: hunk)
        let t = review.triage(of: hunk)
        VStack(alignment: .leading, spacing: 0) {
            VStack(alignment: .leading, spacing: 6) {
                HStack(spacing: 6) {
                    Image(systemName: "sparkles").font(.caption).foregroundStyle(.purple)
                    Text("Why this is \(tier.title.lowercased())").font(.callout.weight(.semibold))
                    Spacer()
                    Text(t == nil ? "rules" : t!.isQuick ? "quick pass" : "deep triage").font(.caption).foregroundStyle(.tertiary)
                }
                Text(t?.summary ?? t?.reason ?? review.reasons(of: hunk).joined(separator: "; ")).font(.callout).textSelection(.enabled)
                if let t, t.summary != nil, t.reason != t.summary { Text(t.reason).font(.caption).foregroundStyle(.secondary) }
                HStack(spacing: 6) {
                    Button {
                        let what = cc.enclosing ?? hunk.path.lastPathComponent
                        ws.generateTrace("Trace the effect of the change in `\(what)` (\(review.location(of: hunk))) through the code: who depends on it and what behaves differently now.", includeAnchor: true)
                        ws.inspectorPane = .paths
                    } label: { Label("Trace from here", systemImage: "point.topleft.down.to.point.bottomright.curvepath") }
                        .buttonStyle(.borderedProminent)
                    if let loc = cc.enclosingLocation {
                        Button("Go to \(loc.short)") { ws.open(loc) }.buttonStyle(.bordered)
                    }
                }
                .controlSize(.small)
            }
            .padding(.top, 10)

            if let o = review.overview {
                DisclosureGroup("Change overview" + (review.overviewIsStale ? " (before latest edits)" : "")) {
                    Text(o).font(.caption).foregroundStyle(.secondary).textSelection(.enabled).frame(maxWidth: .infinity, alignment: .leading)
                }
                .font(.caption.weight(.semibold)).padding(.top, 8)
            }

            if let e = cc.enclosing {
                PaneSectionHeader(title: "Callers of \(e.split(separator: ":").last.map(String.init) ?? e)",
                                  trailing: cc.callers.isEmpty ? nil : String(cc.callers.count), source: cc.source, loading: cc.loading && cc.callers.isEmpty)
                if cc.callers.isEmpty && !cc.loading { Text("No callers found").font(.caption).foregroundStyle(.tertiary) }
                ForEach(cc.callers) { n in CallTreeRow(ws: ws, node: n, direction: .incoming, depth: 0) }
            }
            ForEach(cc.callChanges) { change in
                PaneSectionHeader(title: change.added ? "Other callers of \(change.name)" : "Remaining callers of \(change.name)",
                                  subtitle: change.added ? "call added" : "call removed", trailing: String(change.callers.count), source: .textSearch)
                if change.callers.isEmpty { Text("None left").font(.caption).foregroundStyle(.orange) }
                ForEach(change.callers.prefix(8)) { n in CallTreeRow(ws: ws, node: n, direction: .incoming, depth: 0) }
            }
            PaneSectionHeader(title: "Tests that reach this hunk", loading: cc.loading)
            ForEach(cc.tests) { n in CallTreeRow(ws: ws, node: n, direction: .incoming, depth: 0) }
            if !cc.loading && cc.tests.isEmpty {
                HStack(spacing: 6) {
                    Text("no Rust test").font(.system(size: 9, weight: .semibold)).padding(.horizontal, 4).padding(.vertical, 1)
                        .background(Color.orange.opacity(0.18), in: RoundedRectangle(cornerRadius: 3)).foregroundStyle(.orange)
                    Text(verbatim: "No unit test calls \(cc.enclosing.map { $0.split(separator: ":").last.map(String.init) ?? $0 } ?? "this code")")
                        .font(.caption).foregroundStyle(.secondary)
                }
                ForEach(cc.testMentions.prefix(6)) { m in
                    Button { ws.open(m.location, edge: .reference, source: .textSearch) } label: {
                        HStack {
                            Text(m.path).font(.system(size: 11, design: .monospaced)).lineLimit(1).truncationMode(.head)
                            Spacer()
                            Text(verbatim: String(m.line + 1)).font(.caption2.monospaced()).foregroundStyle(.tertiary)
                        }
                        .contentShape(Rectangle())
                    }.buttonStyle(.plain)
                }
            }
        }
        .padding(.horizontal, 12).padding(.bottom, 12)
    }
}

/// Code Paths and Bookmarks as one line each while the context pane is showing.
struct CollapsedRows: View {
    @Bindable var ws: Workspace
    var body: some View {
        VStack(alignment: .leading, spacing: 4) {
            HStack(spacing: 6) {
                Text("Code Paths").font(.caption.weight(.semibold)).frame(width: 78, alignment: .leading)
                if ws.traces.traces.isEmpty {
                    Text("none").font(.caption).foregroundStyle(.tertiary)
                } else {
                    Button(ws.traces.active?.title ?? "\(ws.traces.traces.count) paths") { ws.inspectorPane = .paths }
                        .buttonStyle(.link).font(.caption).lineLimit(1)
                }
                Spacer()
                Button("New from cursor") { ws.newCodePath(fromCursor: true); ws.inspectorPane = .paths }.disabled(ws.document == nil)
                Text("·").foregroundStyle(.tertiary)
                Button("Generate") { ws.inspectorPane = .paths; ws.showGenerateTrace = true }
            }
            HStack(spacing: 6) {
                Text("Bookmarks").font(.caption.weight(.semibold)).frame(width: 78, alignment: .leading)
                if ws.bookmarks.items.isEmpty {
                    Text("none").font(.caption).foregroundStyle(.tertiary)
                } else {
                    Button("\(ws.bookmarks.items.count)") { ws.inspectorPane = .bookmarks }.buttonStyle(.link).font(.caption)
                }
                Spacer()
                KeyCap("⇧⌘B"); Text("add").font(.caption).foregroundStyle(.tertiary)
            }
        }
        .buttonStyle(.link).font(.caption)
        .padding(.horizontal, 12).padding(.vertical, 6)
    }
}

/// Where the pane's answers came from, stated once.
struct ProvenanceFooter: View {
    @Bindable var ws: Workspace
    let showingHunk: Bool
    @State private var showIndex = false

    var body: some View {
        HStack(spacing: 5) {
            let src = showingHunk ? ws.changeContext?.source : ws.context?.details?.source
            Circle().fill(color(src)).frame(width: 6, height: 6)
            Text(verbatim: text(src)).lineLimit(1)
            Spacer()
            Button("Details") { showIndex.toggle() }.buttonStyle(.link)
                .popover(isPresented: $showIndex, arrowEdge: .top) { IndexPopover(ws: ws) }
        }
        .font(.caption).foregroundStyle(.secondary)
        .padding(.horizontal, 12).frame(height: 24)
    }

    func color(_ s: IntelSource?) -> Color {
        switch s {
        case .rustAnalyzer: .green
        case .scip: .blue
        case nil: ws.ra.status == .ready ? .green : .yellow
        default: .orange
        }
    }

    func text(_ s: IntelSource?) -> String {
        var parts: [String] = []
        if let s {
            var p = "From \(s.label)"
            if !showingHunk, let e = ws.context?.elapsed { p += String(format: " in %.1fs", e) }
            parts.append(p)
        } else {
            parts.append("rust-analyzer " + ws.ra.status.label.lowercased())
        }
        if ws.scip.index != nil { parts.append(ws.scip.uncoveredFiles.isEmpty ? "index complete" : "index partial") }
        return parts.joined(separator: " · ")
    }
}

struct TracePanel: View {
    @Bindable var ws: Workspace
    @Bindable var traces: TraceStore
    @State private var question = ""
    @State private var showGenerate = false
    @State private var renaming = false
    @State private var newTitle = ""

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            HStack(spacing: 6) {
                Text("Code Paths").font(.caption.weight(.semibold)).foregroundStyle(.secondary)
                if let t = traces.active { Text(verbatim: "\(t.steps.count) steps").font(.caption).foregroundStyle(.secondary) }
                Spacer()
                Button { ws.addCurrentToTrace() } label: { Image(systemName: "plus") }
                    .buttonStyle(.borderless)
                    .disabled(ws.document == nil)
                    .help("Add the cursor location after the current step (⇧⌘T)")
                Menu {
                    Button("New Code Path") { ws.newCodePath(fromCursor: false) }
                    Button("New Code Path from Cursor") { ws.newCodePath(fromCursor: true) }.disabled(ws.document == nil)
                    Button("Generate with Claude…") { showGenerate = true }
                    if let t = traces.active {
                        Divider()
                        Button("Rename…") { newTitle = t.title; renaming = true }
                        Button("Duplicate") { traces.duplicateActive() }
                        Button("Copy as Markdown") {
                            NSPasteboard.general.clearContents()
                            NSPasteboard.general.setString(t.markdown(), forType: .string)
                        }
                        Divider()
                        Button("Delete", role: .destructive) { traces.delete(t.id) }
                    }
                } label: { Image(systemName: "ellipsis") }
                .menuStyle(.borderlessButton)
                .fixedSize()
            }
            .padding(.horizontal, 10)

            if !traces.traces.isEmpty {
                Picker("", selection: Binding(get: { traces.activeID }, set: { traces.activeID = $0; traces.currentStep = nil })) {
                    ForEach(traces.traces) { t in
                        Text(t.title).tag(Optional(t.id))
                    }
                }
                .labelsHidden()
                .pickerStyle(.menu)
                .padding(.horizontal, 8)
            }

            if showGenerate || ws.traceGenerating != nil {
                VStack(alignment: .leading, spacing: 4) {
                    HStack {
                        TextField("Describe a flow, e.g. how a peek reaches the replica", text: $question)
                            .textFieldStyle(.roundedBorder)
                            .onSubmit(generate)
                        ModelMenu(task: .trace)
                        Button { showGenerate = false } label: { Image(systemName: "xmark") }.buttonStyle(.borderless)
                    }
                    if let g = ws.traceGenerating {
                        HStack { ProgressView().controlSize(.mini); Text(g).font(.caption).foregroundStyle(.purple).lineLimit(1) }
                    } else {
                        Text("Claude reads the code and writes the path, anchored at the cursor. Steps are matched to real symbols.")
                            .font(.caption2).foregroundStyle(.secondary)
                    }
                }
                .padding(.horizontal, 10)
            }

            if let t = traces.active {
                if let s = t.summary, !s.isEmpty {
                    Text(s).font(.caption).foregroundStyle(.secondary).padding(.horizontal, 10).lineLimit(3).help(s)
                }
                if t.steps.isEmpty {
                    emptyPath
                } else {
                    ScrollViewReader { proxy in
                        List {
                            ForEach(Array(t.steps.enumerated()), id: \.element.id) { i, step in
                                TraceStepRow(ws: ws, step: step, index: i, current: traces.currentStep == i)
                                    .id(step.id)
                                    .contentShape(Rectangle())
                                    .onTapGesture { ws.playStep(i) }
                                    .contextMenu { stepMenu(step) }
                            }
                            .onMove { traces.moveSteps(from: $0, to: $1) }
                        }
                        .listStyle(.plain)
                        .onChange(of: traces.currentStep) {
                            if let c = traces.currentStep, c < t.steps.count { withAnimation { proxy.scrollTo(t.steps[c].id, anchor: .center) } }
                        }
                    }
                }
            } else {
                VStack(alignment: .leading, spacing: 8) {
                    Text("A code path is an ordered list of locations with notes: how a request flows, how a value is built, where a bug travels.")
                        .font(.caption).foregroundStyle(.secondary)
                    Button("New Code Path from Cursor") { ws.newCodePath(fromCursor: true) }.disabled(ws.document == nil)
                    Button("Generate with Claude…") { showGenerate = true }
                }
                .buttonStyle(.link)
                .padding(10)
                Spacer()
            }
        }
        .alert("Rename code path", isPresented: $renaming) {
            TextField("Title", text: $newTitle)
            Button("Rename") { traces.rename(newTitle) }
            Button("Cancel", role: .cancel) {}
        }
    }

    var emptyPath: some View {
        VStack(alignment: .leading, spacing: 6) {
            Text("No steps yet. Put the cursor where the path starts and press + (⇧⌘T). Navigate with ⌘-click, callers and references, and add each place that matters.")
                .font(.caption).foregroundStyle(.secondary)
            Spacer()
        }
        .padding(10)
    }

    @ViewBuilder func stepMenu(_ step: TraceStep) -> some View {
        Button("Edit Note") { ws.editingStepID = step.id }
        Button("Move Up") { traces.moveStep(step.id, by: -1) }
        Button("Move Down") { traces.moveStep(step.id, by: 1) }
        Button("Set Location to Cursor") {
            guard let d = ws.document, let c = ws.cursor else { return }
            traces.updateStep(step.id) {
                $0.location = CodeLocation(path: d.path, range: ws.selection ?? SourceRange(line: c.line, col: c.col))
                $0.snippet = d.lineText(c.line).trimmingCharacters(in: .whitespaces)
                $0.verified = true
            }
        }
        Divider()
        Button("Remove Step", role: .destructive) { traces.removeStep(step.id) }
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
    @State private var draft = ""
    @State private var titleDraft = ""
    @FocusState private var focused: Bool

    var editing: Bool { ws.editingStepID == step.id }

    var body: some View {
        HStack(alignment: .firstTextBaseline, spacing: 8) {
            Text(verbatim: "\(index + 1)").font(.system(size: 12, weight: .medium).monospacedDigit()).foregroundStyle(.secondary)
                .frame(width: 18, alignment: .trailing)
            VStack(alignment: .leading, spacing: 3) {
                HStack(spacing: 4) {
                    if editing {
                        TextField("Title", text: $titleDraft).font(.system(size: 13, weight: .semibold, design: .monospaced))
                            .textFieldStyle(.plain)
                    } else {
                        Text(step.title).font(.system(size: 13, weight: .semibold, design: .monospaced)).lineLimit(1).truncationMode(.tail)
                    }
                    if !step.verified { Image(systemName: "questionmark.circle").foregroundStyle(.orange).help("Claude's location could not be matched to a symbol") }
                    Spacer(minLength: 0)
                    if step.edge != .start && step.edge != .manual {
                        Image(systemName: step.edge.glyph).font(.caption2).foregroundStyle(.tertiary).help(step.edge.label)
                    }
                }
                if editing {
                    TextField("What happens here, and how does it lead to the next step?", text: $draft, axis: .vertical)
                        .textFieldStyle(.roundedBorder).font(.callout)
                        .lineLimit(2...10)
                        .focused($focused)
                        .onSubmit(commit)
                    HStack {
                        Button("Done", action: commit).keyboardShortcut(.return, modifiers: .command)
                        Button("Cancel") { ws.editingStepID = nil }
                    }.controlSize(.small)
                } else if !step.note.isEmpty {
                    Text(step.note).font(.callout).foregroundStyle(.primary.opacity(0.85))
                        .onTapGesture(count: 2) { ws.editingStepID = step.id }
                } else {
                    Text(step.snippet.isEmpty ? "Double-click to add a note" : step.snippet)
                        .font(step.snippet.isEmpty ? .caption : .system(size: 11, design: .monospaced))
                        .foregroundStyle(.secondary).lineLimit(1)
                        .onTapGesture(count: 2) { ws.editingStepID = step.id }
                }
                Text(step.location.path).font(.system(size: 10, design: .monospaced))
                    .foregroundStyle(.tertiary).lineLimit(1).truncationMode(.head)
                    .help("\(step.location.path):\(step.location.displayLine)")
            }
        }
        .padding(.vertical, 6).padding(.horizontal, 6)
        .background(current ? Color.secondary.opacity(0.18) : Color.clear, in: RoundedRectangle(cornerRadius: 8))
        .listRowSeparator(.hidden)
        .listRowInsets(EdgeInsets(top: 1, leading: 6, bottom: 1, trailing: 6))
        .onChange(of: editing, initial: true) {
            if editing { draft = step.note; titleDraft = step.title; focused = true }
        }
    }

    private func commit() {
        let note = draft, title = titleDraft.trimmingCharacters(in: .whitespaces)
        ws.traces.updateStep(step.id) { $0.note = note; if !title.isEmpty { $0.title = title } }
        ws.editingStepID = nil
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
                            Text(verbatim: "\(item.lineCount) L").font(.caption2).foregroundStyle(.secondary)
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
                                if i < 10 { Text(verbatim: "⌘\(i)").font(.caption2).foregroundStyle(.secondary) }
                            }
                            Text(verbatim: "\(b.location.path):\(b.location.displayLine)").font(.caption2).foregroundStyle(.secondary).lineLimit(1).truncationMode(.head)
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
                        Text(verbatim: "\(d.location.path):\(d.location.displayLine)\(d.code.map { " · \($0)" } ?? "")")
                            .font(.caption2).foregroundStyle(.secondary).lineLimit(1).truncationMode(.head)
                    }
                }.buttonStyle(.plain)
            }.listStyle(.plain)
        }
    }
}
