import Foundation

extension Workspace {
    /// Wires a review's semantic rule conditions to this workspace's code intelligence.
    func attachSemantics(_ r: ReviewSession) {
        r.semanticProvider = { [weak self] h, f, needs in
            await self?.semanticFacts(for: h, file: f, needs: needs) ?? .unavailable
        }
    }

    /// Answers about the item a hunk changes, asked at that item's position in the file on disk:
    /// rust-analyzer when warm, otherwise SCIP, tree-sitter or text search, as `IntelHub` falls back.
    func semanticFacts(for h: Hunk, file f: FileDiff, needs: SemanticNeeds) async -> SemanticFacts {
        guard f.status != .deleted, SourceLanguage.from(path: f.newPath) == .rust, let disk = docs.document(f.newPath) else { return .unavailable }
        let reviewDoc = review?.cachedDocument(f.newPath, side: .new) ?? disk
        guard reviewDoc.lines.lineCount > 0,
              let item = reviewDoc.syntax.enclosingItem(line: min(h.anchorNewLine, reviewDoc.lines.lineCount - 1)) else { return .unavailable }
        // The review's version can differ from the working copy; find the same item on disk by name.
        let target = reviewDoc === disk ? item : disk.syntax.flatOutline.first { $0.qualifiedName == item.qualifiedName && $0.kind == item.kind }
        var s = SemanticFacts(item: item.qualifiedName)
        guard let target else {
            if needs.callers {
                let callers = await intel.callersByName(item.name)
                s.callers = callers.map { .init(name: $0.name, path: $0.location.path) }
                s.transitiveCallers = callers.map(\.name)
                s.source = .textSearch
            }
            return s
        }
        let path = f.newPath, pos = target.nameRange.start, name = target.name
        if needs.refs {
            let (hits, src) = await intel.references(path: path, at: pos, name: name)
            s.refs = hits.filter { !$0.isDefinition }.count
            s.source = src
        }
        if needs.callers {
            let roots = await intel.callRoots(.incoming, path: path, at: pos, name: name)
            s.callers = roots.map { .init(name: $0.name, path: $0.location.path) }
            s.source = roots.first?.source ?? s.source
            var names = roots.map(\.name)
            var frontier = roots
            if needs.depth > 1 {
                for _ in 2...needs.depth {
                    var next: [CallNode] = []
                    for n in frontier.prefix(25) {
                        await intel.expand(n, .incoming)
                        next += n.children ?? []
                    }
                    names += next.map(\.name)
                    frontier = next
                    if frontier.isEmpty || names.count > 300 { break }
                }
            }
            s.transitiveCallers = names
        }
        if needs.callees {
            let roots = await intel.callRoots(.outgoing, path: path, at: pos, name: name)
            s.callees = roots.map { $0.detail.isEmpty ? $0.name : $0.name + " " + $0.detail }
        }
        if needs.signature {
            s.signature = await intel.details(path: path, at: pos, name: name).signature
        }
        return s
    }
}
