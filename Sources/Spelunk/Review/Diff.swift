import Foundation

enum DiffLineKind: String, Codable, Sendable { case context, added, removed }

struct DiffLine: Hashable, Sendable {
    var kind: DiffLineKind
    var text: String
    /// Zero-based line numbers in the old and new file.
    var oldLine: Int?
    var newLine: Int?
}

struct Hunk: Identifiable, Hashable, Sendable {
    var id: String
    var path: String
    var oldStart: Int
    var oldCount: Int
    var newStart: Int
    var newCount: Int
    var header: String
    var lines: [DiffLine]

    var added: [DiffLine] { lines.filter { $0.kind == .added } }
    var removed: [DiffLine] { lines.filter { $0.kind == .removed } }
    var addedCount: Int { lines.lazy.filter { $0.kind == .added }.count }
    var removedCount: Int { lines.lazy.filter { $0.kind == .removed }.count }

    /// First changed line in the new file, or where the deletion happened.
    var anchorNewLine: Int {
        lines.first { $0.kind == .added }?.newLine
            ?? lines.first { $0.kind == .removed }.flatMap { r in
                lines.last { $0.newLine != nil && ($0.oldLine ?? -1) < (r.oldLine ?? 0) }?.newLine.map { $0 + 1 }
            }
            ?? max(0, newStart - 1)
    }

    /// Identity that survives edits elsewhere in the file: the path plus the changed text. Viewed
    /// marks and triage results key on this, so a rewritten hunk comes back unreviewed.
    var contentKey: String {
        let body = lines.filter { $0.kind != .context }.map { ($0.kind == .added ? "+" : "-") + $0.text }.joined(separator: "\n")
        return path + "#" + String(UInt(bitPattern: body.stableHash), radix: 36)
    }

    var anchorOldLine: Int { lines.first { $0.kind == .removed }?.oldLine ?? max(0, oldStart - 1) }
}

struct FileDiff: Identifiable, Hashable, Sendable {
    enum Status: String, Sendable { case added, deleted, modified, renamed }
    var oldPath: String
    var newPath: String
    var status: Status
    var isBinary = false
    var hunks: [Hunk] = []
    var id: String { newPath }
    var path: String { status == .deleted ? oldPath : newPath }
    var addedCount: Int { hunks.reduce(0) { $0 + $1.addedCount } }
    var removedCount: Int { hunks.reduce(0) { $0 + $1.removedCount } }
}

enum DiffParser {
    static func parse(_ text: String) -> [FileDiff] {
        var files: [FileDiff] = []
        var current: FileDiff?
        var hunk: Hunk?
        var oldLine = 0, newLine = 0

        func flushHunk() {
            if let h = hunk { current?.hunks.append(h) }
            hunk = nil
        }
        func flushFile() {
            flushHunk()
            if let f = current { files.append(f) }
            current = nil
        }
        func stripPrefix(_ s: Substring) -> String {
            var p = String(s)
            if p.hasPrefix("\"") && p.hasSuffix("\"") { p = String(p.dropFirst().dropLast()) }
            if p.hasPrefix("a/") || p.hasPrefix("b/") { p = String(p.dropFirst(2)) }
            return p
        }

        var oldLeft = 0, newLeft = 0
        for raw in text.split(separator: "\n", omittingEmptySubsequences: false) {
            let line = raw.hasSuffix("\r") ? raw.dropLast() : raw
            if hunk != nil && (oldLeft > 0 || newLeft > 0) {
                if line.hasPrefix("+") {
                    hunk!.lines.append(DiffLine(kind: .added, text: String(line.dropFirst()), oldLine: nil, newLine: newLine))
                    newLine += 1; newLeft -= 1
                    continue
                } else if line.hasPrefix("-") {
                    hunk!.lines.append(DiffLine(kind: .removed, text: String(line.dropFirst()), oldLine: oldLine, newLine: nil))
                    oldLine += 1; oldLeft -= 1
                    continue
                } else if line.hasPrefix(" ") || line.isEmpty {
                    hunk!.lines.append(DiffLine(kind: .context, text: String(line.dropFirst()), oldLine: oldLine, newLine: newLine))
                    oldLine += 1; newLine += 1; oldLeft -= 1; newLeft -= 1
                    continue
                }
            }
            if line.hasPrefix("\\") { continue }
            if line.hasPrefix("diff --git ") {
                flushFile()
                let rest = line.dropFirst("diff --git ".count)
                var oldP = "", newP = ""
                if let r = rest.range(of: " b/") {
                    oldP = stripPrefix(rest[..<r.lowerBound])
                    newP = String(rest[r.upperBound...])
                }
                current = FileDiff(oldPath: oldP, newPath: newP, status: .modified)
                continue
            }
            guard current != nil else { continue }
            if line.hasPrefix("new file mode") { current?.status = .added; continue }
            if line.hasPrefix("deleted file mode") { current?.status = .deleted; continue }
            if line.hasPrefix("rename from ") { current?.oldPath = String(line.dropFirst(12)); current?.status = .renamed; continue }
            if line.hasPrefix("rename to ") { current?.newPath = String(line.dropFirst(10)); current?.status = .renamed; continue }
            if line.hasPrefix("Binary files") { current?.isBinary = true; continue }
            if line.hasPrefix("--- ") {
                let p = line.dropFirst(4)
                if p != "/dev/null" { current?.oldPath = stripPrefix(p) }
                continue
            }
            if line.hasPrefix("+++ ") {
                let p = line.dropFirst(4)
                if p != "/dev/null" { current?.newPath = stripPrefix(p) }
                continue
            }
            if line.hasPrefix("@@") {
                flushHunk()
                let (os, oc, ns, nc, hdr) = parseHunkHeader(String(line))
                let path = current!.status == .deleted ? current!.oldPath : current!.newPath
                hunk = Hunk(id: "\(path)#\(current!.hunks.count)", path: path, oldStart: os, oldCount: oc, newStart: ns, newCount: nc, header: hdr, lines: [])
                oldLine = max(0, os - 1)
                newLine = max(0, ns - 1)
                oldLeft = oc
                newLeft = nc
            }
        }
        flushFile()
        return files
    }

    static func parseHunkHeader(_ s: String) -> (Int, Int, Int, Int, String) {
        // @@ -a,b +c,d @@ context
        let parts = s.components(separatedBy: "@@")
        let ranges = parts.count > 1 ? parts[1].trimmingCharacters(in: .whitespaces) : ""
        let ctx = parts.count > 2 ? parts[2...].joined(separator: "@@").trimmingCharacters(in: .whitespaces) : ""
        var os = 0, oc = 1, ns = 0, nc = 1
        for r in ranges.split(separator: " ") {
            let nums = r.dropFirst().split(separator: ",").compactMap { Int($0) }
            if r.hasPrefix("-") { os = nums.first ?? 0; oc = nums.count > 1 ? nums[1] : 1 }
            if r.hasPrefix("+") { ns = nums.first ?? 0; nc = nums.count > 1 ? nums[1] : 1 }
        }
        return (os, oc, ns, nc, ctx)
    }
}
