import AppKit
import SwiftUI

/// Attachments that rules produced for the selected hunk.
struct AttachmentsSection: View {
    @Bindable var review: ReviewSession
    let hunk: Hunk
    let open: (String) -> Void

    var body: some View {
        let list = review.attachments(for: hunk)
        if !list.isEmpty {
            PaneSectionHeader(title: "Attachments", trailing: String(list.count))
            ForEach(list) { a in AttachmentCard(review: review, attachment: a, open: open) }
        }
    }
}

struct AttachmentCard: View {
    @Bindable var review: ReviewSession
    let attachment: Attachment
    let open: (String) -> Void
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
        if let m = r.markdown, !m.isEmpty { CitedText(text: m, open: open) }
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
