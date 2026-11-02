import Foundation

/// How one code-path step reaches the next.
struct StepConnector: Hashable {
    enum Kind: Hashable { case calls, calledBy, inferred }
    var kind: Kind
    /// The call site, when one was found.
    var site: CodeLocation?
}

extension Workspace {
    /// Looks for a call to the next step's function inside the current step's function body (or the
    /// reverse, for paths written callee-first). Anything else is an inferred hop: a channel, a trait
    /// object, an async boundary, or a step whose location could not be matched.
    func connector(from a: TraceStep, to b: TraceStep) -> StepConnector {
        if let site = callSite(in: a, calling: b) { return StepConnector(kind: .calls, site: site) }
        if let site = callSite(in: b, calling: a) { return StepConnector(kind: .calledBy, site: site) }
        return StepConnector(kind: .inferred, site: nil)
    }

    private func callSite(in caller: TraceStep, calling callee: TraceStep) -> CodeLocation? {
        guard let doc = docs.document(caller.location.path),
              let item = doc.syntax.enclosingItem(line: caller.location.line), item.kind == .function || item.kind == .method else { return nil }
        let name = callee.title.split(separator: ":").last.map(String.init) ?? callee.title
        guard !name.isEmpty, let re = try? NSRegularExpression(pattern: "\\b" + NSRegularExpression.escapedPattern(for: name) + "\\s*(::<[^>]*>)?\\(") else { return nil }
        let start = doc.lines.offset(of: SourcePos(line: item.headerEndLine, col: 0))
        let end = doc.lines.offset(of: item.range.end)
        guard end > start else { return nil }
        guard let m = re.firstMatch(in: doc.text, range: NSRange(location: start, length: end - start)) else { return nil }
        let p = doc.lines.position(of: m.range.location)
        return CodeLocation(path: caller.location.path, range: SourceRange(start: p, end: SourcePos(line: p.line, col: p.col + name.utf16.count)))
    }

    /// Connectors for the active path, cached per path content.
    func activeConnectors() -> [StepConnector] {
        guard let t = traces.active, t.steps.count > 1 else { return [] }
        let key = t.steps.map { "\($0.location.id)|\($0.title)" }.joined(separator: ";")
        if let c = connectorCache, c.key == key { return c.value }
        let v = zip(t.steps, t.steps.dropFirst()).map { connector(from: $0, to: $1) }
        connectorCache = (key, v)
        return v
    }

    /// For the open file: step numbers at their lines, and call sites that lead to another step.
    func pathMarkers(for doc: SourceDocument) -> (badges: [Int: Int], pills: [Int: Int]) {
        guard doc.revisionLabel == nil, let t = traces.active else { return ([:], [:]) }
        var badges: [Int: Int] = [:], pills: [Int: Int] = [:]
        for (i, s) in t.steps.enumerated() where s.location.path == doc.path { badges[s.location.line] = i + 1 }
        for (i, c) in activeConnectors().enumerated() {
            guard let site = c.site, site.path == doc.path else { continue }
            let target = c.kind == .calls ? i + 2 : i + 1
            if badges[site.line] == nil || c.kind == .calls { pills[site.line] = target }
        }
        return (badges, pills)
    }
}
