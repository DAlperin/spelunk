import Foundation

/// One commit inside a review's range, oldest first.
struct RangeCommit: Identifiable, Hashable, Sendable {
    var id: String
    var short: String
    var title: String
    var author: String
}

extension ReviewSession {
    /// The commits between the review's base and head, oldest first, from jj for jj reviews and git
    /// otherwise. Empty when the range has a single commit or its commits are not available locally.
    func loadRangeCommits() async {
        guard !oldRev.isEmpty, newRev != "" else { rangeCommits = []; return }
        var out: [RangeCommit] = []
        if vcs == .jj {
            let to = newRev ?? (showsParent ? "@-" : "@")
            let t = #"commit_id ++ "\t" ++ change_id.short(8) ++ "\t" ++ description.first_line() ++ "\t" ++ author.name() ++ "\n""#
            let text = (try? await Shell.output("jj", ["log", "--no-graph", "--ignore-working-copy", "--color", "never",
                                                       "-r", "\(oldRev)..\(to)", "-T", t], cwd: root)) ?? ""
            for line in text.split(separator: "\n").reversed() {
                let f = line.split(separator: "\t", omittingEmptySubsequences: false).map(String.init)
                guard f.count >= 4 else { continue }
                out.append(RangeCommit(id: f[0], short: f[1], title: f[2].isEmpty ? "(no description)" : f[2], author: f[3]))
            }
        } else {
            let head = newRev ?? "HEAD"
            let text = (try? await Shell.output("git", ["log", "--reverse", "--first-parent", "--format=%H%x09%h%x09%s%x09%an",
                                                        "\(oldRev)..\(head)"], cwd: root)) ?? ""
            for line in text.split(separator: "\n") {
                let f = line.split(separator: "\t", omittingEmptySubsequences: false).map(String.init)
                guard f.count >= 4 else { continue }
                out.append(RangeCommit(id: f[0], short: f[1], title: f[2], author: f[3]))
            }
        }
        rangeCommits = out.count > 1 ? out : []
        if let c = selectedCommit, !rangeCommits.contains(where: { $0.id == c }) { selectedCommit = nil }
    }

    /// The diff of one commit against its first parent; the review's revisions become that pair.
    func commitDiff(_ commit: String) async throws -> String {
        if vcs == .jj {
            let parent = try await Shell.output("jj", ["log", "--no-graph", "--ignore-working-copy", "-r", "\(commit)-", "-T", "commit_id ++ \"\\n\""], cwd: root)
                .split(separator: "\n").first.map(String.init) ?? ""
            oldRev = parent
            newRev = commit
            return try await Shell.output("jj", ["diff", "--git", "--context", "3"] + Self.jjWhitespace + ["--from", parent, "--to", commit], cwd: root)
        }
        let parent = try await Shell.output("git", ["rev-parse", "\(commit)^"], cwd: root).trimmingCharacters(in: .whitespacesAndNewlines)
        oldRev = parent
        newRev = commit
        return try await Shell.output("git", ["diff", "--no-color", "--no-ext-diff"] + Self.gitWhitespace + [parent, commit], cwd: root)
    }

    /// Shows one commit of the range, or the whole range with nil.
    func selectCommit(_ id: String?) {
        guard selectedCommit != id else { return }
        selectedCommit = id
        Task { await load() }
    }

    /// Steps to the previous or next commit; past either end returns to the whole range.
    func stepCommit(_ d: Int) {
        guard !rangeCommits.isEmpty else { return }
        let i = selectedCommit.flatMap { c in rangeCommits.firstIndex { $0.id == c } }
        let next: Int? = switch (i, d > 0) {
        case (nil, true): 0
        case (nil, false): rangeCommits.count - 1
        case (let i?, _): i + d
        }
        selectCommit(next.flatMap { rangeCommits.indices.contains($0) ? rangeCommits[$0].id : nil })
    }

    var selectedCommitInfo: RangeCommit? { selectedCommit.flatMap { c in rangeCommits.first { $0.id == c } } }
}
