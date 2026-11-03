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
                case .conversation:
                    if let r = ws.review, let pr = r.pullRequest { ConversationPane(ws: ws, review: r, pr: pr) }
                    else { Text("Open a GitHub pull request to see its conversation.").font(.callout).foregroundStyle(.secondary).padding(12); Spacer() }
                case .claude: ClaudePane(ws: ws)
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
            if ws.inspectorPane == .conversation, let pr = ws.review?.pullRequest {
                Text(verbatim: "PR #\(pr.number) · head \(pr.headSha.prefix(7)) · posting as \(ws.github.login ?? "you")")
                    .font(.caption).foregroundStyle(.secondary).padding(.horizontal, 12).frame(maxWidth: .infinity, minHeight: 24, alignment: .leading)
            } else {
                ProvenanceFooter(ws: ws, showingHunk: showingHunk)
            }
        }
    }

    var header: some View {
        HStack(spacing: 6) {
            switch ws.inspectorPane {
            case .context:
                if ws.review != nil, ws.changeContext != nil, !ws.contextPinned {
                    Picker("", selection: Binding(get: { showingHunk ? ContextFocus.hunk : .symbol }, set: { ws.contextFocus = $0 })) {
                        Text(verbatim: ReviewNav.importantPosition(ws).map { "Hunk \($0.0)/\($0.1)" } ?? "Hunk").tag(ContextFocus.hunk)
                        Text(verbatim: ws.context.map { $0.name.count > 16 ? $0.name.prefix(15) + "…" : $0.name } ?? "Symbol").tag(ContextFocus.symbol)
                    }
                    .pickerStyle(.segmented).labelsHidden().fixedSize()
                    .help("Switch between the selected hunk's change context and the last clicked symbol (Esc returns to the hunk)")
                } else if showingHunk {
                    Text("Change context").font(.callout.weight(.semibold))
                } else {
                    Text("Context").font(.callout.weight(.semibold))
                    Text(ws.contextPinned ? "pinned" : "follows cursor").font(.caption).foregroundStyle(.secondary)
                }
            default:
                Text(ws.inspectorPane.rawValue).font(.callout.weight(.semibold))
            }
            Spacer()
            if ws.inspectorPane == .context {
                Button { ws.contextPinned.toggle() } label: {
                    Label("Pin", systemImage: ws.contextPinned ? "pin.fill" : "pin").labelStyle(.titleAndIcon)
                }
                .help(ws.contextPinned ? "Unpin: follow the cursor again" : "Keep this symbol while you click elsewhere")
                .disabled(ws.context == nil)
                .fixedSize()
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

            AttachmentsSection(ws: ws, review: review, hunk: hunk)

            ForEach(review.groups(containing: hunk).prefix(3)) { g in
                RelatedGroupSection(ws: ws, review: review, group: g, current: hunk)
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

/// The rest of a logical change the hunk belongs to, with the other hunks one click away.
struct RelatedGroupSection: View {
    @Bindable var ws: Workspace
    let review: ReviewSession
    let group: HunkGroup
    let current: Hunk

    var body: some View {
        let hs = review.hunks(of: group)
        let pos = (hs.firstIndex { $0.id == current.id } ?? 0) + 1
        VStack(alignment: .leading, spacing: 2) {
            HStack(spacing: 6) {
                Image(systemName: group.glyph).font(.caption2).foregroundStyle(group.kind == .claude ? .purple : .secondary)
                Text(group.title).font(.caption.weight(.semibold)).foregroundStyle(.secondary).lineLimit(1).truncationMode(.tail)
                Spacer(minLength: 4)
                Text(verbatim: "\(pos) of \(hs.count)").font(.caption).foregroundStyle(.tertiary).fixedSize()
                Button { step(hs, pos, by: -1) } label: { Image(systemName: "chevron.up") }.disabled(pos <= 1)
                Button { step(hs, pos, by: 1) } label: { Image(systemName: "chevron.down") }.disabled(pos >= hs.count)
            }
            .buttonStyle(.borderless).controlSize(.small)
            .padding(.top, 10).padding(.bottom, 3)
            if let r = group.rationale { Text(r).font(.caption).foregroundStyle(.secondary).padding(.bottom, 2) }
            ForEach(hs.prefix(12)) { h in
                Button { ws.selectHunk(h) } label: {
                    HStack(spacing: 6) {
                        Image(systemName: review.isViewed(h) ? "checkmark.circle.fill" : "circle").font(.caption2)
                            .foregroundStyle(review.isViewed(h) ? .green : .secondary)
                        Text(review.analyses[h.id]?.enclosing ?? h.path.lastPathComponent)
                            .font(.system(size: 11, weight: h.id == current.id ? .semibold : .regular, design: .monospaced))
                            .lineLimit(1).truncationMode(.middle)
                        Spacer(minLength: 4)
                        Text(verbatim: h.path.lastPathComponent).font(.caption2.monospaced()).foregroundStyle(.tertiary).lineLimit(1)
                    }
                    .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
                .padding(.vertical, 1)
                .background(h.id == current.id ? Color.accentColor.opacity(0.12) : .clear, in: RoundedRectangle(cornerRadius: 3))
            }
            if hs.count > 12 {
                Button("Show all \(hs.count) in the review list") { review.listMode = .importance; review.expandedGroups.insert(group.id); ws.sidebarTab = .changes }.buttonStyle(.link).font(.caption)
            }
        }
    }

    func step(_ hs: [Hunk], _ pos: Int, by d: Int) {
        let i = pos - 1 + d
        if i >= 0 && i < hs.count { ws.selectHunk(hs[i]) }
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
                    Button { ws.inspectorPane = .paths } label: {
                        Text(ws.traces.active?.title ?? "\(ws.traces.traces.count) paths")
                            .lineLimit(1).truncationMode(.tail)
                            .frame(maxWidth: .infinity, alignment: .leading)
                    }
                    .buttonStyle(.plain).foregroundStyle(Color.accentColor).font(.caption)
                    .help(ws.traces.active?.title ?? "")
                    .layoutPriority(-1)
                }
                Spacer(minLength: 4)
                HStack(spacing: 6) {
                    Button("New from cursor") { ws.newCodePath(fromCursor: true); ws.inspectorPane = .paths }.disabled(ws.document == nil)
                    Text("·").foregroundStyle(.tertiary)
                    Button("Generate") { ws.inspectorPane = .paths; ws.showGenerateTrace = true }
                }
                .fixedSize()
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

/// The open code path: the main object of the pane while it is shown.
struct TracePanel: View {
    @Bindable var ws: Workspace
    @Bindable var traces: TraceStore
    @State private var question = ""
    @State private var renaming = false
    @State private var newTitle = ""

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            contextStrip
            Divider()
            pathPicker
            if ws.showGenerateTrace || ws.jobs.contains(where: { $0.kind == .trace && $0.running }) { generateBox }
            if let t = traces.active {
                if t.origin == .claude, let q = t.question { generatedBox(t, q) }
                if t.steps.isEmpty {
                    Text("No steps yet. Put the cursor where the path starts and press Add step (⇧⌘T). Follow calls with ⌘-click and add each place that matters.")
                        .font(.caption).foregroundStyle(.secondary).padding(12)
                    Spacer()
                } else {
                    stepList(t)
                }
                Divider()
                footer(t)
            } else {
                VStack(alignment: .leading, spacing: 8) {
                    Text("A code path is an ordered list of places with a note on each: how a request flows, how a value is built, where a bug travels.")
                        .font(.caption).foregroundStyle(.secondary)
                    Button("New Code Path from Cursor") { ws.newCodePath(fromCursor: true) }.disabled(ws.document == nil)
                    Button("Generate with Claude…") { ws.showGenerateTrace = true }
                }
                .buttonStyle(.link).padding(12)
                Spacer()
            }
        }
        .alert("Rename code path", isPresented: $renaming) {
            TextField("Title", text: $newTitle)
            Button("Rename") { traces.rename(newTitle) }
            Button("Cancel", role: .cancel) {}
        }
    }

    /// The context pane, collapsed to one line while a path is open.
    var contextStrip: some View {
        Button { ws.inspectorPane = .context } label: {
            HStack(spacing: 6) {
                Image(systemName: "chevron.right").font(.system(size: 8, weight: .semibold))
                Text("Context").font(.caption.weight(.semibold))
                if let c = ws.context {
                    Text(c.name).font(.caption.monospaced()).lineLimit(1)
                    Text(verbatim: [c.details?.kindLabel, c.callers.isEmpty ? nil : "\(c.callers.count) callers", c.callees.isEmpty ? nil : "\(c.callees.count) callees"]
                        .compactMap { $0 }.joined(separator: " · ")).font(.caption).foregroundStyle(.secondary).lineLimit(1)
                }
                Spacer()
            }
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .padding(.horizontal, 12).frame(height: 26)
    }

    var pathPicker: some View {
        HStack(spacing: 6) {
            Text("Code Path").font(.caption.weight(.semibold)).foregroundStyle(.secondary)
            Menu {
                ForEach(traces.traces) { t in
                    Button { traces.activeID = t.id; traces.currentStep = nil } label: {
                        if t.id == traces.activeID { Label("\(t.title) (\(t.steps.count))", systemImage: "checkmark") }
                        else { Text(verbatim: "\(t.title) (\(t.steps.count))") }
                    }
                }
                Divider()
                Button("New Code Path") { ws.newCodePath(fromCursor: false) }
                Button("New Code Path from Cursor") { ws.newCodePath(fromCursor: true) }.disabled(ws.document == nil)
                Button("Generate with Claude…") { ws.showGenerateTrace = true }
                if let t = traces.active {
                    Divider()
                    Button("Rename…") { newTitle = t.title; renaming = true }
                    Button("Duplicate") { traces.duplicateActive() }
                    Button("Delete", role: .destructive) { traces.delete(t.id) }
                }
            } label: {
                Text(traces.active?.title ?? "None").lineLimit(1)
            }
            .menuStyle(.button)
            .controlSize(.small)
        }
        .padding(.horizontal, 12).padding(.vertical, 6)
    }

    var generateBox: some View {
        VStack(alignment: .leading, spacing: 4) {
            HStack {
                TextField("Ask Claude to trace a flow, e.g. how a peek reaches the replica", text: $question, axis: .vertical)
                    .textFieldStyle(.roundedBorder).lineLimit(1...4)
                    .onSubmit(generate)
                ModelMenu(task: .trace)
                Button { ws.showGenerateTrace = false } label: { Image(systemName: "xmark") }.buttonStyle(.borderless)
            }
            let pending = ws.jobs.filter { $0.kind == .trace && $0.running }
            if !pending.isEmpty {
                ForEach(pending) { j in
                    HStack(spacing: 6) {
                        ProgressView().controlSize(.mini)
                        Text(j.question).font(.caption.weight(.medium)).lineLimit(1).truncationMode(.tail)
                        Text(j.status).font(.caption).foregroundStyle(.purple).lineLimit(1).truncationMode(.tail).layoutPriority(-1)
                        Spacer(minLength: 0)
                        Button { ws.cancelJob(j.id) } label: { Image(systemName: "stop.circle") }.buttonStyle(.borderless).help("Cancel")
                    }
                }
            } else {
                Text("Anchored at the cursor. Steps are matched to real symbols; hops Claude could not confirm are marked inferred.")
                    .font(.caption2).foregroundStyle(.secondary)
            }
        }
        .padding(.horizontal, 12).padding(.bottom, 8)
    }

    func generatedBox(_ t: Trace, _ q: String) -> some View {
        let connectors = ws.activeConnectors()
        let verified = connectors.filter { $0.kind != .inferred }.count
        return VStack(alignment: .leading, spacing: 4) {
            HStack(spacing: 4) {
                Image(systemName: "sparkles").font(.caption2).foregroundStyle(.purple)
                Text(verbatim: "Generated from question · \(t.steps.count) steps · \(verified) of \(connectors.count) hops verified")
                    .font(.caption).foregroundStyle(.secondary)
            }
            Text(q).font(.callout)
            HStack {
                Button("Refine…") { question = q; ws.showGenerateTrace = true }
                Button("Regenerate") { ws.generateTrace(q, includeAnchor: false, force: true) }
            }
            .controlSize(.small)
        }
        .padding(8)
        .background(Color.purple.opacity(0.07), in: RoundedRectangle(cornerRadius: 6))
        .padding(.horizontal, 12).padding(.bottom, 8)
    }

    func stepList(_ t: Trace) -> some View {
        let connectors = ws.activeConnectors()
        return ScrollViewReader { proxy in
            List {
                ForEach(Array(t.steps.enumerated()), id: \.element.id) { i, step in
                    VStack(alignment: .leading, spacing: 0) {
                        TraceStepRow(ws: ws, step: step, index: i, current: traces.currentStep == i)
                            .contentShape(Rectangle())
                            .onTapGesture { ws.playStep(i) }
                        if i < connectors.count { ConnectorRow(ws: ws, connector: connectors[i]) }
                    }
                    .id(step.id)
                    .listRowSeparator(.hidden)
                    .listRowInsets(EdgeInsets(top: 0, leading: 8, bottom: 0, trailing: 8))
                    .contextMenu {
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
                }
                .onMove { traces.moveSteps(from: $0, to: $1) }
            }
            .listStyle(.plain)
            .scrollContentBackground(.hidden)
            .onChange(of: traces.currentStep) {
                if let c = traces.currentStep, c < t.steps.count { withAnimation { proxy.scrollTo(t.steps[c].id, anchor: .center) } }
            }
        }
    }

    func footer(_ t: Trace) -> some View {
        HStack(spacing: 6) {
            Button { ws.addCurrentToTrace() } label: { Label("Add step at cursor", systemImage: "plus") }
                .buttonStyle(.bordered).controlSize(.small).disabled(ws.document == nil)
            if let c = traces.currentStep { Text(verbatim: "inserts after \(c + 1)").font(.caption).foregroundStyle(.tertiary) }
            Spacer()
            Button("Share as Markdown") {
                NSPasteboard.general.clearContents()
                NSPasteboard.general.setString(t.markdown(), forType: .string)
                ws.statusMessage = "Copied \(t.title) as Markdown"
            }
            .buttonStyle(.link).font(.caption)
        }
        .padding(.horizontal, 12).frame(height: 34)
    }

    private func generate() {
        guard !question.isEmpty else { return }
        ws.generateTrace(question, includeAnchor: ws.document != nil)
        question = ""
        ws.showGenerateTrace = false
    }
}

/// The hop between two steps: a call found in code, or an inferred one.
struct ConnectorRow: View {
    let ws: Workspace
    let connector: StepConnector
    var body: some View {
        HStack(spacing: 6) {
            Rectangle().fill(connector.kind == .inferred ? Color.clear : Color.secondary.opacity(0.35)).frame(width: 1.5, height: 18)
                .overlay(connector.kind == .inferred
                         ? AnyView(Rectangle().stroke(style: StrokeStyle(lineWidth: 1.5, dash: [3, 3])).foregroundStyle(Color.orange.opacity(0.6)))
                         : AnyView(EmptyView()))
                .padding(.leading, 11).padding(.trailing, 14)
            switch connector.kind {
            case .calls, .calledBy:
                Text(connector.kind == .calls ? "calls" : "called from").font(.system(size: 9, weight: .semibold))
                    .padding(.horizontal, 5).padding(.vertical, 1)
                    .background(Color.green.opacity(0.16), in: RoundedRectangle(cornerRadius: 3)).foregroundStyle(.green)
                if let s = connector.site {
                    Button(s.short) { ws.open(s) }.buttonStyle(.plain).font(.caption2.monospaced()).foregroundStyle(.secondary)
                }
            case .inferred:
                Text("inferred").font(.system(size: 9, weight: .semibold))
                    .padding(.horizontal, 5).padding(.vertical, 1)
                    .background(Color.orange.opacity(0.16), in: RoundedRectangle(cornerRadius: 3)).foregroundStyle(.orange)
                Text("no direct call found (channel, trait object or async hop?)").font(.caption2).foregroundStyle(.tertiary).lineLimit(1)
            }
            Spacer()
        }
    }
}

struct TraceStepRow: View {
    @Bindable var ws: Workspace
    let step: TraceStep
    let index: Int
    let current: Bool
    @State private var draft = ""
    @FocusState private var focused: Bool

    var editing: Bool { ws.editingStepID == step.id }

    var body: some View {
        HStack(alignment: .top, spacing: 8) {
            ZStack {
                Circle().strokeBorder(current ? Color.purple : Color.secondary.opacity(0.5), style: StrokeStyle(lineWidth: 1.5, dash: step.verified ? [] : [2, 2]))
                    .background(Circle().fill(current ? Color.purple : .clear))
                Text(verbatim: String(index + 1)).font(.system(size: 10, weight: .bold)).foregroundStyle(current ? .white : .secondary)
            }
            .frame(width: 20, height: 20)
            VStack(alignment: .leading, spacing: 3) {
                HStack(spacing: 4) {
                    Text(step.title).font(.system(size: 12.5, weight: .semibold, design: .monospaced)).lineLimit(1).truncationMode(.middle)
                    if !step.verified { Image(systemName: "questionmark.circle").font(.caption).foregroundStyle(.orange).help("Claude's location could not be matched to a symbol") }
                    Spacer(minLength: 0)
                }
                if editing {
                    TextEditor(text: $draft)
                        .font(.callout).scrollContentBackground(.hidden)
                        .frame(minHeight: 54, maxHeight: 140)
                        .padding(4)
                        .background(RoundedRectangle(cornerRadius: 6).strokeBorder(Color.accentColor, lineWidth: 1.5))
                        .focused($focused)
                        .onChange(of: draft) { ws.traces.updateStep(step.id) { $0.note = draft } }
                        .onKeyPress(.escape) { ws.editingStepID = nil; return .handled }
                    HStack(spacing: 4) {
                        Text("Saved").font(.caption2).foregroundStyle(.tertiary)
                        Text("·").foregroundStyle(.tertiary)
                        Button("Done") { ws.editingStepID = nil }.buttonStyle(.link).font(.caption2)
                        KeyCap("esc")
                    }
                } else if !step.note.isEmpty {
                    Text(step.note).font(.callout).fixedSize(horizontal: false, vertical: true)
                        .onTapGesture(count: 2) { ws.editingStepID = step.id }
                } else {
                    Button("Add a note") { ws.editingStepID = step.id }.buttonStyle(.link).font(.caption)
                }
                Text(verbatim: "\(step.location.path):\(step.location.displayLine)").font(.system(size: 10, design: .monospaced))
                    .foregroundStyle(.tertiary).lineLimit(1).truncationMode(.head)
            }
        }
        .padding(.vertical, 6).padding(.horizontal, 6)
        .background(current ? Color.purple.opacity(0.12) : Color.clear, in: RoundedRectangle(cornerRadius: 8))
        .onChange(of: editing, initial: true) {
            if editing { draft = step.note; focused = true }
        }
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

/// Unresolved threads first, then your drafts, then resolved ones; checks and reviewers below.
struct ConversationPane: View {
    @Bindable var ws: Workspace
    @Bindable var review: ReviewSession
    let pr: GitHubService.PullRequestDetails
    @State private var showAll = false

    var body: some View {
        let open = pr.threads.filter { !$0.isResolved }
        let resolved = pr.threads.filter(\.isResolved)
        VStack(spacing: 0) {
            HStack {
                Picker("", selection: $showAll) {
                    Text(verbatim: "Open \(open.count + review.pendingComments.count)").tag(false)
                    Text(verbatim: "All \(pr.threads.count + review.pendingComments.count)").tag(true)
                }
                .pickerStyle(.segmented).labelsHidden().frame(width: 170)
                Spacer()
                Button { Task { await review.refreshPullRequest() } } label: { Image(systemName: "arrow.clockwise") }.buttonStyle(.borderless)
            }
            .padding(.horizontal, 12).padding(.vertical, 6)
            List {
                ForEach(open) { t in threadRow(t) }
                ForEach(review.pendingComments) { c in
                    Button { ws.jump(to: c) } label: {
                        VStack(alignment: .leading, spacing: 2) {
                            HStack(spacing: 5) {
                                Text("pending").font(.system(size: 9, weight: .semibold)).padding(.horizontal, 4).padding(.vertical, 1)
                                    .background(Color.blue.opacity(0.2), in: RoundedRectangle(cornerRadius: 3)).foregroundStyle(.blue)
                                Text("You").font(.caption.weight(.semibold))
                                Text(verbatim: c.path.lastPathComponent + ":" + String(c.line)).font(.caption2.monospaced()).foregroundStyle(.secondary)
                            }
                            Text(c.body).font(.caption).lineLimit(2).foregroundStyle(.secondary)
                        }
                        .contentShape(Rectangle())
                    }
                    .buttonStyle(.plain)
                }
                if showAll { ForEach(resolved) { t in threadRow(t).opacity(0.6) } }
                else if !resolved.isEmpty {
                    Button(resolved.count == 1 ? "1 resolved thread" : "\(resolved.count) resolved threads") { showAll = true }
                        .buttonStyle(.link).font(.caption)
                }
                Section {
                    let failed = pr.checks.filter(\.isFailure), pending = pr.checks.filter(\.isPending)
                    HStack(spacing: 6) {
                        Circle().fill(failed.isEmpty ? (pending.isEmpty ? Color.green : .orange) : .red).frame(width: 7, height: 7)
                        Text(verbatim: failed.isEmpty ? (pending.isEmpty ? "\(pr.checks.count) passed" : "\(pending.count) pending") : "\(failed.count) failing")
                            .font(.caption)
                        Text((failed.isEmpty ? pr.checks : failed).prefix(4).map(\.name).joined(separator: ", ")).font(.caption).foregroundStyle(.secondary).lineLimit(1)
                    }
                } header: { Text("Checks").font(.caption.weight(.semibold)) }
                Section {
                    let latest = Dictionary(pr.reviews.map { ($0.author, $0.state) }, uniquingKeysWith: { _, b in b })
                    if latest.isEmpty { Text("No reviews yet").font(.caption).foregroundStyle(.tertiary) }
                    ForEach(latest.keys.sorted(), id: \.self) { a in
                        HStack(spacing: 6) {
                            Avatar(login: a, color: .gray).scaleEffect(0.8)
                            Text(a == ws.github.login ? "You" : a).font(.caption)
                            Text(latest[a]!.replacingOccurrences(of: "_", with: " ").lowercased()).font(.caption)
                                .foregroundStyle(latest[a] == "APPROVED" ? .green : latest[a] == "CHANGES_REQUESTED" ? .red : .secondary)
                        }
                    }
                } header: { Text("Reviewers").font(.caption.weight(.semibold)) }
            }
            .listStyle(.plain)
            .scrollContentBackground(.hidden)
        }
    }

    func threadRow(_ t: GitHubService.ReviewThread) -> some View {
        Button { ws.showThread(t) } label: {
            VStack(alignment: .leading, spacing: 2) {
                HStack(spacing: 5) {
                    Circle().fill(t.isResolved ? Color.secondary : .orange).frame(width: 6, height: 6)
                    Text(t.comments.first?.author ?? "").font(.caption.weight(.semibold))
                    Text(verbatim: t.path.lastPathComponent + ":" + String(t.anchorLine ?? 0)).font(.caption2.monospaced()).foregroundStyle(.secondary)
                    Spacer()
                    Text(InlineThread.ago(t.comments.last?.createdAt ?? "")).font(.caption2).foregroundStyle(.tertiary)
                }
                Text(t.comments.first?.body ?? "").font(.caption).lineLimit(2).foregroundStyle(.secondary)
                if t.comments.count > 1 { Text(verbatim: "\(t.comments.count - 1) replies").font(.caption2).foregroundStyle(.tertiary) }
            }
            .padding(.vertical, 2)
            .background(ws.currentThreadID == t.id ? Color.accentColor.opacity(0.1) : .clear)
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
    }
}
