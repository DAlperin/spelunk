import SwiftUI

/// The working-copy review plus any pinned reviews, as tabs.
struct ReviewTabsView: View {
    @Bindable var ws: Workspace
    @State private var showPicker = false

    var body: some View {
        VStack(spacing: 0) {
            ScrollView(.horizontal, showsIndicators: false) {
                HStack(spacing: 4) {
                    chip(title: "Working copy", subtitle: ws.workingReview.map { workingSubtitle($0) }, icon: "pencil.and.outline",
                         active: ws.activeReviewKey == nil, closable: false) { ws.showWorkingReview() }
                    ForEach(ws.pinnedReviews, id: \.target.key) { r in
                        chip(title: r.target.label, subtitle: nil, icon: r.pullRequest != nil || { if case .githubPR = r.target { return true }; return false }() ? "arrow.triangle.pull" : "square.stack",
                             active: ws.activeReviewKey == r.target.key, closable: true) {
                            ws.activeReviewKey = r.target.key
                        } onClose: {
                            ws.closeReview(r.target.key)
                        }
                    }
                    Button { showPicker = true } label: { Image(systemName: "plus") }
                        .buttonStyle(.borderless).help("Compare something else: a PR, a range, a change")
                        .popover(isPresented: $showPicker) { ReviewPicker(ws: ws, dismiss: { showPicker = false }) }
                }
                .padding(.horizontal, 8)
            }
            .padding(.bottom, 6)
            if let r = ws.review {
                ChangesView(ws: ws, review: r).id(r.target.key)
            } else {
                NoReviewView(ws: ws)
            }
        }
    }

    private func workingSubtitle(_ r: ReviewSession) -> String {
        switch r.target {
        case .jj(_, let to): to == "@" ? "@" : "@- (@ is empty)"
        case .git(_, let head): head == nil ? "uncommitted" : "last commit"
        case .githubPR: ""
        }
    }

    @ViewBuilder
    private func chip(title: String, subtitle: String?, icon: String, active: Bool, closable: Bool,
                      select: @escaping () -> Void, onClose: @escaping () -> Void = {}) -> some View {
        HStack(spacing: 4) {
            Image(systemName: icon).font(.caption2)
            Text(title).font(.caption.weight(active ? .semibold : .regular)).lineLimit(1)
            if let subtitle, !subtitle.isEmpty { Text(subtitle).font(.caption2).foregroundStyle(.secondary) }
            if closable {
                Button(action: onClose) { Image(systemName: "xmark").font(.system(size: 8, weight: .bold)) }
                    .buttonStyle(.plain).foregroundStyle(.secondary).help("Close this review")
            }
        }
        .padding(.horizontal, 8).padding(.vertical, 4)
        .background(active ? Color.accentColor.opacity(0.22) : Color.secondary.opacity(0.1), in: Capsule())
        .contentShape(Capsule())
        .onTapGesture(perform: select)
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
    @State private var showOverview = true

    var body: some View {
        VStack(spacing: 0) {
            header
            Divider()
            switch review.state {
            case .loading(let s):
                ProgressView(s).frame(maxWidth: .infinity, maxHeight: .infinity)
            case .failed(let e):
                ContentUnavailableView("Could not load change", systemImage: "exclamationmark.triangle", description: Text(e))
            default:
                if review.files.isEmpty {
                    ContentUnavailableView("No changes", systemImage: "checkmark.circle")
                } else {
                    list
                }
            }
        }
    }

    var header: some View {
        VStack(alignment: .leading, spacing: 6) {
            Text(review.title).font(.headline).lineLimit(2)
            if let pr = review.pullRequest {
                PullRequestHeader(ws: ws, review: review, pr: pr)
            } else if let e = review.githubError {
                Text(e).font(.caption).foregroundStyle(.red).lineLimit(3)
            }
            HStack(spacing: 8) {
                let p = review.progress
                ProgressView(value: Double(p.viewed), total: Double(max(1, p.total))).frame(width: 80)
                Text("\(p.viewed)/\(p.total) important hunks viewed").font(.caption).foregroundStyle(.secondary)
            }
            ViewThatFits(in: .horizontal) {
                tierChips
                ScrollView(.horizontal, showsIndicators: false) { tierChips }
            }
            if !review.tracksWorkingCopy {
                HStack {
                    CheckoutMenu(ws: ws, review: review)
                    Spacer()
                }
                .controlSize(.small)
            }
            HStack {
                Button {
                    Task { await review.triageWithClaude() }
                } label: {
                    Label(review.llm.isEmpty ? "Triage with Claude" : "Re-triage", systemImage: "sparkles")
                }
                .disabled(review.triaging || review.state != .ready)
                ModelMenu(task: .triage)
                Picker("", selection: $review.groupByTier) {
                    Text("By importance").tag(true)
                    Text("By file").tag(false)
                }.labelsHidden().frame(width: 120)
            }
            .controlSize(.small)
            if let s = review.classifyState {
                HStack(spacing: 4) {
                    Image(systemName: "sparkle").font(.caption2)
                    Text(s).font(.caption).lineLimit(1)
                    Spacer()
                    ModelMenu(task: .classify)
                }
                .foregroundStyle(.secondary)
            }
            if let s = review.triageState {
                Text(s).font(.caption).foregroundStyle(.purple).lineLimit(2)
            }
            if let o = review.overview {
                DisclosureGroup(review.overviewIsStale ? "Overview (written before the latest edits)" : "Overview", isExpanded: $showOverview) {
                    ScrollView { Text(o).font(.caption).textSelection(.enabled).frame(maxWidth: .infinity, alignment: .leading) }
                        .frame(maxHeight: 140)
                }.font(.caption.weight(.semibold))
            } else if !review.body.isEmpty {
                DisclosureGroup("Description", isExpanded: $showOverview) {
                    ScrollView { Text(review.body).font(.caption).textSelection(.enabled) }.frame(maxHeight: 120)
                }.font(.caption.weight(.semibold))
            }
        }
        .padding(.horizontal, 10).padding(.bottom, 8)
    }

    var tierChips: some View {
        HStack(spacing: 4) {
            ForEach(ChangeTier.allCases) { t in
                    let n = review.allHunks.filter { review.tier(of: $0) == t }.count
                    Button {
                        if review.hideTiers.contains(t) { review.hideTiers.remove(t) } else { review.hideTiers.insert(t) }
                    } label: {
                        Text("\(t.shortTitle) \(n)").font(.system(size: 10, weight: .medium)).lineLimit(1).fixedSize()
                            .padding(.horizontal, 6).padding(.vertical, 2)
                            .background(review.hideTiers.contains(t) ? Color.clear : t.color.opacity(0.18), in: Capsule())
                            .overlay(Capsule().strokeBorder(t.color.opacity(0.4)))
                            .foregroundStyle(review.hideTiers.contains(t) ? .secondary : t.color)
                    }
                    .buttonStyle(.plain)
                    .help(review.hideTiers.contains(t) ? "Show \(t.title.lowercased())" : "Hide \(t.title.lowercased())")
            }
        }
    }

    var list: some View {
        List(selection: Binding(get: { ws.selectedHunkID }, set: { id in
            if let id, let h = review.allHunks.first(where: { $0.id == id }) { ws.selectHunk(h) }
        })) {
            if review.groupByTier {
                ForEach(ChangeTier.allCases) { tier in
                    let hs = review.hunks(in: tier)
                    if !hs.isEmpty {
                        Section {
                            if review.hideTiers.contains(tier) {
                                Button {
                                    review.hideTiers.remove(tier)
                                } label: {
                                    Label("Show \(hs.count) \(tier.shortTitle.lowercased()) hunks", systemImage: "chevron.down")
                                        .font(.caption).foregroundStyle(.secondary)
                                        .frame(maxWidth: .infinity, alignment: .leading).contentShape(Rectangle())
                                }
                                .buttonStyle(.plain)
                                .selectionDisabled()
                            } else {
                                ForEach(hs) { h in HunkRow(review: review, hunk: h, showFile: true).tag(h.id) }
                            }
                        } header: {
                            Button {
                                if review.hideTiers.contains(tier) { review.hideTiers.remove(tier) } else { review.hideTiers.insert(tier) }
                            } label: {
                                HStack {
                                    Image(systemName: review.hideTiers.contains(tier) ? "chevron.right" : "chevron.down").font(.caption2)
                                    Circle().fill(tier.color).frame(width: 7, height: 7)
                                    Text(tier.title)
                                    Spacer()
                                    Text("\(hs.count)").foregroundStyle(.secondary)
                                }
                                .contentShape(Rectangle())
                            }
                            .buttonStyle(.plain)
                            .help(review.hideTiers.contains(tier) ? "Show these hunks" : "Collapse these hunks")
                        }
                    }
                }
            } else {
                ForEach(review.files.sorted { review.fileTier($0) < review.fileTier($1) }) { f in
                    Section {
                        ForEach(f.hunks.filter { !review.hideTiers.contains(review.tier(of: $0)) }) { h in
                            HunkRow(review: review, hunk: h, showFile: false).tag(h.id)
                        }
                    } header: {
                        HStack {
                            Circle().fill(review.fileTier(f).color).frame(width: 7, height: 7)
                            Text(f.path).lineLimit(1).truncationMode(.head)
                            Spacer()
                            Text(f.status == .modified ? "" : f.status.rawValue).foregroundStyle(.secondary)
                            Text("+\(f.addedCount) −\(f.removedCount)").font(.caption2.monospaced()).foregroundStyle(.secondary)
                        }
                    }
                }
            }
        }
        .listStyle(.sidebar)
    }
}

struct HunkRow: View {
    let review: ReviewSession
    let hunk: Hunk
    let showFile: Bool

    var body: some View {
        let a = review.analyses[hunk.id]
        let viewed = review.isViewed(hunk)
        VStack(alignment: .leading, spacing: 2) {
            HStack(spacing: 4) {
                Image(systemName: viewed ? "checkmark.circle.fill" : "circle")
                    .foregroundStyle(viewed ? .green : .secondary).font(.caption)
                    .onTapGesture { review.toggleViewed(hunk) }
                Text(a?.enclosing ?? hunk.path.lastPathComponent)
                    .font(.system(size: 12, weight: .medium, design: .monospaced)).lineLimit(1)
                Spacer()
                let threads = review.threads(for: hunk)
                if !threads.isEmpty {
                    let open = threads.filter { !$0.isResolved }.count
                    Label("\(threads.count)", systemImage: open > 0 ? "bubble.left.fill" : "bubble.left")
                        .font(.caption2).foregroundStyle(open > 0 ? .orange : .secondary).labelStyle(.titleAndIcon)
                }
                if !review.pending(for: hunk).isEmpty { Image(systemName: "pencil.circle.fill").font(.caption2).foregroundStyle(.blue) }
                if let t = review.triage(of: hunk) {
                    Image(systemName: t.isQuick ? "sparkle" : "sparkles").font(.caption2).foregroundStyle(.purple)
                        .help(t.isQuick ? "Classified by the quick pass" : "Triaged by Claude")
                }
                Text("+\(hunk.addedCount) −\(hunk.removedCount)").font(.caption2.monospaced()).foregroundStyle(.secondary)
            }
            if showFile {
                Text(hunk.path).font(.caption2).foregroundStyle(.secondary).lineLimit(1).truncationMode(.head)
            }
            Text(review.reasons(of: hunk).joined(separator: " · ")).font(.caption).foregroundStyle(review.tier(of: hunk).color).lineLimit(2)
        }
        .opacity(viewed ? 0.55 : 1)
        .padding(.vertical, 2)
    }
}
