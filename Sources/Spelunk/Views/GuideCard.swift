import SwiftUI

/// The Getting Started guide, as a card over the bottom corner of the editor.
struct GuideCard: View {
    @Bindable var ws: Workspace
    @Bindable var guide = Guide.shared
    @State private var showList = false

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            header
            if guide.collapsed {
                progress.padding(.horizontal, 12).padding(.bottom, 10)
            } else {
                Divider()
                VStack(alignment: .leading, spacing: 10) {
                    if let done = guide.justDone {
                        Label("Done: \(done)", systemImage: "checkmark.circle.fill")
                            .font(.callout.weight(.medium)).foregroundStyle(.green)
                            .transition(.opacity)
                    }
                    if let s = guide.focus { stepBody(s) } else { finishedBody }
                    if showList { stepList }
                }
                .padding(12)
                .animation(.easeOut(duration: 0.2), value: guide.justDone)
            }
        }
        .frame(width: 340)
        .background(.regularMaterial, in: RoundedRectangle(cornerRadius: 12))
        .overlay(RoundedRectangle(cornerRadius: 12).strokeBorder(Color.secondary.opacity(0.25)))
        .shadow(color: .black.opacity(0.18), radius: 14, y: 6)
    }

    private var header: some View {
        HStack(spacing: 8) {
            Image(systemName: "flashlight.on.fill").foregroundStyle(.orange)
            Text("Getting Started").font(.headline)
            Spacer()
            Text("\(guide.doneCount) of \(Guide.steps.count)").font(.caption).monospacedDigit().foregroundStyle(.secondary)
            Button { withAnimation(.easeOut(duration: 0.15)) { guide.collapsed.toggle() } } label: {
                Image(systemName: guide.collapsed ? "chevron.up" : "chevron.down")
            }
            .buttonStyle(.borderless).help(guide.collapsed ? "Expand" : "Collapse")
            Button { guide.close() } label: { Image(systemName: "xmark") }
                .buttonStyle(.borderless).help("Close the guide. Help › Getting Started opens it again.")
        }
        .padding(.horizontal, 12).padding(.vertical, 9)
        .contentShape(Rectangle())
        .onTapGesture { if guide.collapsed { withAnimation(.easeOut(duration: 0.15)) { guide.collapsed = false } } }
    }

    private var progress: some View {
        HStack(spacing: 3) {
            ForEach(Guide.steps) { s in
                Capsule().fill(guide.isDone(s) ? Color.green : s.id == guide.focus?.id ? Color.orange : Color.secondary.opacity(0.25))
                    .frame(height: 3)
            }
        }
    }

    @ViewBuilder private func stepBody(_ s: Guide.Step) -> some View {
        progress
        Text(s.title).font(.title3.weight(.semibold))
        Text(s.detail).font(.callout).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
        if !s.keys.isEmpty {
            HStack(spacing: 6) { ForEach(s.keys, id: \.self) { KeyCapLarge($0) } }
        }
        HStack(spacing: 10) {
            Button(showList ? "Hide Steps" : "All Steps") { withAnimation(.easeOut(duration: 0.15)) { showList.toggle() } }
                .buttonStyle(.borderless).font(.caption)
            if !guide.isDone(s) {
                Button("Skip") { guide.skip(s) }.buttonStyle(.borderless).font(.caption)
            }
            Spacer()
            if let m = s.showMe {
                Button(m.label) { m.run(ws) }
                    .controlSize(.small).buttonStyle(.borderedProminent)
                    .disabled(!m.available(ws))
            }
        }
    }

    @ViewBuilder private var finishedBody: some View {
        progress
        Text("You're set").font(.title3.weight(.semibold))
        Text("Every command is in the palette (⇧⌘K), with its shortcut. Help › Getting Started opens this guide again.")
            .font(.callout).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
        HStack {
            Button(showList ? "Hide Steps" : "All Steps") { withAnimation(.easeOut(duration: 0.15)) { showList.toggle() } }
                .buttonStyle(.borderless).font(.caption)
            Spacer()
            Button("Close") { guide.close() }.controlSize(.small).buttonStyle(.borderedProminent)
        }
    }

    private var stepList: some View {
        VStack(alignment: .leading, spacing: 2) {
            Divider().padding(.bottom, 4)
            ForEach(Guide.steps) { s in
                Button { guide.picked = s.id } label: {
                    HStack(spacing: 8) {
                        Image(systemName: guide.isDone(s) ? "checkmark.circle.fill" : "circle")
                            .foregroundStyle(guide.isDone(s) ? Color.green : Color.secondary)
                        Text(s.title).foregroundStyle(guide.isDone(s) ? .secondary : .primary)
                        Spacer()
                    }
                    .padding(.vertical, 3).padding(.horizontal, 6)
                    .background(s.id == guide.focus?.id ? Color.accentColor.opacity(0.15) : .clear, in: RoundedRectangle(cornerRadius: 5))
                    .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
            }
        }
        .font(.callout)
    }
}

/// A keyboard-key glyph sized for body text.
private struct KeyCapLarge: View {
    let key: String
    init(_ key: String) { self.key = key }
    var body: some View {
        Text(key).font(.system(size: 12, weight: .medium, design: .rounded))
            .padding(.horizontal, 6).padding(.vertical, 2)
            .background(Color.secondary.opacity(0.16), in: RoundedRectangle(cornerRadius: 4))
            .overlay(RoundedRectangle(cornerRadius: 4).strokeBorder(Color.secondary.opacity(0.25)))
    }
}
