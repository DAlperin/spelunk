import Foundation

/// A function body that can be folded: the lines between its signature and its closing line.
struct FoldRegion: Hashable, Sendable {
    /// The item's whole extent; its first line identifies the fold within the document.
    var item: ClosedRange<Int>
    var hidden: ClosedRange<Int>
    var id: Int { item.lowerBound }
}

/// Which files start with function bodies folded.
enum FoldMode: String, CaseIterable, Identifiable, Sendable {
    case off
    /// Files in the review being shown: functions without changes or comments start folded.
    case review
    /// Every file: all function bodies start folded, except around where you arrive.
    case all
    var id: String { rawValue }
    var label: String {
        switch self {
        case .off: "Never"
        case .review: "Unchanged functions in review files"
        case .all: "All functions in every file"
        }
    }
}

extension Workspace {
    /// Folds in effect for a document; empty in split view, where the two sides scroll together.
    /// A document seen for the first time gets the default for its kind.
    func foldedRanges(for d: SourceDocument) -> [ClosedRange<Int>] {
        _ = foldsVersion
        guard !(documentInReview && diffMode == .split) else { return [] }
        let key = foldKey(d)
        let regions = Self.foldRegions(d)
        var ids: Set<Int>
        let changed = reviewedFile(d) != nil ? mustShow(d) : []
        if let s = folds[key] {
            ids = s
            // Lines changed since the folds were set (the file is being edited) come into view.
            let fresh = changed.subtracting(foldChanged[key] ?? [])
            if !fresh.isEmpty {
                ids.subtract(regions.filter { r in fresh.contains { r.hidden.contains($0) || $0 == r.hidden.upperBound + 1 } }.map(\.id))
                folds[key] = ids
            }
        } else {
            ids = defaultFolds(d, regions, changed: changed)
            folds[key] = ids
        }
        foldChanged[key] = changed
        // Nested functions inside a folded one are already hidden.
        var out: [ClosedRange<Int>] = []
        for r in regions.filter({ ids.contains($0.id) }).sorted(by: { $0.hidden.lowerBound < $1.hidden.lowerBound }) {
            if let last = out.last, last.contains(r.hidden.lowerBound) { continue }
            out.append(r.hidden)
        }
        return out
    }

    /// Folds are kept per document version, and separately in review mode, where unchanged code folds.
    func foldKey(_ d: SourceDocument) -> String { "\(d.path)|\(d.version)\(reviewedFile(d) != nil ? "|review" : "")" }

    nonisolated static func foldRegions(_ d: SourceDocument) -> [FoldRegion] {
        d.syntax.flatOutline.compactMap { i in
            guard i.kind == .function || i.kind == .method else { return nil }
            let lo = i.headerEndLine + 1, hi = i.range.end.line - 1
            // A fold hides at least two lines; one line is no shorter than its placeholder.
            guard hi - lo >= 1 else { return nil }
            return FoldRegion(item: i.range.start.line...i.range.end.line, hidden: lo...hi)
        }
    }

    /// Lines of a reviewed document that folds must leave visible: changes, removed lines shown
    /// inline, and comments.
    private func mustShow(_ d: SourceDocument) -> Set<Int> {
        Set(diffMarkers(for: d).keys).union(phantomLines(for: d).keys).union(commentLines(for: d).keys)
    }

    private func defaultFolds(_ d: SourceDocument, _ regions: [FoldRegion], changed: Set<Int>) -> Set<Int> {
        let mode = FoldMode(rawValue: Prefs.foldMode) ?? .review
        let inReview = reviewedFile(d) != nil
        guard mode == .all || (mode == .review && inReview) else { return [] }
        // The arrival point stays visible too.
        var keep = changed
        if let s = selection, document === d { keep.insert(s.start.line) }
        return Set(regions.filter { r in
            !keep.contains { r.hidden.contains($0) || $0 == r.hidden.upperBound + 1 }
        }.map(\.id))
    }

    /// The innermost foldable function containing a line.
    private func region(at line: Int, in d: SourceDocument) -> FoldRegion? {
        Self.foldRegions(d).filter { $0.item.contains(line) }.min { $0.item.count < $1.item.count }
    }

    private func changeFolds(_ d: SourceDocument, _ change: (inout Set<Int>) -> Void) {
        let key = foldKey(d)
        var s = folds[key] ?? Set(foldedRanges(for: d).compactMap { r in Self.foldRegions(d).first { $0.hidden == r }?.id })
        change(&s)
        folds[key] = s
        foldsVersion += 1
    }

    /// Folds or unfolds the function at the caret.
    func toggleFold() {
        guard let d = document, let line = cursor?.line, let r = region(at: line, in: d) else { return }
        let folded = folds[foldKey(d)]?.contains(r.id) ?? false
        changeFolds(d) { if folded { $0.remove(r.id) } else { $0.insert(r.id) } }
    }

    func setFold(_ folded: Bool) {
        guard let d = document, let line = cursor?.line, let r = region(at: line, in: d) else { return }
        changeFolds(d) { if folded { $0.insert(r.id) } else { $0.remove(r.id) } }
    }

    func foldAll(_ folded: Bool) {
        guard let d = document else { return }
        let all = Set(Self.foldRegions(d).map(\.id))
        changeFolds(d) { $0 = folded ? all : [] }
    }

    /// Unfolds every fold hiding a line, so a jump there shows it.
    func unfold(containing line: Int, in d: SourceDocument) {
        let key = foldKey(d)
        guard let s = folds[key] else { return }
        let hiding = Self.foldRegions(d).filter { s.contains($0.id) && $0.hidden.contains(line) }.map(\.id)
        guard !hiding.isEmpty else { return }
        folds[key] = s.subtracting(hiding)
        foldsVersion += 1
    }
}
