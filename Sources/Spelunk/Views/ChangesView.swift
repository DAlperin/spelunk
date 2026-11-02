import SwiftUI

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
            HStack(spacing: 8) {
                let p = review.progress
                ProgressView(value: Double(p.viewed), total: Double(max(1, p.total))).frame(width: 80)
                Text("\(p.viewed)/\(p.total) important hunks viewed").font(.caption).foregroundStyle(.secondary)
            }
            ViewThatFits(in: .horizontal) {
                tierChips
                ScrollView(.horizontal, showsIndicators: false) { tierChips }
            }
            HStack {
                Button {
                    Task { await review.triageWithClaude() }
                } label: {
                    Label(review.llm.isEmpty ? "Triage with Claude" : "Re-triage", systemImage: "sparkles")
                }
                .disabled(review.triageState == "Asking Claude" || review.state != .ready)
                Picker("", selection: $review.groupByTier) {
                    Text("By importance").tag(true)
                    Text("By file").tag(false)
                }.labelsHidden().frame(width: 120)
            }
            .controlSize(.small)
            if let s = review.triageState {
                Text(s).font(.caption).foregroundStyle(.purple).lineLimit(2)
            }
            if let o = review.overview {
                DisclosureGroup("Overview", isExpanded: $showOverview) {
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
                                Text("\(hs.count) hunks hidden").font(.caption).foregroundStyle(.secondary)
                            } else {
                                ForEach(hs) { h in HunkRow(review: review, hunk: h, showFile: true).tag(h.id) }
                            }
                        } header: {
                            HStack {
                                Circle().fill(tier.color).frame(width: 7, height: 7)
                                Text(tier.title)
                                Spacer()
                                Text("\(hs.count)").foregroundStyle(.secondary)
                            }
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
        let viewed = review.viewed.contains(hunk.id)
        VStack(alignment: .leading, spacing: 2) {
            HStack(spacing: 4) {
                Image(systemName: viewed ? "checkmark.circle.fill" : "circle")
                    .foregroundStyle(viewed ? .green : .secondary).font(.caption)
                    .onTapGesture { review.toggleViewed(hunk.id) }
                Text(a?.enclosing ?? hunk.path.lastPathComponent)
                    .font(.system(size: 12, weight: .medium, design: .monospaced)).lineLimit(1)
                Spacer()
                if review.llm[hunk.id] != nil { Image(systemName: "sparkles").font(.caption2).foregroundStyle(.purple) }
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
