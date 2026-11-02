import AppKit
import SwiftUI

/// Pull request status shown above the change list.
struct PullRequestHeader: View {
    @Bindable var ws: Workspace
    @Bindable var review: ReviewSession
    let pr: GitHubService.PullRequestDetails
    @State private var showChecks = false

    var body: some View {
        VStack(alignment: .leading, spacing: 4) {
            HStack(spacing: 6) {
                Text(pr.isDraft ? "Draft" : pr.state.capitalized).font(.caption2.weight(.semibold))
                    .padding(.horizontal, 5).padding(.vertical, 1)
                    .background((pr.state == "OPEN" ? Color.green : Color.purple).opacity(0.18), in: Capsule())
                Text(verbatim: "\(pr.author) · \(pr.headRef) → \(pr.baseRef)").font(.caption).foregroundStyle(.secondary).lineLimit(1)
                Spacer()
                Button { if let u = URL(string: pr.url) { NSWorkspace.shared.open(u) } } label: { Image(systemName: "safari") }
                    .buttonStyle(.borderless).help("Open on GitHub")
                Button { Task { await review.refreshPullRequest() } } label: { Image(systemName: "arrow.clockwise") }
                    .buttonStyle(.borderless).help("Refresh comments and checks")
            }
            HStack(spacing: 8) {
                let failed = pr.checks.filter(\.isFailure).count
                let pending = pr.checks.filter(\.isPending).count
                Button { showChecks.toggle() } label: {
                    Label(failed > 0 ? "\(failed) failing" : pending > 0 ? "\(pending) pending" : "\(pr.checks.count) checks passed",
                          systemImage: failed > 0 ? "xmark.circle.fill" : pending > 0 ? "clock" : "checkmark.circle.fill")
                        .foregroundStyle(failed > 0 ? .red : pending > 0 ? .orange : .green)
                }
                .buttonStyle(.plain).font(.caption)
                .popover(isPresented: $showChecks) { ChecksList(checks: pr.checks) }
                if let d = pr.reviewDecision {
                    Text(d.replacingOccurrences(of: "_", with: " ").lowercased()).font(.caption)
                        .foregroundStyle(d == "APPROVED" ? .green : d == "CHANGES_REQUESTED" ? .red : .secondary)
                }
                let open = pr.threads.filter { !$0.isResolved }.count
                if !pr.threads.isEmpty {
                    Label("\(open)/\(pr.threads.count)", systemImage: "bubble.left.and.bubble.right").font(.caption)
                        .foregroundStyle(open > 0 ? .orange : .secondary)
                        .help("\(open) unresolved of \(pr.threads.count) review threads")
                }
            }
            HStack {
                Button {
                    ws.showSubmitReview = true
                } label: {
                    Label(review.pendingComments.isEmpty ? "Review…" : "Submit review (\(review.pendingComments.count))", systemImage: "paperplane")
                }
                .controlSize(.small)
                Text("Add comments from the editor's context menu").font(.caption2).foregroundStyle(.tertiary)
            }
        }
    }
}

struct ChecksList: View {
    let checks: [GitHubService.Check]
    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 4) {
                ForEach(checks.sorted { ($0.isFailure ? 0 : $0.isPending ? 1 : 2, $0.name) < ($1.isFailure ? 0 : $1.isPending ? 1 : 2, $1.name) }) { c in
                    HStack {
                        Image(systemName: c.isFailure ? "xmark.circle.fill" : c.isPending ? "clock" : "checkmark.circle.fill")
                            .foregroundStyle(c.isFailure ? .red : c.isPending ? .orange : .green)
                        if let u = c.url.flatMap(URL.init(string:)) {
                            Link(c.name, destination: u).font(.caption)
                        } else {
                            Text(c.name).font(.caption)
                        }
                        Spacer()
                        Text(c.state.lowercased()).font(.caption2).foregroundStyle(.secondary)
                    }
                }
            }.padding(12)
        }
        .frame(width: 380, height: 360)
    }
}

/// Review threads and pending comments for one hunk.
struct HunkConversation: View {
    @Bindable var ws: Workspace
    @Bindable var review: ReviewSession
    let hunk: Hunk
    @State private var replyDrafts: [String: String] = [:]
    @State private var busy: String?
    @State private var error: String?

    var body: some View {
        let threads = review.threads(for: hunk)
        let pending = review.pending(for: hunk)
        if !threads.isEmpty || !pending.isEmpty {
            VStack(alignment: .leading, spacing: 6) {
                ForEach(threads) { t in thread(t) }
                ForEach(pending) { c in
                    HStack(alignment: .top) {
                        Image(systemName: "pencil.circle").foregroundStyle(.blue)
                        VStack(alignment: .leading, spacing: 1) {
                            Text(verbatim: "Pending · \(c.side == "LEFT" ? "old" : "new") line \(c.line)").font(.caption2).foregroundStyle(.secondary)
                            Text(c.body).font(.caption).textSelection(.enabled)
                        }
                        Spacer()
                        Button { review.removePending(c.id) } label: { Image(systemName: "trash") }.buttonStyle(.borderless)
                    }
                }
                if let e = error { Text(e).font(.caption).foregroundStyle(.red) }
            }
        }
    }

    @ViewBuilder func thread(_ t: GitHubService.ReviewThread) -> some View {
        VStack(alignment: .leading, spacing: 4) {
            HStack {
                Image(systemName: t.isResolved ? "checkmark.bubble" : "bubble.left").foregroundStyle(t.isResolved ? Color.secondary : Color.orange)
                Text(verbatim: "\(t.side == "LEFT" ? "old" : "new") line \(t.anchorLine ?? 0)\(t.isOutdated ? " · outdated" : "")").font(.caption2).foregroundStyle(.secondary)
                Spacer()
                if busy == t.id { ProgressView().controlSize(.mini) }
                Button(t.isResolved ? "Unresolve" : "Resolve") { act(t.id) { try await ws.github.setResolved(threadId: t.id, !t.isResolved) } }
                    .controlSize(.mini)
                Button {
                    if let line = t.anchorLine {
                        ws.setReviewSide(t.side == "LEFT" ? .before : .after)
                        Task { @MainActor in
                            try? await Task.sleep(nanoseconds: 200_000_000)
                            ws.selection = SourceRange(line: line - 1)
                            ws.revealRequest += 1
                        }
                    }
                } label: { Image(systemName: "arrow.right.circle") }.buttonStyle(.borderless).help("Show line")
            }
            ForEach(t.comments) { c in
                VStack(alignment: .leading, spacing: 1) {
                    Text(c.author).font(.caption.weight(.semibold))
                    Text(LocalizedStringKey(c.body)).font(.caption).textSelection(.enabled)
                }
            }
            if !t.isResolved, let first = t.comments.first {
                HStack {
                    TextField("Reply", text: Binding(get: { replyDrafts[t.id] ?? "" }, set: { replyDrafts[t.id] = $0 }), axis: .vertical)
                        .textFieldStyle(.roundedBorder).font(.caption).lineLimit(1...4)
                    Button("Reply") {
                        let body = replyDrafts[t.id] ?? ""
                        guard !body.isEmpty, let pr = review.pullRequest else { return }
                        act(t.id) { try await ws.github.reply(number: pr.number, to: first.id, body: body); replyDrafts[t.id] = "" }
                    }
                    .controlSize(.small)
                    .disabled((replyDrafts[t.id] ?? "").isEmpty)
                }
            }
        }
        .padding(6)
        .background(Color.orange.opacity(t.isResolved ? 0.03 : 0.07), in: RoundedRectangle(cornerRadius: 6))
        .opacity(t.isResolved ? 0.7 : 1)
    }

    private func act(_ id: String, _ work: @escaping () async throws -> Void) {
        busy = id
        Task {
            do { try await work(); error = nil } catch { self.error = error.localizedDescription }
            await review.refreshPullRequest()
            busy = nil
        }
    }
}

/// Composes one review comment on a line.
struct CommentSheet: View {
    @Bindable var ws: Workspace
    @State var draft: PendingComment
    @Environment(\.dismiss) private var dismiss

    var body: some View {
        let commentable = ws.review?.isCommentable(path: draft.path, line: draft.line, side: draft.side) ?? false
        VStack(alignment: .leading, spacing: 10) {
            Text("Review comment").font(.headline)
            Text(verbatim: "\(draft.path):\(draft.line) · \(draft.side == "LEFT" ? "old version" : "new version")")
                .font(.caption.monospaced()).foregroundStyle(.secondary)
            if !commentable {
                Label("This line is outside the diff; GitHub only accepts comments on changed hunks and their context.", systemImage: "exclamationmark.triangle")
                    .font(.caption).foregroundStyle(.orange)
            }
            TextEditor(text: $draft.body).font(.body).frame(minHeight: 120)
                .overlay(RoundedRectangle(cornerRadius: 4).strokeBorder(Color.secondary.opacity(0.3)))
            Text("Comments are kept locally and posted together when you submit the review.").font(.caption).foregroundStyle(.secondary)
            HStack {
                Spacer()
                Button("Cancel") { ws.commentDraft = nil; dismiss() }.keyboardShortcut(.cancelAction)
                Button("Add to Review") {
                    ws.review?.addPending(draft)
                    ws.commentDraft = nil
                    dismiss()
                }
                .keyboardShortcut(.return, modifiers: .command)
                .disabled(draft.body.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
            }
        }
        .padding(16)
        .frame(width: 520)
    }
}

/// Final step: choose the verdict, write the summary, confirm, post.
struct SubmitReviewSheet: View {
    @Bindable var ws: Workspace
    @Bindable var review: ReviewSession
    @Environment(\.dismiss) private var dismiss
    @State private var event: GitHubService.ReviewEvent = .comment
    @State private var body_ = ""
    @State private var confirming = false
    @State private var posting = false
    @State private var error: String?

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            Text("Submit review").font(.headline)
            if let pr = review.pullRequest {
                Text(verbatim: "#\(pr.number) \(pr.title)").font(.callout).lineLimit(2)
                Text(verbatim: "Posting as \(ws.github.login ?? "your gh account") at \(String(pr.headSha.prefix(10)))").font(.caption).foregroundStyle(.secondary)
            }
            Picker("", selection: $event) {
                ForEach(GitHubService.ReviewEvent.allCases) { Text($0.label).tag($0) }
            }.pickerStyle(.segmented).labelsHidden()
            TextEditor(text: $body_).frame(minHeight: 90)
                .overlay(RoundedRectangle(cornerRadius: 4).strokeBorder(Color.secondary.opacity(0.3)))
            Text(verbatim: "\(review.pendingComments.count) line comments").font(.caption.weight(.semibold))
            ScrollView {
                VStack(alignment: .leading, spacing: 6) {
                    ForEach(review.pendingComments) { c in
                        HStack(alignment: .top) {
                            VStack(alignment: .leading, spacing: 1) {
                                Text(verbatim: "\(c.path):\(c.line) \(c.side == "LEFT" ? "(old)" : "")").font(.caption.monospaced()).foregroundStyle(.secondary)
                                Text(c.body).font(.caption)
                            }
                            Spacer()
                            Button { review.removePending(c.id) } label: { Image(systemName: "trash") }.buttonStyle(.borderless)
                        }
                    }
                }
            }.frame(maxHeight: 180)
            if let e = error { Text(e).font(.caption).foregroundStyle(.red).textSelection(.enabled) }
            HStack {
                Spacer()
                Button("Cancel") { dismiss() }.keyboardShortcut(.cancelAction)
                Button(posting ? "Posting…" : "Submit…") { confirming = true }
                    .disabled(posting || (event == .comment && body_.isEmpty && review.pendingComments.isEmpty))
            }
        }
        .padding(16)
        .frame(width: 560)
        .confirmationDialog("Post this review to GitHub?", isPresented: $confirming) {
            Button("Post \(event.label)") { post() }
            Button("Cancel", role: .cancel) {}
        } message: {
            Text(verbatim: "\(event.label) with \(review.pendingComments.count) line comments will be visible on the pull request.")
        }
    }

    private func post() {
        posting = true
        Task {
            do {
                try await review.submit(event: event, body: body_)
                dismiss()
            } catch {
                self.error = error.localizedDescription
            }
            posting = false
        }
    }
}

/// The review you are building: drafted comments as jump links, the verdict, and Submit.
struct PendingReviewBar: View {
    @Bindable var ws: Workspace
    @Bindable var review: ReviewSession
    @State private var event: GitHubService.ReviewEvent = .comment
    @State private var summary = ""
    @State private var confirming = false
    @State private var posting = false
    @State private var error: String?

    var body: some View {
        HStack(spacing: 8) {
            Text("Pending review").font(.callout.weight(.semibold))
            Text(verbatim: review.pendingComments.count == 1 ? "1 comment" : "\(review.pendingComments.count) comments").font(.caption).foregroundStyle(.secondary)
            ScrollView(.horizontal, showsIndicators: false) {
                HStack(spacing: 4) {
                    ForEach(review.pendingComments) { c in
                        Button(c.path.lastPathComponent + ":" + String(c.line)) { ws.jump(to: c) }
                            .buttonStyle(.bordered).controlSize(.small).font(.caption.monospaced())
                    }
                }
            }
            Picker("", selection: $event) {
                ForEach(GitHubService.ReviewEvent.allCases) { Text($0.label).tag($0) }
            }
            .pickerStyle(.segmented).labelsHidden().frame(width: 290)
            if posting { ProgressView().controlSize(.small) }
            Button { confirming = true } label: { HStack(spacing: 4) { Text("Submit review…"); KeyCap("⇧⌘↩") } }
                .buttonStyle(.borderedProminent).controlSize(.small)
                .keyboardShortcut(.return, modifiers: [.command, .shift])
                .disabled(posting || (event == .comment && review.pendingComments.isEmpty))
        }
        .padding(.horizontal, 12).frame(height: 38)
        .background(Color.blue.opacity(0.06))
        .onChange(of: ws.showSubmitReview) { if ws.showSubmitReview { confirming = true; ws.showSubmitReview = false } }
        .popover(isPresented: $confirming, arrowEdge: .top) {
            VStack(alignment: .leading, spacing: 8) {
                Text(verbatim: "\(event.label) on #\(review.pullRequest?.number ?? 0)").font(.headline)
                Text(verbatim: "Posts \(review.pendingComments.count) line comments as \(ws.github.login ?? "your gh account"). Everyone on the pull request will see it.")
                    .font(.caption).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
                TextField("Summary (optional)", text: $summary, axis: .vertical).textFieldStyle(.roundedBorder).lineLimit(2...6)
                if let error { Text(error).font(.caption).foregroundStyle(.red).textSelection(.enabled) }
                HStack {
                    Spacer()
                    Button("Cancel") { confirming = false }
                    Button("Post \(event.label)") { submit() }.buttonStyle(.borderedProminent)
                        .disabled(event == .comment && summary.isEmpty && review.pendingComments.isEmpty)
                }
            }
            .padding(14).frame(width: 380)
        }
    }

    private func submit() {
        posting = true
        Task {
            do {
                try await review.submit(event: event, body: summary)
                summary = ""
                confirming = false
                ws.statusMessage = "Review posted"
            } catch {
                self.error = error.localizedDescription
            }
            posting = false
        }
    }
}
