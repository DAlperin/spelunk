import Foundation

struct TextMatch: Identifiable, Hashable, Sendable {
    var path: String
    var line: Int
    var col: Int
    var length: Int
    var text: String
    var id: String { "\(path):\(line):\(col)" }
    var location: CodeLocation {
        CodeLocation(path: path, range: SourceRange(start: SourcePos(line: line, col: col), end: SourcePos(line: line, col: col + length)))
    }
}

/// Workspace text search through ripgrep, with a slow pure-Swift fallback.
enum TextSearch {
    struct Options: Sendable {
        var regex = false
        var wholeWord = false
        var caseSensitive = false
        var globs: [String] = []
        var limit = 2000
    }

    /// What a search found, whether it stopped at the limit, and ripgrep's complaint when it had one
    /// (such as an invalid regular expression).
    struct Outcome: Sendable {
        var matches: [TextMatch] = []
        var truncated = false
        var error: String?
    }

    static func run(root: URL, query: String, options: Options) async -> Outcome {
        guard !query.isEmpty else { return Outcome() }
        guard Shell.which("rg") != nil else {
            let m = fallback(root: root, query: query, options: options)
            return Outcome(matches: m, truncated: m.count >= options.limit)
        }
        var args = ["--json", "--max-columns", "400", "--max-count", "200"]
        if !options.regex { args.append("--fixed-strings") }
        if options.wholeWord { args.append("--word-regexp") }
        args.append(options.caseSensitive ? "--case-sensitive" : "--smart-case")
        for g in options.globs { args += ["--glob", g] }
        args += ["--", query, "."]
        guard let r = try? await Shell.run("rg", args, cwd: root) else { return Outcome() }
        // ripgrep exits 1 for no matches and 2 for errors.
        if r.status == 2, r.stdout.isEmpty {
            let e = r.stderr.split(separator: "\n").map { $0.trimmingCharacters(in: .whitespaces) }.filter { !$0.isEmpty }
            return Outcome(error: e.prefix(4).joined(separator: "\n"))
        }
        let m = parseRipgrepJSON(r.stdout, limit: options.limit + 1)
        return Outcome(matches: Array(m.prefix(options.limit)), truncated: m.count > options.limit)
    }

    static func search(root: URL, query: String, options: Options) async throws -> [TextMatch] {
        guard !query.isEmpty else { return [] }
        if Shell.which("rg") != nil {
            var args = ["--json", "--max-columns", "400", "--max-count", "200"]
            if !options.regex { args.append("--fixed-strings") }
            if options.wholeWord { args.append("--word-regexp") }
            args.append(options.caseSensitive ? "--case-sensitive" : "--smart-case")
            for g in options.globs { args += ["--glob", g] }
            args += ["--", query, "."]
            let r = try await Shell.run("rg", args, cwd: root)
            return parseRipgrepJSON(r.stdout, limit: options.limit)
        }
        return fallback(root: root, query: query, options: options)
    }

    static func parseRipgrepJSON(_ out: String, limit: Int) -> [TextMatch] {
        var results: [TextMatch] = []
        for line in out.split(separator: "\n") {
            guard results.count < limit,
                  let obj = try? JSONSerialization.jsonObject(with: Data(line.utf8)) as? [String: Any],
                  obj["type"] as? String == "match",
                  let data = obj["data"] as? [String: Any],
                  let path = ((data["path"] as? [String: Any])?["text"] as? String),
                  let lineNo = data["line_number"] as? Int,
                  let text = (data["lines"] as? [String: Any])?["text"] as? String else { continue }
            let clean = path.hasPrefix("./") ? String(path.dropFirst(2)) : path
            let trimmed = text.trimmingCharacters(in: .newlines)
            for sm in (data["submatches"] as? [[String: Any]]) ?? [] {
                let s = sm["start"] as? Int ?? 0, e = sm["end"] as? Int ?? s
                let c16 = ColumnEncoding.utf8ToUTF16(trimmed, s)
                let e16 = ColumnEncoding.utf8ToUTF16(trimmed, e)
                results.append(TextMatch(path: clean, line: lineNo - 1, col: c16, length: e16 - c16, text: trimmed))
            }
        }
        return results
    }

    private static func fallback(root: URL, query: String, options: Options) -> [TextMatch] {
        var results: [TextMatch] = []
        let e = FileManager.default.enumerator(at: root, includingPropertiesForKeys: nil, options: [.skipsHiddenFiles])
        let pattern = options.regex ? query : NSRegularExpression.escapedPattern(for: query)
        let full = options.wholeWord ? "\\b\(pattern)\\b" : pattern
        guard let re = try? NSRegularExpression(pattern: full, options: options.caseSensitive ? [] : [.caseInsensitive]) else { return [] }
        while let u = e?.nextObject() as? URL, results.count < options.limit {
            if u.lastPathComponent == "target" { e?.skipDescendants(); continue }
            guard FileClassifier.isSource(u.path), let text = try? String(contentsOf: u, encoding: .utf8) else { continue }
            for (i, line) in text.components(separatedBy: "\n").enumerated() {
                let ns = line as NSString
                for m in re.matches(in: line, range: NSRange(location: 0, length: ns.length)) {
                    results.append(TextMatch(path: u.relativePath(from: root), line: i, col: m.range.location, length: m.range.length, text: line))
                }
            }
        }
        return results
    }
}
