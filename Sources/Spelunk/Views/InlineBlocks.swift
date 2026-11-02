import AppKit
import SwiftUI

/// A view embedded in the editor under a line: a review thread, a pending comment, or the composer.
struct InlineBlockView: View {
    let ws: Workspace
    let id: String

    var body: some View {
        Group {
            if id == "draft" {
                InlineComposer(ws: ws)
            } else if id.hasPrefix("thread:"), let t = ws.review?.pullRequest?.threads.first(where: { "thread:" + $0.id == id }) {
                InlineThread(ws: ws, thread: t)
            } else if id.hasPrefix("pending:"), let c = ws.review?.pendingComments.first(where: { "pending:" + $0.id.uuidString == id }) {
                InlinePending(ws: ws, comment: c)
            } else {
                EmptyView()
            }
        }
        .frame(width: CodeView.Coordinator.blockWidth, alignment: .leading)
        .environment(\.colorScheme, .dark)
    }
}

struct Avatar: View {
    let login: String
    var color: Color = .orange
    var body: some View {
        Text(String(login.prefix(2)).uppercased()).font(.system(size: 9, weight: .bold))
            .frame(width: 22, height: 22)
            .background(Circle().fill(color.opacity(0.85)))
            .foregroundStyle(.black.opacity(0.8))
    }
}

struct BlockCard<Content: View>: View {
    var accent: Color
    @ViewBuilder var content: Content
    var body: some View {
        VStack(alignment: .leading, spacing: 6) { content }
            .padding(10)
            .frame(maxWidth: .infinity, alignment: .leading)
            .background(RoundedRectangle(cornerRadius: 8).fill(Color(nsColor: .windowBackgroundColor)))
            .overlay(RoundedRectangle(cornerRadius: 8).strokeBorder(accent.opacity(0.55), lineWidth: 1))
    }
}

struct InlineThread: View {
    let ws: Workspace
    let thread: GitHubService.ReviewThread
    @State private var reply = ""
    @State private var expanded = false
    @State private var busy = false
    @State private var error: String?

    var body: some View {
        if thread.isResolved && !expanded {
            Button { expanded = true } label: {
                HStack(spacing: 6) {
                    Image(systemName: "checkmark.bubble").foregroundStyle(.secondary)
                    Text(verbatim: "Resolved thread · \(thread.comments.first?.author ?? "") · \(thread.comments.count) comments").font(.caption)
                    Text("show").font(.caption).foregroundStyle(Color.accentColor)
                }
                .padding(.horizontal, 8).padding(.vertical, 4)
                .background(RoundedRectangle(cornerRadius: 6).fill(Color.secondary.opacity(0.1)))
            }
            .buttonStyle(.plain)
        } else {
            BlockCard(accent: thread.isResolved ? .secondary : .orange) {
                ForEach(thread.comments) { c in
                    HStack(alignment: .top, spacing: 8) {
                        Avatar(login: c.author)
                        VStack(alignment: .leading, spacing: 2) {
                            HStack(spacing: 6) {
                                Text(c.author).font(.callout.weight(.semibold))
                                Text(verbatim: Self.ago(c.createdAt) + " · line \(thread.anchorLine ?? 0)").font(.caption).foregroundStyle(.secondary)
                                if c.id == thread.comments.first?.id {
                                    Text(thread.isResolved ? "resolved" : thread.isOutdated ? "outdated" : "unresolved").font(.system(size: 9, weight: .semibold))
                                        .padding(.horizontal, 5).padding(.vertical, 1)
                                        .background((thread.isResolved ? Color.secondary : .orange).opacity(0.2), in: RoundedRectangle(cornerRadius: 3))
                                        .foregroundStyle(thread.isResolved ? Color.secondary : .orange)
                                }
                            }
                            Text(LocalizedStringKey(c.body)).font(.callout).textSelection(.enabled).fixedSize(horizontal: false, vertical: true)
                        }
                    }
                }
                HStack(spacing: 6) {
                    TextField("Reply…", text: $reply, axis: .vertical).textFieldStyle(.roundedBorder).lineLimit(1...4)
                        .onSubmit(send)
                    Button(thread.isResolved ? "Unresolve" : "Resolve") { act { try await ws.github.setResolved(threadId: thread.id, !thread.isResolved) } }
                    Button("Suggest change") { reply += Self.suggestion(ws: ws, thread: thread) }
                    if busy { ProgressView().controlSize(.mini) }
                }
                .controlSize(.small)
                if let error { Text(error).font(.caption).foregroundStyle(.red) }
            }
        }
    }

    private func send() {
        let body = reply.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !body.isEmpty, let pr = ws.review?.pullRequest, let first = thread.comments.first else { return }
        act { try await ws.github.reply(number: pr.number, to: first.id, body: body); reply = "" }
    }

    private func act(_ work: @escaping () async throws -> Void) {
        busy = true
        Task {
            do { try await work(); error = nil } catch { self.error = error.localizedDescription }
            await ws.review?.refreshPullRequest()
            busy = false
        }
    }

    static func suggestion(ws: Workspace, thread: GitHubService.ReviewThread) -> String {
        let line = (thread.anchorLine ?? 1) - 1
        let text = ws.document?.path == thread.path ? (ws.document?.lineText(line) ?? "") : ""
        return "\n```suggestion\n\(text)\n```\n"
    }

    static func ago(_ iso: String) -> String {
        guard let d = ISO8601DateFormatter().date(from: iso) else { return "" }
        let s = Int(Date().timeIntervalSince(d))
        if s < 3600 { return "\(max(1, s / 60))m" }
        if s < 86400 { return "\(s / 3600)h" }
        return "\(s / 86400)d"
    }
}

struct InlinePending: View {
    let ws: Workspace
    let comment: PendingComment
    var body: some View {
        BlockCard(accent: .blue) {
            HStack(alignment: .top, spacing: 8) {
                Avatar(login: ws.github.login ?? "you", color: .blue)
                VStack(alignment: .leading, spacing: 2) {
                    HStack(spacing: 6) {
                        Text("You").font(.callout.weight(.semibold))
                        Text(verbatim: "pending · line \(comment.line)").font(.caption).foregroundStyle(.secondary)
                        Spacer()
                        Button("Edit") {
                            ws.review?.removePending(comment.id)
                            ws.commentDraft = comment
                        }
                        Button("Delete", role: .destructive) { ws.review?.removePending(comment.id) }
                    }
                    .buttonStyle(.link).font(.caption)
                    Text(LocalizedStringKey(comment.body)).font(.callout).fixedSize(horizontal: false, vertical: true)
                }
            }
        }
    }
}

/// Writes a review comment in place; ⌘↩ adds it to the pending review, ⌥⌘↩ posts it now.
struct InlineComposer: View {
    let ws: Workspace
    @State private var text = ""
    @State private var posting = false
    @State private var error: String?
    @FocusState private var focused: Bool

    var body: some View {
        if let d = ws.commentDraft {
            BlockCard(accent: .accentColor) {
                HStack(spacing: 8) {
                    Avatar(login: ws.github.login ?? "you", color: .blue)
                    Text("You").font(.callout.weight(.semibold))
                    Text(verbatim: "draft · line \(d.line)").font(.caption).foregroundStyle(.secondary)
                    if !(ws.review?.isCommentable(path: d.path, line: d.line, side: d.side) ?? true) {
                        Label("outside the diff; GitHub will reject it", systemImage: "exclamationmark.triangle").font(.caption).foregroundStyle(.orange)
                    }
                }
                TextEditor(text: $text)
                    .font(.callout).scrollContentBackground(.hidden)
                    .frame(height: 64)
                    .padding(4)
                    .background(RoundedRectangle(cornerRadius: 6).strokeBorder(Color.accentColor, lineWidth: 1.5))
                    .focused($focused)
                    .onKeyPress(.escape) { ws.commentDraft = nil; return .handled }
                HStack(spacing: 6) {
                    Button("Suggest change") {
                        let line = ws.document?.lineText(d.line - 1) ?? ""
                        text += "\n```suggestion\n\(line)\n```\n"
                    }
                    Text("Markdown").font(.caption).foregroundStyle(.tertiary)
                    Spacer()
                    if let error { Text(error).font(.caption).foregroundStyle(.red).lineLimit(1) }
                    if posting { ProgressView().controlSize(.mini) }
                    Button("Cancel") { ws.commentDraft = nil }
                    Button { post(d) } label: { HStack(spacing: 4) { Text("Comment now"); KeyCap("⌥⌘↩") } }
                        .keyboardShortcut(.return, modifiers: [.command, .option])
                        .disabled(text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
                    Button { add(d) } label: { HStack(spacing: 4) { Text("Add to review"); KeyCap("⌘↩") } }
                        .buttonStyle(.borderedProminent)
                        .keyboardShortcut(.return, modifiers: .command)
                        .disabled(text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
                }
                .controlSize(.small)
            }
            .onAppear { text = d.body; focused = true }
        }
    }

    private func add(_ d: PendingComment) {
        var c = d
        c.body = text
        ws.review?.addPending(c)
        ws.commentDraft = nil
    }

    private func post(_ d: PendingComment) {
        guard let r = ws.review, let pr = r.pullRequest else { return }
        var c = d
        c.body = text
        posting = true
        Task {
            do {
                try await ws.github.postComment(number: pr.number, commitId: pr.headSha, comment: c)
                ws.commentDraft = nil
                await r.refreshPullRequest()
            } catch {
                self.error = error.localizedDescription
            }
            posting = false
        }
    }
}
