import Foundation

/// Converts rule files written in the earlier line-based format (`rule <tier> "<reason>"` followed by
/// indented conditions) to s-expressions. Comments are kept; a line it cannot convert becomes a
/// comment and an error.
enum LegacyRules {
    /// Whether the first form in the file is an unparenthesized `rule`, `attach` or `disable` line.
    static func isLegacy(_ text: String) -> Bool {
        for raw in text.split(separator: "\n", omittingEmptySubsequences: true) {
            let t = raw.trimmingCharacters(in: .whitespaces)
            if t.isEmpty || t.hasPrefix("#") || t.hasPrefix(";") { continue }
            return t.hasPrefix("rule ") || t.hasPrefix("attach ") || t.hasPrefix("disable ")
        }
        return false
    }

    static func convert(_ text: String) -> (text: String, errors: [String]) {
        var out: [String] = []
        var errors: [String] = []
        var open = false
        func close() {
            guard open else { return }
            // Close after the form's last non-comment line, so trailing comments stay outside it.
            if let i = out.lastIndex(where: { let t = $0.trimmingCharacters(in: .whitespaces); return !t.isEmpty && !t.hasPrefix(";") }) {
                out[i] += ")"
            }
            open = false
        }

        for (i, raw) in text.components(separatedBy: "\n").enumerated() {
            let n = i + 1
            let (code, comment) = split(raw)
            let trimmed = code.trimmingCharacters(in: .whitespaces)
            let note = comment.map { " ;" + $0 } ?? ""
            if trimmed.isEmpty {
                if let comment { out.append(String(raw.prefix { $0 == " " || $0 == "\t" }) + ";" + comment) } else { out.append("") }
                continue
            }
            let indented = code.first == " " || code.first == "\t"
            if !indented {
                close()
                if trimmed.hasPrefix("disable "), let r = quoted(String(trimmed.dropFirst(8))) {
                    out.append("(disable \(str(r)))" + note)
                } else if trimmed.hasPrefix("rule ") {
                    let rest = trimmed.dropFirst(5).trimmingCharacters(in: .whitespaces)
                    let tier = rest.prefix { !$0.isWhitespace }
                    let after = rest.dropFirst(tier.count).trimmingCharacters(in: .whitespaces)
                    guard let reason = quoted(after) else {
                        errors.append("\(n): could not convert `\(trimmed)`")
                        out.append("; " + trimmed)
                        continue
                    }
                    let flags = after.dropFirst(reason.count + 2).split(separator: " ").map { ":" + $0 }
                    out.append((["(rule", String(tier), str(reason)] + flags).joined(separator: " ") + note)
                    open = true
                } else if trimmed.hasPrefix("attach "), let title = quoted(trimmed.dropFirst(7).trimmingCharacters(in: .whitespaces)) {
                    let rest = trimmed.dropFirst(7).trimmingCharacters(in: .whitespaces).dropFirst(title.count + 2)
                    var parts = ["(attach", str(title)]
                    let flags = rest.split(separator: " ").map(String.init)
                    var j = 0
                    while j < flags.count {
                        if flags[j] == "per", j + 1 < flags.count { parts += [":per", flags[j + 1]]; j += 2; continue }
                        if flags[j] == "auto" { parts.append(":auto") }
                        j += 1
                    }
                    out.append(parts.joined(separator: " ") + note)
                    open = true
                } else {
                    errors.append("\(n): could not convert `\(trimmed)`")
                    out.append("; " + trimmed)
                }
                continue
            }
            guard open else {
                errors.append("\(n): condition outside a rule")
                out.append("  ; " + trimmed)
                continue
            }
            if let c = clause(trimmed) {
                out.append("  " + c + note)
            } else {
                errors.append("\(n): could not convert `\(trimmed)`")
                out.append("  ; " + trimmed)
            }
        }
        close()
        return (out.joined(separator: "\n"), errors)
    }

    /// One indented line: an attach action or model, or a possibly negated condition.
    private static func clause(_ line: String) -> String? {
        if line.hasPrefix("run ") { return "(run \(str(line.dropFirst(4).trimmingCharacters(in: .whitespaces))))" }
        if line.hasPrefix("claude ") {
            let arg = line.dropFirst(7).trimmingCharacters(in: .whitespaces)
            return "(claude \(str(quoted(arg) ?? arg)))"
        }
        if line.hasPrefix("model ") { return ":model " + line.dropFirst(6).trimmingCharacters(in: .whitespaces) }
        if line.hasPrefix("not ") { return condition(line.dropFirst(4).trimmingCharacters(in: .whitespaces)).map { "(not \($0))" } }
        return condition(line)
    }

    private static func condition(_ s: String) -> String? {
        let parts = s.split(separator: " ", maxSplits: 1).map(String.init)
        let head = parts[0], arg = parts.count > 1 ? parts[1].trimmingCharacters(in: .whitespaces) : ""
        let words = arg.split(separator: " ", maxSplits: 1).map(String.init)
        switch head {
        case "path":
            guard arg.hasPrefix("~") else { return nil }
            return "(path \(str(arg.dropFirst().trimmingCharacters(in: .whitespaces))))"
        case "lang": return "(lang " + arg.split(separator: ",").map { $0.trimmingCharacters(in: .whitespaces) }.joined(separator: " ") + ")"
        case "file", "hunk": return arg.isEmpty ? nil : "(\(head) \(arg))"
        case "code", "comment", "text":
            guard words.count == 2, let re = regex(words[1]) else { return nil }
            return "(\(head) \(words[0]) \(re))"
        case "comment-words", "lines", "refs": return "(\(head) \(arg))"
        case "callers":
            if words.first == "in", words.count == 2 { return "(callers in \(str(words[1])))" }
            return "(callers \(arg))"
        case "called-from":
            var re = arg, depth = ""
            if let r = arg.range(of: #"\s+depth\s+\d+\s*$"#, options: .regularExpression) {
                depth = " :depth " + (arg[r].split(separator: " ").last.map(String.init) ?? "3")
                re = String(arg[..<r.lowerBound])
            }
            return regex(re).map { "(called-from \($0)\(depth))" }
        case "calls", "signature": return regex(arg).map { "(\(head) \($0))" }
        case "llm": return quoted(arg).map { "(llm \(str($0)))" }
        case "ts":
            guard words.count == 2 else { return nil }
            if words[0] == "touches" { return "(ts touches " + words[1].split(separator: ",").map { $0.trimmingCharacters(in: .whitespaces) }.joined(separator: " ") + ")" }
            return words[0] == "query" ? "(ts query \(str(words[1])))" : nil
        default: return nil
        }
    }

    /// A `/regex/flags` argument with any unescaped inner slash escaped, since the new reader ends a
    /// regex at the first one.
    private static func regex(_ s: String) -> String? {
        guard s.hasPrefix("/"), let end = s.lastIndex(of: "/"), end != s.startIndex else { return nil }
        let body = s[s.index(after: s.startIndex)..<end]
        var out = "", escaped = false
        for c in body {
            if escaped { out.append(c); escaped = false; continue }
            if c == "\\" { out.append(c); escaped = true; continue }
            if c == "/" { out += "\\/" } else { out.append(c) }
        }
        return "/" + out + "/" + s[s.index(after: end)...]
    }

    private static func str(_ s: String) -> String {
        "\"" + s.replacingOccurrences(of: "\\", with: "\\\\").replacingOccurrences(of: "\"", with: "\\\"") + "\""
    }

    private static func quoted(_ s: String) -> String? {
        guard s.hasPrefix("\""), let end = s.dropFirst().firstIndex(of: "\"") else { return nil }
        return String(s[s.index(after: s.startIndex)..<end])
    }

    /// Splits a line at a `#` comment, leaving `#` inside a regex, a string or a tree-sitter query.
    private static func split(_ s: String) -> (code: String, comment: String?) {
        var inRegex = false, inString = false, depth = 0
        var prev: Character = " "
        for (i, c) in s.enumerated() {
            if c == "\"" && prev != "\\" { inString.toggle() }
            if c == "/" && !inString {
                if inRegex { if prev != "\\" { inRegex = false } } else if prev == " " || prev == "\t" { inRegex = true }
            }
            if c == "(" && !inString && !inRegex { depth += 1 }
            if c == ")" && !inString && !inRegex { depth -= 1 }
            if c == "#" && !inRegex && !inString && depth == 0 && (i == 0 || prev == " " || prev == "\t") {
                return (String(s.prefix(i)), String(s.dropFirst(i + 1)))
            }
            prev = c
        }
        return (s, nil)
    }
}
