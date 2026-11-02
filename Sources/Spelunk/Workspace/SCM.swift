import Foundation
import Observation

enum SCMSection: String, CaseIterable, Identifiable {
    case changes = "Changes", pullRequests = "Pull Requests"
    var id: String { rawValue }
}

/// Source control state for the workspace: the jj change graph (or git log), file status, and
/// jj operations. Every command passes its message explicitly so no editor is ever needed.
@MainActor @Observable
final class SCMService {
    struct Change: Identifiable, Hashable {
        var changeId: String
        var commitId: String
        var description: String
        var author: String
        var ago: String
        var bookmarks: [String]
        var isWorkingCopy: Bool
        var isEmpty: Bool
        var hasConflict: Bool
        var isImmutable: Bool
        var id: String { commitId }
        /// Revision expression usable in jj or git commands.
        var rev: String { changeId.isEmpty ? commitId : changeId }
    }

    struct GraphRow: Identifiable, Hashable {
        var id: Int
        var graph: String
        var change: Change?
    }

    struct FileStatus: Identifiable, Hashable {
        var status: String
        var path: String
        var id: String { status + path }
    }

    let root: URL
    var kind: VCSKind = .none
    var rows: [GraphRow] = []
    var workingCopy: Change?
    var workingCopyFiles: [FileStatus] = []
    var selectedID: String?
    var selectedFiles: [FileStatus] = []
    var revset = UserDefaults.standard.string(forKey: "scm.revset") ?? ""
    var busy: String?
    var lastError: String?
    var lastOutput: String?
    var focusDescription = false
    var descriptionDraft = ""

    init(root: URL) { self.root = root }

    var selected: Change? { rows.first { $0.change?.id == selectedID }?.change }

    private static let sep = "␟"
    private static let jjTemplate = [
        "change_id.short(8)", "commit_id.short(10)", "description.first_line()", "author.email()",
        "committer.timestamp().ago()", "bookmarks.join(\" \")", "if(current_working_copy, \"@\")",
        "if(empty, \"empty\")", "if(conflict, \"conflict\")", "if(immutable, \"immutable\")",
    ].map { "\"\(sep)\" ++ \($0)" }.joined(separator: " ++ ") + " ++ \"\\n\""

    func refresh(kind: VCSKind) async {
        self.kind = kind
        UserDefaults.standard.set(revset, forKey: "scm.revset")
        switch kind {
        case .jj: await refreshJJ()
        case .git: await refreshGit()
        case .none: rows = []
        }
        if let id = selectedID, rows.contains(where: { $0.change?.id == id }) { await loadSelectedFiles() } else { selectedFiles = [] }
    }

    private func refreshJJ() async {
        var args = ["log", "--color", "never", "--limit", "300", "-T", Self.jjTemplate]
        if !revset.isEmpty { args += ["-r", revset] }
        do {
            let out = try await Shell.output("jj", args, cwd: root)
            rows = parseGraph(out) { fields in
                guard fields.count >= 10 else { return nil }
                return Change(changeId: fields[0], commitId: fields[1], description: fields[2], author: fields[3], ago: fields[4],
                              bookmarks: fields[5].split(separator: " ").map(String.init), isWorkingCopy: fields[6] == "@",
                              isEmpty: fields[7] == "empty", hasConflict: fields[8] == "conflict", isImmutable: fields[9] == "immutable")
            }
            lastError = nil
        } catch {
            lastError = error.localizedDescription
        }
        workingCopy = rows.compactMap(\.change).first { $0.isWorkingCopy }
        if workingCopy == nil, let wc = try? await Shell.output("jj", ["log", "--no-graph", "--color", "never", "-r", "@", "-T", Self.jjTemplate], cwd: root) {
            workingCopy = parseGraph(wc) { f in
                f.count >= 10 ? Change(changeId: f[0], commitId: f[1], description: f[2], author: f[3], ago: f[4], bookmarks: [],
                                       isWorkingCopy: true, isEmpty: f[7] == "empty", hasConflict: f[8] == "conflict", isImmutable: false) : nil
            }.first?.change
        }
        if !focusDescription { await loadDescription() }
        workingCopyFiles = parseSummary((try? await Shell.output("jj", ["diff", "--summary", "--color", "never", "-r", "@"], cwd: root)) ?? "")
    }

    func loadDescription() async {
        guard kind == .jj else { return }
        if let d = try? await Shell.output("jj", ["log", "--no-graph", "--color", "never", "-r", "@", "-T", "description"], cwd: root) {
            descriptionDraft = d.trimmingCharacters(in: .whitespacesAndNewlines)
        }
    }

    private func refreshGit() async {
        let fmt = ["%H", "%h", "%s", "%ae", "%ar", "%D"].map { Self.sep + $0 }.joined() + "%n"
        do {
            let out = try await Shell.output("git", ["log", "--graph", "--color=never", "-n", "300", "--format=\(fmt)"] + (revset.isEmpty ? ["--all"] : revset.split(separator: " ").map(String.init)), cwd: root)
            let head = (try? await Shell.output("git", ["rev-parse", "HEAD"], cwd: root))?.trimmingCharacters(in: .whitespacesAndNewlines)
            rows = parseGraph(out) { f in
                guard f.count >= 6 else { return nil }
                let refs = f[5].split(separator: ",").map { $0.trimmingCharacters(in: .whitespaces) }.filter { !$0.isEmpty }
                return Change(changeId: "", commitId: f[1], description: f[2], author: f[3], ago: f[4], bookmarks: refs,
                              isWorkingCopy: f[0] == head, isEmpty: false, hasConflict: false, isImmutable: false)
            }
            lastError = nil
        } catch {
            lastError = error.localizedDescription
        }
        workingCopy = nil
        let status = (try? await Shell.output("git", ["status", "--porcelain"], cwd: root)) ?? ""
        workingCopyFiles = status.split(separator: "\n").map { l in
            let s = String(l.prefix(2)).trimmingCharacters(in: .whitespaces)
            return FileStatus(status: s == "??" ? "A" : String(s.prefix(1)), path: String(l.dropFirst(3)))
        }
    }

    private func parseGraph(_ out: String, _ make: ([String]) -> Change?) -> [GraphRow] {
        var rows: [GraphRow] = []
        for (i, line) in out.split(separator: "\n", omittingEmptySubsequences: false).enumerated() where !line.isEmpty {
            let parts = line.components(separatedBy: Self.sep)
            if parts.count > 1 {
                rows.append(GraphRow(id: i, graph: parts[0], change: make(Array(parts.dropFirst()))))
            } else {
                rows.append(GraphRow(id: i, graph: String(line), change: nil))
            }
        }
        return rows
    }

    private func parseSummary(_ out: String) -> [FileStatus] {
        out.split(separator: "\n").compactMap { l in
            let parts = l.split(separator: " ", maxSplits: 1)
            guard parts.count == 2 else { return nil }
            var path = String(parts[1])
            // Renames print as "dir/{old => new}"; keep the new path.
            if let open = path.firstIndex(of: "{"), let arrow = path.range(of: " => "), let close = path.firstIndex(of: "}") {
                path = String(path[..<open]) + String(path[arrow.upperBound..<close]) + String(path[path.index(after: close)...])
            }
            return FileStatus(status: String(parts[0]), path: path)
        }
    }

    func select(_ change: Change?) async {
        selectedID = change?.id
        await loadSelectedFiles()
    }

    private func loadSelectedFiles() async {
        guard let c = selected else { selectedFiles = []; return }
        switch kind {
        case .jj:
            selectedFiles = parseSummary((try? await Shell.output("jj", ["diff", "--summary", "--color", "never", "-r", c.rev], cwd: root)) ?? "")
        case .git:
            let out = (try? await Shell.output("git", ["show", "--name-status", "--format=", c.commitId], cwd: root)) ?? ""
            selectedFiles = out.split(separator: "\n").compactMap { l in
                let p = l.split(separator: "\t")
                return p.count >= 2 ? FileStatus(status: String(p[0].prefix(1)), path: String(p.last!)) : nil
            }
        case .none: selectedFiles = []
        }
    }

    /// Runs a jj command, then refreshes. Returns false and records the error on failure.
    @discardableResult
    func run(_ args: [String], label: String? = nil) async -> Bool {
        guard kind == .jj else { lastError = "Source control actions need jj"; return false }
        busy = label ?? "jj " + args.joined(separator: " ")
        defer { busy = nil }
        do {
            let r = try await Shell.run("jj", args + ["--color", "never"], cwd: root)
            guard r.ok else { lastError = r.stderr.trimmingCharacters(in: .whitespacesAndNewlines); await refresh(kind: kind); return false }
            let msg = (r.stderr + r.stdout).trimmingCharacters(in: .whitespacesAndNewlines)
            lastOutput = msg.isEmpty ? "Ran jj \(args.first ?? "")" : msg
            lastError = nil
        } catch {
            lastError = error.localizedDescription
            return false
        }
        await refresh(kind: kind)
        return true
    }

    func describeWorkingCopy() async {
        focusDescription = false
        await run(["describe", "-r", "@", "-m", descriptionDraft], label: "Describing @")
    }

    func commit() async {
        focusDescription = false
        await run(["commit", "-m", descriptionDraft], label: "Committing @")
        await loadDescription()
    }
}
