import SwiftUI

/// The working-copy review plus any pinned reviews, as tabs.
/// The active review (working copy or a pinned one, chosen from the toolbar).
struct ReviewTabsView: View {
    @Bindable var ws: Workspace

    var body: some View {
        if let r = ws.review {
            ChangesView(ws: ws, review: r).id(r.target.key)
        } else {
            NoReviewView(ws: ws)
        }
    }
}

/// Puts a pinned review's change into the working copy, after confirmation.
struct CheckoutMenu: View {
    @Bindable var ws: Workspace
    let review: ReviewSession
    @State private var options: [ReviewSession.CheckoutOption] = []
    @State private var pending: ReviewSession.CheckoutOption?

    var body: some View {
        Menu {
            if options.isEmpty { Text("Nothing to check out") }
            ForEach(options) { o in Button(o.label) { pending = o } }
        } label: {
            Label("Check out", systemImage: "arrow.down.to.line")
        }
        .fixedSize()
        .task(id: review.target.key) { options = await review.checkoutOptions(repoVCS: ws.vcs.kind) }
        .onChange(of: review.pullRequest?.headSha) { Task { options = await review.checkoutOptions(repoVCS: ws.vcs.kind) } }
        .confirmationDialog(pending?.label ?? "", isPresented: Binding(get: { pending != nil }, set: { if !$0 { pending = nil } })) {
            Button("Check Out") {
                if let o = pending { Task { await ws.checkOut(review, o) } }
                pending = nil
            }
            Button("Cancel", role: .cancel) { pending = nil }
        } message: {
            Text(((pending?.detail.isEmpty ?? true) ? "" : pending!.detail + "\n\n") + (pending?.steps.map { $0.joined(separator: " ") }.joined(separator: "\n") ?? ""))
        }
    }
}

struct ChangesView: View {
    @Bindable var ws: Workspace
    @Bindable var review: ReviewSession
    @State private var descriptionOpen = false

    var body: some View {
        VStack(spacing: 0) {
            header
            Divider()
            switch review.state {
            case .loading(let s):
                ProgressView(s).frame(maxWidth: .infinity, maxHeight: .infinity)
            case .failed(let e):
                ContentUnavailableView {
                    Label("Could not load change", systemImage: "exclamationmark.triangle")
                } description: {
                    Text(e)
                } actions: {
                    HStack {
                        Button("Retry") { Task { await review.load() } }
                        if !review.tracksWorkingCopy { Button("Close Review") { ws.closeReview(review.target.key) } }
                    }
                }
                .frame(maxHeight: .infinity)
            default:
                if review.files.isEmpty {
                    ContentUnavailableView("No changes", systemImage: "checkmark.circle").frame(maxHeight: .infinity)
                } else {
                    switch review.listMode {
                    case .importance: tierList
                    case .files: fileList
                    }
                }
            }
        }
    }

    // MARK: Header

    var header: some View {
        VStack(alignment: .leading, spacing: 6) {
            if let pr = review.pullRequest {
                prHeader(pr)
            } else {
                HStack(spacing: 6) {
                    if let id = review.changeID {
                        Text(verbatim: (review.tracksWorkingCopy ? "@ " : "") + id).font(.caption.monospaced()).foregroundStyle(.purple)
                    }
                    Text(verbatim: "· \(review.files.count) files · +\(review.addedCount) −\(review.removedCount)")
                        .font(.caption).foregroundStyle(.secondary)
                    Spacer()
                    if review.tracksWorkingCopy {
                        HStack(spacing: 3) { Circle().fill(.green).frame(width: 6, height: 6); Text("live") }
                            .font(.caption).foregroundStyle(.secondary).help("Refreshes as files change on disk")
                    } else {
                        CheckoutMenu(ws: ws, review: review).controlSize(.small)
                    }
                }
                Text(review.title).font(.headline).lineLimit(3)
                if let n = review.linkedPR {
                    HStack(spacing: 6) {
                        Image(systemName: "arrow.triangle.pull").font(.caption)
                        Text(verbatim: "PR #\(n)").font(.caption.monospaced().weight(.semibold))
                        if let b = review.linkedBookmark { Text(verbatim: b).font(.caption.monospaced()).foregroundStyle(.secondary).lineLimit(1) }
                        if let pr = review.pullRequest { ChecksSummary(checks: pr.checks) }
                        Spacer()
                        if review.linkedInSync == false {
                            Text("local ahead of push").font(.caption).foregroundStyle(.orange)
                                .help("The pull request's comments anchor to the pushed head; lines may not match until you push.")
                        }
                        Button("Conversation") { ws.inspectorPane = .conversation; ws.showInspector = true }.buttonStyle(.link).font(.caption)
                    }
                    .padding(6)
                    .background(Color.green.opacity(0.08), in: RoundedRectangle(cornerRadius: 5))
                }
                if let e = review.githubError { Text(e).font(.caption).foregroundStyle(.red).lineLimit(2) }
            }
            ImportanceBar(review: review)
            HStack(spacing: 8) {
                let p = review.progress
                ProgressView(value: Double(p.viewed), total: Double(max(1, p.total))).frame(minWidth: 30, maxWidth: 70)
                Text(verbatim: "\(p.viewed)/\(p.total) important reviewed").font(.caption).foregroundStyle(.secondary).lineLimit(1).fixedSize()
                if let pr = review.pullRequest {
                    let open = pr.threads.filter { !$0.isResolved }.count
                    if open > 0 {
                        Text(verbatim: "● \(open) unresolved").font(.caption).foregroundStyle(.orange).lineLimit(1).fixedSize()
                    }
                }
                Spacer()
                TriageMenu(ws: ws, review: review)
            }
            Picker("", selection: $review.listMode) {
                ForEach(ReviewSession.ListMode.allCases) { m in Text(m.rawValue).tag(m) }
            }
            .pickerStyle(.segmented).labelsHidden().controlSize(.small)
            if !review.ruleErrors.isEmpty {
                Label("\(review.ruleErrors.count) rule errors", systemImage: "exclamationmark.triangle").font(.caption).foregroundStyle(.red)
                    .onTapGesture { RulesFiles.openUserRules() }
                    .help(review.ruleErrors.joined(separator: "\n"))
            }
            if let s = review.ruleState {
                HStack(spacing: 4) { ProgressView().controlSize(.mini); Text(s).lineLimit(1).truncationMode(.tail) }
                    .font(.caption).foregroundStyle(.secondary)
            }
            if review.triaging || review.classifyState?.hasPrefix("Classifying") == true {
                HStack(spacing: 4) {
                    ProgressView().controlSize(.mini)
                    Text(review.triaging ? (review.triageState ?? "Triaging") : (review.classifyState ?? "")).lineLimit(1)
                }
                .font(.caption).foregroundStyle(.purple)
            }
        }
        .padding(.horizontal, 10).padding(.top, 4).padding(.bottom, 8)
    }

    @ViewBuilder func prHeader(_ pr: GitHubService.PullRequestDetails) -> some View {
        HStack(spacing: 6) {
            Text(verbatim: "#" + String(pr.number)).font(.callout.monospaced().weight(.semibold))
            Text(pr.isDraft ? "Draft" : pr.state.capitalized).font(.caption2.weight(.semibold))
                .padding(.horizontal, 5).padding(.vertical, 1)
                .background((pr.state == "OPEN" ? Color.green : Color.purple).opacity(0.18), in: Capsule())
            ChecksSummary(checks: pr.checks)
            Spacer()
            HeadIntelButton(review: review)
            CheckoutMenu(ws: ws, review: review).controlSize(.small)
        }
        Text(pr.title).font(.headline).lineLimit(3)
        HStack(spacing: 4) {
            Text(verbatim: "\(pr.author) → \(pr.baseRef)")
            if let d = pr.reviewDecision {
                Text("·")
                Text(d == "REVIEW_REQUIRED" ? "review required" : d.replacingOccurrences(of: "_", with: " ").lowercased())
                    .foregroundStyle(d == "APPROVED" ? .green : d == "CHANGES_REQUESTED" ? .red : .secondary)
            }
        }
        .font(.caption).foregroundStyle(.secondary).lineLimit(1)
        if let b = review.linkedBookmark {
            HStack(spacing: 4) {
                Image(systemName: "link").font(.caption2)
                Text(verbatim: "local review of \(b)").lineLimit(1).truncationMode(.middle)
                if let sync = review.linkedInSync {
                    Text("·")
                    Text(sync ? "matches pushed head" : "local ahead of push").foregroundStyle(sync ? .green : .orange)
                        .help(sync ? "" : "Comments anchor to the pushed head; lines may not match until you push.")
                }
            }
            .font(.caption).foregroundStyle(.secondary)
        }
        if !review.body.isEmpty {
            VStack(alignment: .leading, spacing: 2) {
                Text(review.body).font(.caption).foregroundStyle(.secondary).lineLimit(descriptionOpen ? 30 : 2)
                    .textSelection(.enabled)
                Button(descriptionOpen ? "Less" : "More") { descriptionOpen.toggle() }.buttonStyle(.link).font(.caption)
            }
        }
    }

    // MARK: Lists

    var selection: Binding<String?> {
        Binding(get: { ws.selectedHunkID }, set: { id in
            if let id, let h = review.allHunks.first(where: { $0.id == id }) { ws.selectHunk(h) }
        })
    }

    var tierList: some View {
        List(selection: selection) {
            if review.grouping || review.groupState != nil {
                HStack(spacing: 4) {
                    if review.grouping { ProgressView().controlSize(.mini) }
                    Text(review.groupState ?? "").lineLimit(1).truncationMode(.tail)
                }
                .font(.caption).foregroundStyle(.purple).selectionDisabled()
            }
            ForEach(review.tierSections) { section in
                let hs = section.hunks
                Section {
                    ForEach(section.items) { item in
                        switch item {
                        case .hunk(let h):
                            ImportantHunkRow(review: review, hunk: h, selected: ws.selectedHunkID == h.id).tag(h.id)
                        case .group(let g, let members):
                            GroupRow(review: review, group: g, hunks: members).selectionDisabled()
                            if review.expandedGroups.contains(g.id) {
                                ForEach(members) { h in
                                    ImportantHunkRow(review: review, hunk: h, selected: ws.selectedHunkID == h.id, showTier: review.tier(of: h) != section.tier)
                                        .padding(.leading, 14)
                                        .overlay(alignment: .leading) { Rectangle().fill(Color.secondary.opacity(0.25)).frame(width: 1.5).padding(.leading, 5) }
                                        .tag(h.id)
                                }
                            }
                        }
                    }
                } header: {
                    HStack(spacing: 5) {
                        Image(systemName: section.tier.glyph).font(.system(size: 8)).foregroundStyle(section.tier.color)
                        Text(section.tier.title).foregroundStyle(section.tier.color)
                        Spacer()
                        Text(verbatim: "\(hs.filter(review.isViewed).count)/\(hs.count)").foregroundStyle(.secondary)
                    }
                }
            }
            let low = ChangeTier.lowSignal.flatMap { review.hunks(in: $0) }
            if !low.isEmpty {
                Section {
                    LowSignalBox(review: review, hunks: low, open: $review.showLowSignal)
                        .selectionDisabled()
                    if review.showLowSignal {
                        ForEach(ChangeTier.lowSignal) { tier in
                            ForEach(review.hunks(in: tier)) { h in LowSignalRow(review: review, hunk: h).tag(h.id) }
                        }
                    }
                }
            }
        }
        .listStyle(.sidebar)
    }

    @ViewBuilder func row(_ h: Hunk) -> some View {
        if review.tier(of: h).isLowSignal { LowSignalRow(review: review, hunk: h).tag(h.id) }
        else { ImportantHunkRow(review: review, hunk: h, selected: ws.selectedHunkID == h.id).tag(h.id) }
    }

    var fileList: some View {
        List(selection: selection) {
            ForEach(review.files.sorted { review.fileTier($0) < review.fileTier($1) }) { f in
                Section {
                    ForEach(f.hunks) { h in
                        if review.tier(of: h).isLowSignal { LowSignalRow(review: review, hunk: h).tag(h.id) }
                        else { ImportantHunkRow(review: review, hunk: h, selected: ws.selectedHunkID == h.id).tag(h.id) }
                    }
                } header: {
                    HStack {
                        Image(systemName: review.fileTier(f).glyph).font(.system(size: 8)).foregroundStyle(review.fileTier(f).color)
                        Text(f.path).lineLimit(1).truncationMode(.middle)
                        Spacer()
                        Text(verbatim: "+\(f.addedCount) −\(f.removedCount)").font(.caption2.monospaced()).foregroundStyle(.secondary)
                    }
                }
            }
        }
        .listStyle(.sidebar)
    }
}

/// A collapsible row for related hunks inside the importance list.
struct GroupRow: View {
    @Bindable var review: ReviewSession
    let group: HunkGroup
    let hunks: [Hunk]
    var body: some View {
        let open = review.expandedGroups.contains(group.id)
        Button {
            if open { review.expandedGroups.remove(group.id) } else { review.expandedGroups.insert(group.id) }
        } label: {
            HStack(spacing: 6) {
                Image(systemName: "chevron.right").font(.system(size: 9, weight: .semibold)).rotationEffect(.degrees(open ? 90 : 0))
                    .foregroundStyle(.secondary).frame(width: 10)
                Image(systemName: group.glyph).font(.system(size: 11))
                    .foregroundStyle(group.kind == .claude ? Color.purple : group.kind == .removes ? .red : group.kind == .adds ? .green : .secondary)
                VStack(alignment: .leading, spacing: 1) {
                    Text(group.title).font(.system(size: 12, weight: .medium)).lineLimit(1).truncationMode(.tail)
                    Text(verbatim: "\(hunks.count) hunks · \(Set(hunks.map(\.path)).count) files" + (group.rationale.map { " · " + $0 } ?? ""))
                        .font(.caption).foregroundStyle(.secondary).lineLimit(1).truncationMode(.tail)
                }
                Spacer(minLength: 4)
                Text(verbatim: "\(hunks.filter(review.isViewed).count)/\(hunks.count)").font(.caption2.monospaced()).foregroundStyle(.secondary).fixedSize()
            }
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .help(group.rationale ?? group.title)
        .padding(.vertical, 3)
    }
}

struct GroupHeader: View {
    let review: ReviewSession
    let group: HunkGroup
    let hunks: [Hunk]
    var body: some View {
        HStack(spacing: 5) {
            Image(systemName: group.glyph).font(.system(size: 9))
                .foregroundStyle(group.kind == .claude ? Color.purple : group.kind == .removes ? .red : group.kind == .adds ? .green : .secondary)
            Text(group.title).lineLimit(1).truncationMode(.tail).help(group.rationale ?? group.title)
            Spacer(minLength: 4)
            Text(verbatim: "\(hunks.filter(review.isViewed).count)/\(hunks.count) · \(Set(hunks.map(\.path)).count) files")
                .foregroundStyle(.secondary).fixedSize()
        }
    }
}

/// One proportional bar for the tier mix, with a line of non-zero counts.
struct ImportanceBar: View {
    let review: ReviewSession

    var body: some View {
        let counts = ChangeTier.important.map { ($0, review.hunks(in: $0).count) }
        let low = ChangeTier.lowSignal.reduce(0) { $0 + review.hunks(in: $1).count }
        let total = max(1, counts.reduce(0) { $0 + $1.1 } + low)
        VStack(alignment: .leading, spacing: 3) {
            GeometryReader { g in
                HStack(spacing: 2) {
                    ForEach(counts.filter { $0.1 > 0 }, id: \.0) { t, n in
                        RoundedRectangle(cornerRadius: 2).fill(t.color).frame(width: max(4, g.size.width * CGFloat(n) / CGFloat(total)))
                    }
                    if low > 0 { RoundedRectangle(cornerRadius: 2).fill(Color.secondary.opacity(0.35)) }
                }
            }
            .frame(height: 5)
            HStack(spacing: 4) {
                ForEach(counts.filter { $0.1 > 0 }, id: \.0) { t, n in
                    Text(verbatim: "\(n) \(t.title.lowercased())").foregroundStyle(t.color).fixedSize()
                    Text("·").foregroundStyle(.tertiary)
                }
                Text(verbatim: "\(low) low-signal").foregroundStyle(.secondary).fixedSize()
            }
            .font(.caption).lineLimit(1)
        }
    }
}

struct ChecksSummary: View {
    let checks: [GitHubService.Check]
    @State private var show = false
    var body: some View {
        let failed = checks.filter(\.isFailure).count, pending = checks.filter(\.isPending).count
        Button { show.toggle() } label: {
            HStack(spacing: 3) {
                Circle().fill(failed > 0 ? Color.red : pending > 0 ? .orange : .green).frame(width: 6, height: 6)
                Text(verbatim: failed > 0 ? "\(failed) failing" : pending > 0 ? "\(pending) pending" : "\(checks.count) checks")
            }
            .font(.caption).foregroundStyle(.secondary)
        }
        .buttonStyle(.plain)
        .popover(isPresented: $show) { ChecksList(checks: checks) }
    }
}

/// Deep triage, quick classification and list options, in one menu.
struct TriageMenu: View {
    @Bindable var ws: Workspace
    @Bindable var review: ReviewSession

    var body: some View {
        Menu {
            Button(review.llm.values.contains { $0.pass == .deep } ? "Re-run Deep Triage" : "Deep Triage with Claude") {
                Task { await review.triageWithClaude() }
            }
            .disabled(review.triaging || review.state != .ready)
            modelMenu("Deep triage model", .triage)
            Divider()
            Button("Classify New Hunks Now") { Task { await review.quickClassify() } }
            modelMenu("Quick classification model", .classify)
            if let s = review.classifyState { Text(s) }
            if let s = review.triageState { Text(s) }
            Divider()
            Toggle("Keep Related Hunks Together", isOn: $review.groupRelated)
            Button(review.claudeGroups.isEmpty ? "Group with Claude" : "Regroup with Claude") { Task { await review.groupWithClaude() } }
                .disabled(review.grouping || review.state != .ready)
            modelMenu("Grouping model", .group)
            if let s = review.groupState { Text(s) }
            Divider()
            Button("New Rule from Description…") { ws.showRuleWriter = true }
            Button("Edit Review Rules…") { RulesFiles.openUserRules() }
            modelMenu("Rule questions model", .rules)
            modelMenu("Attachments model", .attach)
        } label: {
            Label("Triage", systemImage: "sparkles")
        }
        .menuStyle(.borderlessButton)
        .fixedSize()
        .font(.caption)
    }

    func modelMenu(_ title: String, _ task: ClaudeTask) -> some View {
        Menu(title + ": " + ClaudeModels.label(Claude.model(for: task))) {
            ForEach(ClaudeModels.aliases, id: \.id) { m in
                Button(m.label) { UserDefaults.standard.set(m.id, forKey: task.modelKey) }
            }
        }
    }
}

struct ImportantHunkRow: View {
    let review: ReviewSession
    let hunk: Hunk
    let selected: Bool
    /// Marks the hunk's own tier when it is listed under another tier's group.
    var showTier = false

    var body: some View {
        let viewed = review.isViewed(hunk)
        HStack(alignment: .top, spacing: 6) {
            Image(systemName: viewed ? "checkmark.circle.fill" : "circle")
                .foregroundStyle(viewed ? .green : .secondary).font(.callout)
                .onTapGesture { review.toggleViewed(hunk) }
                .help("Mark viewed (V)")
            VStack(alignment: .leading, spacing: 2) {
                HStack(spacing: 4) {
                    if showTier {
                        let t = review.tier(of: hunk)
                        Image(systemName: t.glyph).font(.system(size: 7)).foregroundStyle(t.color).help(t.title)
                    }
                    Text(review.analyses[hunk.id]?.enclosing ?? hunk.path.lastPathComponent)
                        .font(.system(size: 12, weight: .medium, design: .monospaced)).lineLimit(1).truncationMode(.middle)
                    Spacer(minLength: 2)
                    badges
                    Text(verbatim: sizeText).font(.caption2.monospaced()).foregroundStyle(.secondary)
                }
                Text(review.summary(of: hunk)).font(.caption).foregroundStyle(.secondary).lineLimit(2)
                Text(verbatim: review.location(of: hunk)).font(.caption2.monospaced()).foregroundStyle(.tertiary)
            }
        }
        .opacity(viewed && !selected ? 0.55 : 1)
        .padding(.vertical, 3)
    }

    var sizeText: String {
        hunk.addedCount == 0 ? "−\(hunk.removedCount)" : hunk.removedCount == 0 ? "+\(hunk.addedCount)" : "+\(hunk.addedCount) −\(hunk.removedCount)"
    }

    @ViewBuilder var badges: some View {
        let threads = review.threads(for: hunk)
        if !threads.isEmpty {
            let open = threads.filter { !$0.isResolved }.count
            Label(String(threads.count), systemImage: "text.bubble").labelStyle(.titleAndIcon)
                .font(.caption2).foregroundStyle(open > 0 ? .orange : .secondary)
        }
        if !review.pending(for: hunk).isEmpty { Image(systemName: "pencil.circle.fill").font(.caption2).foregroundStyle(.blue) }
        if !review.attachments(for: hunk).isEmpty { Image(systemName: "paperclip").font(.caption2).foregroundStyle(.secondary).help("Has attachments") }
        if let t = review.triage(of: hunk) {
            Image(systemName: t.isQuick ? "sparkle" : "sparkles").font(.caption2).foregroundStyle(.purple)
                .help(t.isQuick ? "Classified by the quick pass" : "Triaged by Claude")
        }
    }
}

/// Docs, tests and mechanical hunks, acknowledged together.
struct LowSignalBox: View {
    let review: ReviewSession
    let hunks: [Hunk]
    @Binding var open: Bool

    var body: some View {
        VStack(alignment: .leading, spacing: 4) {
            HStack(spacing: 6) {
                Button { open.toggle() } label: {
                    HStack(spacing: 4) {
                        Image(systemName: open ? "chevron.down" : "chevron.right").font(.caption2)
                        Image(systemName: "minus").font(.caption2).foregroundStyle(.secondary)
                        Text("Low signal").fontWeight(.medium).fixedSize()
                        Text(verbatim: "\(hunks.count)").font(.caption).foregroundStyle(.secondary).fixedSize()
                    }
                    .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
                Spacer()
                let unviewed = hunks.filter { !review.isViewed($0) }
                Button("Mark viewed") { review.markViewed(hunks) }.controlSize(.mini).disabled(unviewed.isEmpty).fixedSize()
            }
            if !open {
                ForEach(ChangeTier.lowSignal) { t in
                    let hs = review.hunks(in: t)
                    if !hs.isEmpty {
                        Text(verbatim: "\(t.title) \(hs.count) · " + Self.describe(hs, review)).font(.caption).foregroundStyle(.secondary).lineLimit(1)
                    }
                }
            }
        }
        .padding(8)
        .background(RoundedRectangle(cornerRadius: 6).strokeBorder(Color.secondary.opacity(0.25)))
    }

    static func describe(_ hs: [Hunk], _ r: ReviewSession) -> String {
        var seen: [String] = []
        for h in hs {
            let s = r.reasons(of: h).first ?? h.path.lastPathComponent
            if !seen.contains(s) { seen.append(s) }
        }
        return seen.prefix(3).joined(separator: ", ")
    }
}

struct LowSignalRow: View {
    let review: ReviewSession
    let hunk: Hunk
    var body: some View {
        let viewed = review.isViewed(hunk)
        HStack(spacing: 6) {
            Image(systemName: viewed ? "checkmark.circle.fill" : "circle").font(.caption)
                .foregroundStyle(viewed ? .green : .secondary)
                .onTapGesture { review.toggleViewed(hunk) }
            Text(review.analyses[hunk.id]?.enclosing ?? hunk.path.lastPathComponent).font(.caption.monospaced()).lineLimit(1)
            Text(review.reasons(of: hunk).first ?? "").font(.caption2).foregroundStyle(.secondary).lineLimit(1)
            Spacer()
            Text(verbatim: review.location(of: hunk)).font(.caption2.monospaced()).foregroundStyle(.tertiary)
        }
        .opacity(viewed ? 0.55 : 0.85)
    }
}

/// Starts or shows the review head's own rust-analyzer.
struct HeadIntelButton: View {
    @Bindable var review: ReviewSession
    var body: some View {
        let _ = review.headIntelVersion
        if review.afterIsWorkingCopy || !review.files.contains(where: { $0.path.hasSuffix(".rs") }) {
            EmptyView()
        } else if let h = review.headIntel {
            TimelineView(.periodic(from: .now, by: 2)) { _ in
                HStack(spacing: 3) {
                    Circle().fill(h.server.status == .ready ? Color.green : h.server.status.isUsable ? .yellow : .gray).frame(width: 6, height: 6)
                    Text(h.server.status == .ready ? "head indexed" : "indexing head").font(.caption).foregroundStyle(.secondary)
                }
                .help("This PR's own rust-analyzer: \(h.server.status.label). Symbols in PR files are answered about the PR's code.")
            }
        } else {
            Button("Index head") { Task { await review.startHeadIntel() } }
                .buttonStyle(.link).font(.caption)
                .help("Start a rust-analyzer on this PR's head so answers come from the PR's own code (a second full index)")
        }
    }
}
