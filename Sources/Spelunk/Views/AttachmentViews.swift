import AppKit
import SwiftUI

/// Attachments that rules produced for the selected hunk.
struct AttachmentsSection: View {
    @Bindable var ws: Workspace
    @Bindable var review: ReviewSession
    let hunk: Hunk

    var body: some View {
        let list = review.attachments(for: hunk)
        if !list.isEmpty {
            PaneSectionHeader(title: "Attachments", trailing: String(list.count))
            ForEach(list) { a in AttachmentCard(ws: ws, review: review, hunk: hunk, attachment: a) }
        }
    }
}

struct AttachmentCard: View {
    @Bindable var ws: Workspace
    @Bindable var review: ReviewSession
    let hunk: Hunk
    let attachment: Attachment
    @State private var expanded = true

    var body: some View {
        let result = review.attachmentResults[attachment.key]
        let running = review.attachmentsRunning.contains(attachment.key)
        VStack(alignment: .leading, spacing: 6) {
            HStack(spacing: 6) {
                Image(systemName: attachment.isClaude ? "sparkles" : "paperclip").font(.caption).foregroundStyle(attachment.isClaude ? .purple : .secondary)
                Text(attachment.rule.title).font(.callout.weight(.semibold)).lineLimit(1)
                    .onTapGesture { expanded.toggle() }
                Spacer(minLength: 4)
                if running {
                    ProgressView().controlSize(.mini)
                    Button { review.cancelAttachment(attachment) } label: { Image(systemName: "stop.circle") }.help("Cancel")
                } else if result != nil {
                    Menu {
                        Button("Regenerate") { review.runAttachment(attachment) }
                        if let f = result?.files.first {
                            Button("Show in Finder") { NSWorkspace.shared.activateFileViewerSelecting([URL(fileURLWithPath: f)]) }
                        }
                        Text(verbatim: "\(attachment.rule.source):\(attachment.rule.line)")
                    } label: { Image(systemName: "ellipsis") }
                    .menuStyle(.borderlessButton).menuIndicator(.hidden).fixedSize()
                }
            }
            .buttonStyle(.borderless)
            Text(verbatim: subtitle(result)).font(.caption2).foregroundStyle(.tertiary).lineLimit(1).truncationMode(.middle)
            if expanded {
                if let result {
                    content(result)
                } else if !running {
                    Button(attachment.isClaude ? "Generate with \(ClaudeModels.label(attachment.rule.model ?? Claude.model(for: .attach)))" : "Run") {
                        review.runAttachment(attachment)
                    }
                    .controlSize(.small)
                }
            }
        }
        .padding(8)
        .background(Color.secondary.opacity(0.06), in: RoundedRectangle(cornerRadius: 6))
        .padding(.bottom, 4)
    }

    func subtitle(_ r: AttachmentResult?) -> String {
        var parts = [attachment.label]
        switch attachment.rule.action {
        case .run(let c): parts.append(c)
        case .claude: parts.append(ClaudeModels.label(attachment.rule.model ?? Claude.model(for: .attach)))
        case nil: break
        }
        if let r { parts.append(String(format: "%.0fs", r.seconds) + (r.cost > 0 ? String(format: " · $%.3f", r.cost) : "")) }
        return parts.joined(separator: " · ")
    }

    @ViewBuilder func content(_ r: AttachmentResult) -> some View {
        if let e = r.error { Text(e).font(.caption).foregroundStyle(.red) }
        ForEach(r.files, id: \.self) { f in AttachmentFileView(path: f) }
        if let p = r.payload { PayloadView(ws: ws, review: review, hunk: hunk, payload: p) }
        if let m = r.markdown, !m.isEmpty { CitedText(text: m) { ws.openCitation($0) } }
        if let o = r.output, !o.isEmpty {
            ScrollView {
                Text(o).font(.system(size: 11, design: .monospaced)).textSelection(.enabled)
                    .frame(maxWidth: .infinity, alignment: .leading)
            }
            .frame(maxHeight: 220)
        }
    }
}

/// One file a command wrote: images and PDFs inline, text inline, anything else opens externally.
struct AttachmentFileView: View {
    let path: String
    var body: some View {
        let ext = (path as NSString).pathExtension.lowercased()
        let url = URL(fileURLWithPath: path)
        if ["png", "jpg", "jpeg", "gif", "tiff", "svg", "pdf", "heic", "webp"].contains(ext), let img = NSImage(contentsOf: url) {
            Image(nsImage: img).resizable().aspectRatio(contentMode: .fit)
                .frame(maxWidth: .infinity, maxHeight: 360)
                .background(Color.white.opacity(ext == "svg" || ext == "pdf" ? 1 : 0), in: RoundedRectangle(cornerRadius: 4))
                .onTapGesture(count: 2) { NSWorkspace.shared.open(url) }
                .help("\(url.lastPathComponent) (double-click to open)")
        } else if ["md", "txt", "csv", "log", "json"].contains(ext), let text = try? String(contentsOf: url, encoding: .utf8) {
            if ext == "md" { CitedText(text: String(text.prefix(20_000))) { _ in } }
            else {
                ScrollView { Text(String(text.prefix(20_000))).font(.system(size: 11, design: .monospaced)).textSelection(.enabled).frame(maxWidth: .infinity, alignment: .leading) }
                    .frame(maxHeight: 220)
            }
        } else {
            Button { NSWorkspace.shared.open(url) } label: { Label(url.lastPathComponent, systemImage: "arrow.up.forward.square") }
                .buttonStyle(.link).font(.caption)
        }
    }
}

/// A structured attachment: summary, findings that open their location, copyable examples, and
/// actions. A comment action only fills the draft composer; nothing is posted from here.
struct PayloadView: View {
    @Bindable var ws: Workspace
    let review: ReviewSession
    let hunk: Hunk
    let payload: AttachmentPayload

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            if let s = payload.summary, !s.isEmpty { CitedText(text: s) { ws.openCitation($0) } }
            ForEach(Array((payload.findings ?? []).enumerated()), id: \.offset) { _, f in finding(f) }
            ForEach(Array((payload.examples ?? []).enumerated()), id: \.offset) { _, e in example(e) }
            let actions = payload.actions ?? []
            if !actions.isEmpty {
                FlowButtons(actions: actions) { perform($0) }
            }
        }
    }

    func finding(_ f: AttachmentPayload.Finding) -> some View {
        let color: Color = f.severity == "risk" ? .red : f.severity == "warn" ? .orange : .secondary
        return Button {
            if let p = f.path { ws.openCitation(p + ":" + String(f.line ?? 1)) }
        } label: {
            HStack(alignment: .firstTextBaseline, spacing: 6) {
                Circle().fill(color).frame(width: 6, height: 6)
                VStack(alignment: .leading, spacing: 1) {
                    Text(f.title).font(.caption.weight(.medium)).foregroundStyle(.primary)
                    if let d = f.detail, !d.isEmpty { Text(d).font(.caption).foregroundStyle(.secondary) }
                }
                Spacer(minLength: 4)
                if let p = f.path {
                    Text(verbatim: (p as NSString).lastPathComponent + (f.line.map { ":\($0)" } ?? ""))
                        .font(.caption2.monospaced()).foregroundStyle(.tertiary).lineLimit(1)
                }
            }
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .disabled(f.path == nil)
    }

    func example(_ e: AttachmentPayload.Example) -> some View {
        VStack(alignment: .leading, spacing: 3) {
            HStack {
                Text(e.title).font(.caption.weight(.semibold))
                if let l = e.language { Text(l).font(.caption2).foregroundStyle(.tertiary) }
                Spacer()
                Button("Copy") {
                    NSPasteboard.general.clearContents()
                    NSPasteboard.general.setString(e.code, forType: .string)
                }
                .buttonStyle(.link).font(.caption)
            }
            ScrollView(.horizontal) {
                Text(e.code).font(.system(size: 11, design: .monospaced)).textSelection(.enabled).padding(6)
            }
            .background(Color.black.opacity(0.18), in: RoundedRectangle(cornerRadius: 4))
        }
    }

    func perform(_ a: AttachmentPayload.Action) {
        switch a.kind {
        case "comment":
            let line = (hunk.lines.last { $0.newLine != nil && $0.kind == .added }?.newLine ?? hunk.anchorNewLine) + 1
            ws.commentDraft = PendingComment(path: hunk.path, line: line, side: "RIGHT", body: a.text ?? a.label)
        case "ask": ws.ask(a.text ?? a.label, includeAnchor: true); ws.openAsk()
        case "trace": ws.generateTrace(a.text ?? a.label, includeAnchor: true)
        case "open": if let p = a.path { ws.openCitation(p + ":" + String(a.line ?? 1)) }
        default: break
        }
    }
}

struct FlowButtons: View {
    let actions: [AttachmentPayload.Action]
    let perform: (AttachmentPayload.Action) -> Void
    var body: some View {
        VStack(alignment: .leading, spacing: 4) {
            ForEach(Array(actions.enumerated()), id: \.offset) { _, a in
                Button { perform(a) } label: {
                    Label(a.label, systemImage: icon(a.kind)).lineLimit(2).multilineTextAlignment(.leading)
                }
                .buttonStyle(.bordered).controlSize(.small)
                .help(a.text ?? a.label)
            }
        }
    }
    func icon(_ k: String) -> String {
        switch k {
        case "comment": "text.bubble"
        case "ask": "sparkles"
        case "trace": "point.topleft.down.to.point.bottomright.curvepath"
        default: "arrow.up.forward.square"
        }
    }
}
