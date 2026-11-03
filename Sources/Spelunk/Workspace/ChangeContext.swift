import Foundation
import Observation

/// What the selected hunk touches: the function it changes and who calls it, functions whose calls it
/// adds or removes and their remaining callers, and the tests that reach it.
@MainActor @Observable
final class ChangeContext {
    struct CallChange: Identifiable {
        var name: String
        var added: Bool
        var callers: [CallNode]
        var id: String { (added ? "+" : "-") + name }
    }

    let hunkID: String
    var enclosing: String?
    var enclosingLocation: CodeLocation?
    var callers: [CallNode] = []
    var callChanges: [CallChange] = []
    var tests: [CallNode] = []
    var testMentions: [TextMatch] = []
    var loading = true
    var source: IntelSource?

    init(hunkID: String) { self.hunkID = hunkID }
}

extension Workspace {
    nonisolated static let callKeywords: Set<String> = ["if", "while", "for", "match", "return", "Some", "Ok", "Err", "None", "loop", "fn",
                                             "assert", "assert_eq", "println", "format", "vec", "write", "writeln", "matches"]

    /// Locations a review hunk covers in the working copy's version of the file, for "in this change".
    func isInReview(_ loc: CodeLocation) -> Bool {
        guard let r = review, let f = r.files.first(where: { $0.newPath == loc.path }) else { return false }
        // Hunk line numbers are in the review head; only locations in that text can be compared.
        guard (loc.version ?? .workingCopy) == r.headVersion else { return false }
        return f.hunks.contains { h in loc.line >= h.newStart - 1 && loc.line < h.newStart - 1 + max(1, h.newCount) }
    }

    func loadChangeContext(for h: Hunk) {
        guard let r = review, let f = r.file(for: h) else { changeContext = nil; return }
        let cc = ChangeContext(hunkID: h.id)
        changeContext = cc
        Task {
            // The changed function, found in the review's head (where the hunk's lines are), then asked
            // about at the same item in the working copy, which is what code intelligence answers for.
            let headDoc = r.afterIsWorkingCopy ? docs.document(f.newPath) : await r.document(f.newPath, side: .new)
            let wcDoc = docs.document(f.newPath)
            let anchor = h.anchorNewLine
            if let headDoc, headDoc.lines.lineCount > 0, let item = headDoc.syntax.enclosingItem(line: min(anchor, headDoc.lines.lineCount - 1)),
               item.kind == .function || item.kind == .method {
                cc.enclosing = item.qualifiedName
                cc.enclosingLocation = CodeLocation(path: f.newPath, range: item.nameRange, version: headDoc.isWorkingCopy ? nil : headDoc.version)
                let wcItem = headDoc === wcDoc ? item : wcDoc?.syntax.flatOutline.first { $0.qualifiedName == item.qualifiedName && $0.kind == item.kind }
                let callers = wcItem != nil
                    ? await intel.callRoots(.incoming, path: f.newPath, at: wcItem!.nameRange.start, name: item.name)
                    : await intel.callersByName(item.name)
                guard changeContext === cc else { return }
                cc.source = callers.first?.source
                cc.callers = callers.filter { !$0.isTest }
                cc.tests = callers.filter(\.isTest)
                if cc.tests.isEmpty {
                    var opts = TextSearch.Options()
                    opts.wholeWord = true
                    opts.caseSensitive = true
                    opts.globs = ["test/**", "**/tests/**", "*.td", "*.slt", "*.py"]
                    opts.limit = 10
                    cc.testMentions = ((try? await TextSearch.search(root: root, query: item.name, options: opts)) ?? [])
                }
            }
            // Calls the hunk adds or removes.
            func calls(_ lines: [DiffLine]) -> [String] {
                let re = try! NSRegularExpression(pattern: #"\b([a-z_][a-zA-Z0-9_]*)\s*(?:::<[^>]*>)?\("#)
                var out: [String] = []
                for l in lines {
                    let t = l.text.trimmingCharacters(in: .whitespaces)
                    if t.hasPrefix("//") { continue }
                    let ns = t as NSString
                    for m in re.matches(in: t, range: NSRange(location: 0, length: ns.length)) {
                        let n = ns.substring(with: m.range(at: 1))
                        if !Self.callKeywords.contains(n) && !out.contains(n) { out.append(n) }
                    }
                }
                return out
            }
            let removed = Set(calls(h.removed)), added = Set(calls(h.added))
            for (name, isAdded) in removed.subtracting(added).sorted().map({ ($0, false) }) + added.subtracting(removed).sorted().map({ ($0, true) }) {
                guard changeContext === cc else { return }
                guard name.count > 3 else { continue }
                let callers = await intel.callersByName(name)
                if !callers.isEmpty || !isAdded { cc.callChanges.append(.init(name: name, added: isAdded, callers: callers)) }
                if cc.callChanges.count >= 4 { break }
            }
            cc.loading = false
        }
    }
}
