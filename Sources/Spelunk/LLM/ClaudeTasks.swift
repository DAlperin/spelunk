import Foundation

/// Prompts and response shapes for the app's Claude features.
enum ClaudeTasks {
    // MARK: Traces

    struct TraceResponse: Decodable {
        struct Step: Decodable {
            var file: String
            var symbol: String
            var line: Int?
            var note: String
        }
        var title: String
        var summary: String?
        var steps: [Step]
    }

    static let traceSchema: [String: Any] = [
        "type": "object",
        "properties": [
            "title": ["type": "string", "description": "Short name for the path, e.g. 'SUBSCRIBE request to compute replica'"],
            "summary": ["type": "string", "description": "Two or three sentences describing the path end to end"],
            "steps": [
                "type": "array",
                "items": [
                    "type": "object",
                    "properties": [
                        "file": ["type": "string", "description": "Repository-relative path"],
                        "symbol": ["type": "string", "description": "Exact identifier of the function, method, type or macro at this step (no path, no parentheses)"],
                        "line": ["type": "integer", "description": "1-based line of the symbol's definition or the relevant call"],
                        "note": ["type": "string", "description": "What happens at this step and how control or data reaches the next step"],
                    ],
                    "required": ["file", "symbol", "note"],
                ],
            ],
        ],
        "required": ["title", "steps"],
    ]

    static let traceSystem = """
    You trace control and data flow through a Rust codebase for an engineer reading it in a code viewer.
    Read the code with your tools; do not guess. Follow the path in execution order, one step per function,
    method, trait impl, channel hop or task boundary that matters. Call out dynamic dispatch (which impl runs),
    async boundaries (spawned tasks, channels, awaits), cfg/feature gates and error paths that change the route.
    Keep notes concrete: name the arguments, fields, messages or state that carry the flow. 4 to 25 steps.
    Every step must point at a symbol that exists in the file you name.
    """

    static func tracePrompt(question: String, anchor: String?) -> String {
        var p = "Trace this through the code:\n\n\(question)\n"
        if let anchor { p += "\nStart from (or pass through) this location the user is looking at:\n\(anchor)\n" }
        p += "\nReturn the ordered steps."
        return p
    }

    /// Resolves model-proposed steps against real outlines, fixing line numbers.
    @MainActor
    static func materialize(_ r: TraceResponse, question: String, docs: DocumentCache) -> Trace {
        var t = Trace(title: r.title, question: question, summary: r.summary, origin: .claude)
        for s in r.steps {
            var path = s.file.hasPrefix("./") ? String(s.file.dropFirst(2)) : s.file
            if path.hasPrefix(docs.root.path + "/") { path = String(path.dropFirst(docs.root.path.count + 1)) }
            let bare = s.symbol.split(separator: ":").last.map { String($0).replacingOccurrences(of: "()", with: "") } ?? s.symbol
            var loc = CodeLocation(path: path, range: SourceRange(line: max(0, (s.line ?? 1) - 1)))
            var verified = false
            var snippet = ""
            if let doc = docs.document(path) {
                let hint = max(0, (s.line ?? 1) - 1)
                let items = doc.syntax.flatOutline.filter { $0.name == bare }
                if let best = items.min(by: { abs($0.nameRange.start.line - hint) < abs($1.nameRange.start.line - hint) }) {
                    loc = CodeLocation(path: path, range: best.nameRange)
                    verified = true
                } else if let found = nearestOccurrence(of: bare, in: doc, near: hint) {
                    loc = CodeLocation(path: path, range: found)
                    verified = true
                }
                snippet = doc.lineText(loc.line).trimmingCharacters(in: .whitespaces)
            }
            t.steps.append(TraceStep(title: s.symbol, location: loc, note: s.note, edge: .claude, source: .claude,
                                     verified: verified, snippet: snippet))
        }
        return t
    }

    @MainActor
    static func nearestOccurrence(of word: String, in doc: SourceDocument, near line: Int) -> SourceRange? {
        guard !word.isEmpty, let re = try? NSRegularExpression(pattern: "\\b\(NSRegularExpression.escapedPattern(for: word))\\b") else { return nil }
        let ms = re.matches(in: doc.text, range: NSRange(location: 0, length: doc.ns.length))
        let ranges = ms.map { m in
            SourceRange(start: doc.lines.position(of: m.range.location), end: doc.lines.position(of: NSMaxRange(m.range)))
        }
        return ranges.min { abs($0.start.line - line) < abs($1.start.line - line) }
    }

    // MARK: Questions

    static let askSystem = """
    You answer questions about a Rust codebase for an engineer reading it in a code viewer. Read the code with
    your tools before answering. Cite locations as `path/to/file.rs:LINE` (repository-relative, 1-based) so the
    viewer can link them. Be direct and specific; prefer short paragraphs and lists over long prose.
    """

    // MARK: Quick classification

    static let classifySystem = """
    You classify diff hunks so a reviewer can skip noise and focus on what matters. You see only the diff.
    Tiers: critical (invariants, unsafe, concurrency, persistence/protocol formats, public API, error
    handling that can now panic or swallow errors, security), behavior (logic changes), supporting (plumbing
    that follows from a change elsewhere), docs (comment/doc content changes; safety/invariant comments are
    critical), tests (test code and fixtures), mechanical (formatting, renames, imports, typo fixes, lockfiles,
    generated code). Each hunk has a heuristic tier from static rules; keep it unless the diff clearly says
    otherwise. Reasons: at most 8 words, concrete.
    """

    struct ClassifyResponse: Decodable {
        struct Item: Decodable { var id: String; var tier: String; var reason: String }
        var hunks: [Item]
    }

    static let classifySchema: [String: Any] = [
        "type": "object",
        "properties": [
            "hunks": [
                "type": "array",
                "items": [
                    "type": "object",
                    "properties": [
                        "id": ["type": "string"],
                        "tier": ["type": "string", "enum": ["critical", "behavior", "supporting", "docs", "tests", "mechanical"]],
                        "reason": ["type": "string"],
                    ],
                    "required": ["id", "tier", "reason"],
                ],
            ],
        ],
        "required": ["hunks"],
    ]

    // MARK: Review triage

    struct TriageResponse: Decodable {
        struct Item: Decodable {
            var id: String
            var tier: String
            var reason: String
            var summary: String?
        }
        var overview: String
        var reviewOrder: [String]?
        var hunks: [Item]
    }

    static let triageSchema: [String: Any] = [
        "type": "object",
        "properties": [
            "overview": ["type": "string", "description": "What the change does and where the risk is, 3-6 sentences"],
            "reviewOrder": ["type": "array", "items": ["type": "string"], "description": "Hunk ids in the order a reviewer should read them; only important ones"],
            "hunks": [
                "type": "array",
                "items": [
                    "type": "object",
                    "properties": [
                        "id": ["type": "string"],
                        "tier": ["type": "string", "enum": ["critical", "behavior", "supporting", "docs", "tests", "mechanical"]],
                        "reason": ["type": "string", "description": "Why this tier, at most 12 words"],
                        "summary": ["type": "string", "description": "What the hunk changes, one sentence"],
                    ],
                    "required": ["id", "tier", "reason"],
                ],
            ],
        ],
        "required": ["overview", "hunks"],
    ]

    static let triageSystem = """
    You triage a code change so a reviewer can spend attention where it matters. Classify every hunk:
    - critical: changes to invariants, unsafe code, concurrency/locking/ordering, persistence formats, public API
      or protocol shape, error handling that can now panic or swallow errors, security-relevant logic.
    - behavior: ordinary logic changes that alter what the program does.
    - supporting: plumbing that follows from a behavior change elsewhere (new parameter threaded through,
      constructor updates, re-exports, config wiring) with no independent decision in it.
    - docs: comments, doc comments and documentation whose content changed (explanations, design notes,
      new docs). Comments that state safety or invariants belong in critical.
    - tests: test code, fixtures, snapshots.
    - mechanical: formatting, renames, import churn, typo-level comment edits, lockfiles, generated code, moves.
    Each hunk comes with a heuristic tier from static analysis; overrule it when the code says otherwise.
    You may read files in the repository to understand context. Keep reasons terse.
    """
}
