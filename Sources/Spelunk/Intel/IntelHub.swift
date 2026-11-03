import Foundation

/// Answers navigation questions by asking the most precise available provider first and falling
/// back down the chain: the file's language server, then SCIP (Rust), then tree-sitter, then text
/// search. Every answer
/// carries the source that produced it, so the UI can say how far to trust it.
@MainActor
final class IntelHub {
    let root: URL
    let ra: LanguageServer
    let servers: [LanguageServer]
    let scip: SCIPService
    let docs: DocumentCache

    init(root: URL, ra: LanguageServer, servers: [LanguageServer], scip: SCIPService, docs: DocumentCache) {
        self.root = root; self.ra = ra; self.servers = servers; self.scip = scip; self.docs = docs
    }

    /// The language server for a file, if one is configured for its language.
    func server(_ path: String) -> LanguageServer? { servers.first { $0.spec.handles(path) } }

    /// The server for a file when it can answer now.
    private func usable(_ path: String) -> LanguageServer? { server(path).flatMap { $0.status.isUsable ? $0 : nil } }

    /// While rust-analyzer is still warming up, the on-disk SCIP index answers instantly; it may
    /// trail the working copy, so rust-analyzer takes over as soon as it is ready.
    private var scipFirst: Bool { Prefs.scipFirst && !ra.isWarm && scip.index != nil }

    /// File glob and item keywords for text-search fallbacks in a file's language.
    private func searchProfile(_ path: String) -> (glob: String, items: String) {
        switch SourceLanguage.from(path: path) {
        case .swift: return ("*.swift", "func|class|struct|enum|protocol|actor|extension|typealias|var|let|case")
        case .rust: return ("*.rs", "fn|struct|enum|trait|type|const|static|mod|union|macro_rules!")
        default:
            let ext = path.pathExtension
            return (ext.isEmpty ? "*" : "*.\(ext)", "def|class|function|func|fn|struct|type|interface|const|let|var")
        }
    }

    // MARK: SCIP helpers

    private func scipPos(path: String, line: Int, col: Int) -> Int {
        guard let doc = scip.index?.documents[path] else { return col }
        switch doc.positionEncoding {
        case 2: return col
        case 3: return ColumnEncoding.utf32ToUTF16(docs.document(path)?.lineText(line) ?? "", col)
        default:
            // UTF-8 (1) or unspecified: convert so multibyte characters do not skew columns.
            return ColumnEncoding.utf8ToUTF16(docs.document(path)?.lineText(line) ?? "", col)
        }
    }

    private func scipLocation(_ path: String, _ o: SCIPOccurrence) -> CodeLocation {
        CodeLocation(path: path, range: SourceRange(
            start: SourcePos(line: o.line, col: scipPos(path: path, line: o.line, col: o.startCol)),
            end: SourcePos(line: o.endLine, col: scipPos(path: path, line: o.endLine, col: o.endCol))))
    }

    private func scipSymbol(path: String, at p: SourcePos) -> String? {
        guard let idx = scip.index, idx.documents[path] != nil, !scip.isStale(path) else { return nil }
        // Convert our UTF-16 column into the index's encoding by scanning candidates on the line.
        let line = docs.document(path)?.lineText(p.line) ?? ""
        let utf8Col = String(decoding: Array(line.utf16.prefix(p.col)), as: UTF16.self).utf8.count
        let col = idx.documents[path]?.positionEncoding == 2 ? p.col : utf8Col
        return idx.occurrence(path: path, line: p.line, col: col)?.symbol
    }

    // MARK: Details

    func details(path: String, at p: SourcePos, name: String) async -> SymbolDetails {
        var d = SymbolDetails(name: name, kindLabel: "Symbol", source: .textSearch)
        if let srv = usable(path), !(scipFirst && scipSymbol(path: path, at: p) != nil) {
            async let hover = try? srv.hover(path: path, at: p)
            async let defs = try? srv.definition(path: path, at: p)
            if let h = await hover { (d.signature, d.docs) = Self.splitHover(h); d.source = srv.spec.source }
            if let first = await defs?.first { d.definition = first; d.source = srv.spec.source }
        }
        if d.definition == nil, let sym = scipSymbol(path: path, at: p), let idx = scip.index {
            if let def = idx.definitions(of: sym).first { d.definition = scipLocation(def.path, def.occ) }
            if let info = idx.symbols[sym] {
                if d.docs == nil, let doc = info.documentation.dropFirst().first ?? info.documentation.first { d.docs = doc }
                if d.signature == nil, let sig = info.documentation.first { d.signature = sig }
            }
            d.source = .scip
        }
        if d.definition == nil, let def = await syntaxDefinitions(name: name, near: path).first {
            d.definition = def
            d.source = .treeSitter
        }
        if let def = d.definition, let doc = docs.document(def.path),
           let item = doc.syntax.flatOutline.first(where: { $0.nameRange.start.line == def.line && $0.name == name })
            ?? doc.syntax.enclosingItem(line: def.line).flatMap({ $0.name == name ? $0 : nil }) {
            d.kindLabel = item.kind.label
            if d.signature == nil, !item.detail.isEmpty { d.signature = item.detail }
        } else if let sig = d.signature {
            d.kindLabel = Self.kindFromSignature(sig)
        }
        return d
    }

    static func splitHover(_ md: String) -> (String?, String?) {
        // rust-analyzer hover: ```rust\nmodule\n```\n\n```rust\nsignature\n```\n---\ndocs
        var code: [String] = []
        var docsParts: [String] = []
        var inCode = false
        var current: [String] = []
        for line in md.components(separatedBy: "\n") {
            if line.hasPrefix("```") {
                if inCode { code.append(current.joined(separator: "\n")); current = [] }
                inCode.toggle()
                continue
            }
            if inCode { current.append(line) } else if line != "---" { docsParts.append(line) }
        }
        let sig = code.last?.trimmingCharacters(in: .whitespacesAndNewlines)
        let docs = docsParts.joined(separator: "\n").trimmingCharacters(in: .whitespacesAndNewlines)
        return (sig, docs.isEmpty ? nil : docs)
    }

    static func kindFromSignature(_ s: String) -> String {
        let words = s.split(whereSeparator: { $0 == " " || $0 == "\n" || $0 == "(" || $0 == "<" }).map(String.init)
        for w in words {
            switch w {
            case "fn": return "Function"
            case "struct": return "Struct"
            case "enum": return "Enum"
            case "trait": return "Trait"
            case "mod": return "Module"
            case "const": return "Constant"
            case "static": return "Static"
            case "type": return "Type Alias"
            case "let": return "Local"
            case "macro_rules!": return "Macro"
            default: continue
            }
        }
        return s.contains(":") ? "Field" : "Symbol"
    }

    // MARK: Definitions

    func definitions(path: String, at p: SourcePos, name: String) async -> ([CodeLocation], IntelSource) {
        if scipFirst, let defs = scipDefinitions(path: path, at: p) { return (defs, .scip) }
        if let srv = usable(path), let r = try? await srv.definition(path: path, at: p), !r.isEmpty { return (r, srv.spec.source) }
        if Task.isCancelled { return ([], .rustAnalyzer) }
        if let defs = scipDefinitions(path: path, at: p) { return (defs, .scip) }
        let syn = await syntaxDefinitions(name: name, near: path)
        if !syn.isEmpty { return (syn, .treeSitter) }
        return ([], .textSearch)
    }

    private func scipDefinitions(path: String, at p: SourcePos) -> [CodeLocation]? {
        guard let sym = scipSymbol(path: path, at: p), let idx = scip.index else { return nil }
        let defs = idx.definitions(of: sym).map { scipLocation($0.path, $0.occ) }
        return defs.isEmpty ? nil : defs
    }

    /// Finds items named `name` by grepping for item keywords, then confirming against the parsed outline.
    func syntaxDefinitions(name: String, near path: String) async -> [CodeLocation] {
        guard !name.isEmpty, name.first?.isLetter == true || name.first == "_" else { return [] }
        let profile = searchProfile(path)
        let pattern = "(" + profile.items + #")\s+"# + NSRegularExpression.escapedPattern(for: name) + #"\b"#
        var opts = TextSearch.Options()
        opts.regex = true
        opts.caseSensitive = true
        opts.globs = [profile.glob]
        opts.limit = 50
        let hits = (try? await TextSearch.search(root: root, query: pattern, options: opts)) ?? []
        let found = await docs.documents(hits.map(\.path))
        var out: [CodeLocation] = []
        for h in hits {
            guard let doc = found[h.path] else { continue }
            if let item = doc.syntax.flatOutline.first(where: { $0.name == name && $0.nameRange.start.line == h.line }) {
                out.append(CodeLocation(path: h.path, range: item.nameRange))
            }
        }
        // Prefer definitions in the same crate as the current file.
        let crate = path.split(separator: "/").prefix(2).joined(separator: "/")
        return out.sorted { a, b in a.path.hasPrefix(crate) && !b.path.hasPrefix(crate) }
    }

    // MARK: References

    func references(path: String, at p: SourcePos, name: String) async -> ([ReferenceHit], IntelSource) {
        if scipFirst, let hits = scipReferences(path: path, at: p) { return (hits, .scip) }
        // A warm rust-analyzer that answers with no references means there are none; a cold one
        // may not know yet, so only then fall back.
        if let srv = usable(path), let r = try? await srv.references(path: path, at: p), !r.isEmpty || srv.isWarm {
            let defs = Set((try? await srv.definition(path: path, at: p)) ?? [])
            return (r.map { hit($0, isDef: defs.contains($0), source: srv.spec.source) }, srv.spec.source)
        }
        if Task.isCancelled { return ([], .rustAnalyzer) }
        if let hits = scipReferences(path: path, at: p) { return (hits, .scip) }
        var opts = TextSearch.Options()
        opts.wholeWord = true
        opts.caseSensitive = true
        opts.globs = [searchProfile(path).glob]
        opts.limit = 500
        let matches = (try? await TextSearch.search(root: root, query: name, options: opts)) ?? []
        return (matches.map { hit($0.location, isDef: false, source: .textSearch) }, .textSearch)
    }

    private func scipReferences(path: String, at p: SourcePos) -> [ReferenceHit]? {
        guard let sym = scipSymbol(path: path, at: p), let idx = scip.index else { return nil }
        let occs = idx.occurrences(of: sym)
        return occs.isEmpty ? nil : occs.map { hit(scipLocation($0.path, $0.occ), isDef: $0.occ.isDefinition, source: .scip) }
    }

    func hit(_ loc: CodeLocation, isDef: Bool, source: IntelSource) -> ReferenceHit {
        let doc = docs.document(loc.path)
        let preview = doc?.lineText(loc.line).trimmingCharacters(in: .whitespaces) ?? ""
        let enclosing = doc?.syntax.enclosingItem(line: loc.line)?.qualifiedName
        return ReferenceHit(location: loc, preview: preview, isDefinition: isDef, enclosing: enclosing, source: source)
    }

    // MARK: Implementations

    func implementations(path: String, at p: SourcePos, name: String) async -> ([ReferenceHit], IntelSource) {
        if let srv = usable(path), let r = try? await srv.implementations(path: path, at: p), !r.isEmpty || srv.isWarm {
            return (r.map { implHit($0, source: srv.spec.source) }, srv.spec.source)
        }
        if Task.isCancelled { return ([], .rustAnalyzer) }
        if let sym = scipSymbol(path: path, at: p), let idx = scip.index, let impls = idx.implementors[sym], !impls.isEmpty {
            let locs = impls.flatMap { idx.definitions(of: $0) }.map { scipLocation($0.path, $0.occ) }
            return (locs.map { implHit($0, source: .scip) }, .scip)
        }
        let escaped = NSRegularExpression.escapedPattern(for: name)
        var opts = TextSearch.Options()
        opts.regex = true
        opts.caseSensitive = true
        opts.globs = [searchProfile(path).glob]
        opts.limit = 200
        let q = #"impl(<[^>]*>)?\s+([\w:]+::)?"# + escaped + #"\b"#
        let matches = (try? await TextSearch.search(root: root, query: q, options: opts)) ?? []
        return (matches.map { implHit($0.location, source: .textSearch) }, .textSearch)
    }

    private func implHit(_ loc: CodeLocation, source: IntelSource) -> ReferenceHit {
        var h = hit(loc, isDef: true, source: source)
        if let doc = docs.document(loc.path),
           let item = doc.syntax.enclosingItem(line: loc.line, includeContainers: true) {
            let impl = item.kind == .impl ? item : (item.parent?.kind == .impl ? item.parent : nil)
            if let impl { h.enclosing = impl.detail }
        }
        return h
    }

    // MARK: Call hierarchy

    func callRoots(_ direction: CallDirection, path: String, at p: SourcePos, name: String) async -> [CallNode] {
        if let srv = usable(path), !(scipFirst && scipSymbol(path: path, at: p) != nil), let items = try? await srv.prepareCallHierarchy(path: path, at: p), let item = items.first {
            let root = CallNode(name: item.value["name"] as? String ?? name, detail: item.value["detail"] as? String ?? "",
                                location: CodeLocation(path: path, range: LanguageServer.parseRange(item.value["selectionRange"]) ?? SourceRange(line: p.line)),
                                callSites: [], source: srv.spec.source, payload: item, ancestry: [])
            await expand(root, direction)
            if let c = root.children, !c.isEmpty || srv.isWarm { return c }
        }
        if Task.isCancelled { return [] }
        let def = await definitions(path: path, at: p, name: name).0.first ?? CodeLocation(path: path, range: SourceRange(line: p.line, col: p.col))
        let root = CallNode(name: name, detail: "", location: def, callSites: [], source: .treeSitter, payload: nil, ancestry: [])
        await expand(root, direction)
        return root.children ?? []
    }

    func expand(_ node: CallNode, _ direction: CallDirection) async {
        guard node.children == nil, !node.isLoading else { return }
        await expandChildren(node, direction)
        guard let children = node.children else { return }
        let found = await docs.documents(children.map(\.location.path))
        for n in children {
            n.isTest = FileClassifier.isTest(n.location.path) || (found[n.location.path]?.syntax.isTestLine(n.location.line) ?? false)
        }
    }

    private func expandChildren(_ node: CallNode, _ direction: CallDirection) async {
        if node.isRecursive { node.children = []; node.note = "Recursive branch stopped"; return }
        node.isLoading = true
        defer { node.isLoading = false }
        let ancestry = node.ancestry.union([node.key])

        if let payload = node.payload, let srv = usable(node.location.path), let edges = try? await srv.calls(direction, of: payload) {
            node.children = edges.map { e in
                CallNode(name: e.name, detail: e.detail, location: e.location, callSites: e.callSites,
                         source: srv.spec.source, payload: e.item, ancestry: ancestry)
            }.sorted { $0.location.path == $1.location.path ? $0.location.line < $1.location.line : $0.location.path < $1.location.path }
            return
        }
        node.children = direction == .incoming
            ? await fallbackCallers(of: node, ancestry: ancestry)
            : await fallbackCallees(of: node, ancestry: ancestry)
        if node.children?.isEmpty == true { node.note = direction == .incoming ? "No callers found" : "No calls found" }
    }

    /// Callers of a function known only by name (for example one a diff removed calls to), found by
    /// searching for call expressions and grouping by enclosing function.
    func callersByName(_ name: String) async -> [CallNode] {
        let node = CallNode(name: name, detail: "", location: CodeLocation(path: "", range: SourceRange(line: 0)), callSites: [],
                            source: .textSearch, payload: nil, ancestry: [])
        return await fallbackCallers(of: node, ancestry: [])
    }

    private func fallbackCallers(of node: CallNode, ancestry: Set<String>) async -> [CallNode] {
        var sites: [CodeLocation] = []
        var source = IntelSource.textSearch
        if let idx = scip.index, let sym = scipSymbol(path: node.location.path, at: node.location.range.start) {
            sites = idx.occurrences(of: sym).filter { !$0.occ.isDefinition }.map { scipLocation($0.path, $0.occ) }
            source = .scip
        }
        if sites.isEmpty {
            var opts = TextSearch.Options()
            opts.regex = true
            opts.caseSensitive = true
            opts.globs = node.location.path.isEmpty ? ["*.rs", "*.swift"] : [searchProfile(node.location.path).glob]
            opts.limit = 400
            let q = #"\b"# + NSRegularExpression.escapedPattern(for: node.name) + #"\s*(::<[^>]*>)?\("#
            sites = ((try? await TextSearch.search(root: root, query: q, options: opts)) ?? []).map(\.location)
            source = .textSearch
        }
        let found = await docs.documents(sites.map(\.path))
        var groups: [String: (OutlineItem, String, [CodeLocation])] = [:]
        var order: [String] = []
        for s in sites {
            guard let doc = found[s.path], let item = doc.syntax.enclosingItem(line: s.line),
                  item.kind == .function || item.kind == .method else { continue }
            if item.nameRange.start.line == s.line && item.name == node.name { continue }
            let key = "\(s.path)#\(item.nameRange.start.line)"
            if groups[key] == nil { groups[key] = (item, s.path, []); order.append(key) }
            groups[key]?.2.append(s)
        }
        return order.compactMap { k in
            guard let (item, path, calls) = groups[k] else { return nil }
            return CallNode(name: item.qualifiedName, detail: item.detail, location: CodeLocation(path: path, range: item.nameRange),
                            callSites: calls, source: source, payload: nil, ancestry: ancestry)
        }
    }

    private func fallbackCallees(of node: CallNode, ancestry: Set<String>) async -> [CallNode] {
        guard let doc = docs.document(node.location.path),
              let item = doc.syntax.enclosingItem(line: node.location.line),
              item.kind == .function || item.kind == .method else { return [] }
        let bodyStart = doc.lines.offset(of: SourcePos(line: item.headerEndLine, col: 0))
        let bodyEnd = doc.lines.offset(of: item.range.end)
        var seen: [String: CallNode] = [:]
        var order: [String] = []
        for t in doc.syntax.tokens where t.kind == .function && t.range.location >= bodyStart && NSMaxRange(t.range) <= bodyEnd {
            let name = doc.ns.substring(with: t.range)
            let site = CodeLocation(path: doc.path, range: SourceRange(start: doc.lines.position(of: t.range.location), end: doc.lines.position(of: NSMaxRange(t.range))))
            if let existing = seen[name] { existing.callSites.append(site); continue }
            let defs = await definitions(path: doc.path, at: site.range.start, name: name)
            guard let def = defs.0.first else { continue }
            let n = CallNode(name: name, detail: "", location: def, callSites: [site], source: defs.1, payload: nil, ancestry: ancestry)
            seen[name] = n
            order.append(name)
        }
        return order.compactMap { seen[$0] }
    }
}
