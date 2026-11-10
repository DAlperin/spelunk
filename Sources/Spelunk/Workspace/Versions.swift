import Foundation

/// Which text of a file the editor shows, for the version chip in the breadcrumb.
struct VersionInfo {
    enum Kind { case workingCopy, after, before, other }
    var kind: Kind
    var title: String
    /// Set when the active review has its own version of this file and the editor is not showing it.
    var notReviewed: String?
    var help: String
    var alternatives: [Alternative] = []

    struct Alternative: Identifiable {
        var id: String { label }
        var label: String
        var open: @MainActor () -> Void
    }
}

extension Workspace {
    /// The review whose Before or After `doc` is: the active one first, then the others open.
    func owningReview(of doc: SourceDocument) -> ReviewSession? {
        guard !doc.isWorkingCopy else { return nil }
        let all = [review].compactMap { $0 } + [workingReview].compactMap { $0 } + pinnedReviews
        return all.first { doc.version == (doc.side == .old ? $0.baseVersion : $0.headVersion) }
    }

    var versionInfo: VersionInfo? {
        guard let doc = document else { return nil }
        let line = cursor?.line ?? 0
        let path = doc.path
        func showSide(_ r: ReviewSession, _ side: ReviewSession.Side, _ path: String) {
            let gen = beginNavigation(.manual)
            Task {
                guard let d = await r.document(path, side: side) else { statusMessage = "\(path) is not in \(r.shortLabel)"; return }
                show(d, line: line, generation: gen)
            }
        }
        func openWorkingCopy(_ path: String) {
            open(CodeLocation(path: path, range: SourceRange(line: line)), reason: .manual)
        }

        if doc.isWorkingCopy {
            var info = VersionInfo(kind: .workingCopy, title: "Working copy", help: "The file as it is on disk.")
            // A fixed review shows its own After; the working copy may differ from it.
            if let r = review, !r.afterIsWorkingCopy, let f = r.files.first(where: { $0.newPath == path || $0.oldPath == path }) {
                info.notReviewed = "not \(r.shortLabel)'s version"
                info.help = "The file as it is on disk, not as \(r.shortLabel) has it. Its hunks are not shown here."
                if f.status != .deleted { info.alternatives.append(.init(label: "After · \(r.shortLabel)") { showSide(r, .new, f.newPath) }) }
                if f.status != .added { info.alternatives.append(.init(label: "Before · \(r.shortLabel)") { showSide(r, .old, f.oldPath) }) }
            } else if let r = review, r.afterIsWorkingCopy, let f = r.files.first(where: { $0.newPath == path }), f.status != .added {
                info.alternatives.append(.init(label: "Before · \(r.shortLabel)") { showSide(r, .old, f.oldPath) })
            }
            return info
        }

        let commit: String = if case .revision(let c) = doc.version { String(c.prefix(8)) } else { "" }
        guard let r = owningReview(of: doc) else {
            return VersionInfo(kind: .other, title: "Revision \(commit)", help: "The file at commit \(commit).",
                               alternatives: [.init(label: "Working copy") { openWorkingCopy(path) }])
        }
        let isBefore = doc.side == .old
        let name = r.tracksWorkingCopy ? "working copy changes" : r.shortLabel
        var info = VersionInfo(kind: isBefore ? .before : .after,
                               title: (isBefore ? "Before · " : "After · ") + name + (commit.isEmpty ? "" : " \(commit)"),
                               help: isBefore ? "The file before \(name), at commit \(commit)." : "The file as \(name) has it, at commit \(commit).")
        if r !== review { info.help += " That review is open but not the one shown in the toolbar." }
        let f = r.files.first { (isBefore ? $0.oldPath : $0.newPath) == path }
        if isBefore, let f, f.status != .deleted {
            info.alternatives.append(.init(label: r.afterIsWorkingCopy ? "After · working copy" : "After · \(name)") { showSide(r, .new, f.newPath) })
        } else if !isBefore, let f, f.status != .added {
            info.alternatives.append(.init(label: "Before · \(name)") { showSide(r, .old, f.oldPath) })
        }
        let livePath = isBefore ? (f?.newPath ?? path) : path
        if FileManager.default.fileExists(atPath: root.appendingPathComponent(livePath).path) {
            info.alternatives.append(.init(label: "Working copy") { openWorkingCopy(livePath) })
        }
        return info
    }
}
