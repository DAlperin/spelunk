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
        let ids: Set<Int>
        if let s = folds[key] {
            ids = s
        } else {
            ids = defaultFolds(d, regions)
            folds[key] = ids
        }
        // Nested functions inside a folded one are already hidden.
        var out: [ClosedRange<Int>] = []
        for r in regions.filter({ ids.contains($0.id) }).sorted(by: { $0.hidden.lowerBound < $1.hidden.lowerBound }) {
            if let last = out.last, last.contains(r.hidden.lowerBound) { continue }
            out.append(r.hidden)
        }
        return out
    }

    func foldKey(_ d: SourceDocument) -> String { "\(d.path)|\(d.version)" }

    nonisolated static func foldRegions(_ d: SourceDocument) -> [FoldRegion] {
        d.syntax.flatOutline.compactMap { i in
            guard i.kind == .function || i.kind == .method else { return nil }
            let lo = i.headerEndLine + 1, hi = i.range.end.line - 1
            // A fold hides at least two lines; one line is no shorter than its placeholder.
            guard hi - lo >= 1 else { return nil }
            return FoldRegion(item: i.range.start.line...i.range.end.line, hidden: lo...hi)
        }
    }

    private func defaultFolds(_ d: SourceDocument, _ regions: [FoldRegion]) -> Set<Int> {
        let mode = FoldMode(rawValue: Prefs.foldMode) ?? .review
        let inReview = review?.files.contains { $0.newPath == d.path || $0.oldPath == d.path } ?? false
        guard mode == .all || (mode == .review && inReview) else { return [] }
        // Lines that must stay visible: changes, removed lines shown inline, comments, and the arrival point.
        var keep = Set<Int>()
        if inReview {
            keep.formUnion(diffMarkers(for: d).keys)
            keep.formUnion(phantomLines(for: d).keys)
            keep.formUnion(commentLines(for: d).keys)
        }
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
