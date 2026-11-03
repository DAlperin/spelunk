import Foundation

extension ReviewSession {
    /// A directory where the code reads as it does after the change, for model sessions that browse
    /// the repository. The working copy when it is the change's head; otherwise a detached git
    /// worktree at the head commit, kept per commit (the three most recent) under Application Support.
    /// Throws when the head cannot be checked out; callers must not quietly read another version.
    func headCheckout() async throws -> URL {
        if afterIsWorkingCopy { return root }
        if let made = await worktreeAtHead() { return made }
        throw ClaudeError(message: "Could not check out the head of \(title) (\(newRev.flatMap { $0.isEmpty ? nil : $0 } ?? "its commits are not available locally")).")
    }

    /// The change's full diff as a file outside the repository, for sessions given read access to it.
    func fullDiffFile() -> URL {
        let u = AppPaths.support(for: root).appendingPathComponent("review-diffs/\(String(UInt(bitPattern: target.key.stableHash), radix: 36)).diff")
        try? FileManager.default.createDirectory(at: u.deletingLastPathComponent(), withIntermediateDirectories: true)
        try? fullDiffText.write(to: u, atomically: true, encoding: .utf8)
        return u
    }

    /// True when `headCheckout()` is a separate tree rather than the working copy.
    var headIsSeparateCheckout: Bool { !afterIsWorkingCopy }

    var fullDiffText: String {
        files.map { f in
            "diff --git a/\(f.oldPath) b/\(f.newPath)\n--- a/\(f.oldPath)\n+++ b/\(f.newPath)\n" + f.hunks.map { h in
                "@@ -\(h.oldStart),\(h.oldCount) +\(h.newStart),\(h.newCount) @@ \(h.header)\n"
                    + h.lines.map { ($0.kind == .added ? "+" : $0.kind == .removed ? "-" : " ") + $0.text }.joined(separator: "\n")
            }.joined(separator: "\n")
        }.joined(separator: "\n")
    }

    /// One checkout per directory at a time: concurrent callers share the same in-flight work.
    @MainActor private static var inflight: [String: Task<URL?, Never>] = [:]

    private func worktreeAtHead() async -> URL? {
        guard let rev = newRev, !rev.isEmpty else { return nil }
        let key = root.path + "\u{1}" + rev
        if let t = Self.inflight[key] { return await t.value }
        let t = Task { await makeWorktreeAtHead() }
        Self.inflight[key] = t
        let r = await t.value
        Self.inflight[key] = nil
        return r
    }

    private func makeWorktreeAtHead() async -> URL? {
        guard let rev = newRev, !rev.isEmpty else { return nil }
        var commit = rev
        if FileManager.default.fileExists(atPath: root.appendingPathComponent(".jj").path),
           let id = try? await Shell.output("jj", ["log", "--no-graph", "--ignore-working-copy", "-r", rev, "-T", "commit_id"], cwd: root) {
            commit = id.trimmingCharacters(in: .whitespacesAndNewlines)
        }
        guard !commit.isEmpty else { return nil }
        let base = AppPaths.support(for: root).appendingPathComponent("checkouts", isDirectory: true)
        let dir = base.appendingPathComponent(String(commit.prefix(12)), isDirectory: true)
        let fm = FileManager.default
        if fm.fileExists(atPath: dir.appendingPathComponent(".git").path) {
            try? fm.setAttributes([.modificationDate: Date()], ofItemAtPath: dir.path)
            return dir
        }
        try? fm.createDirectory(at: base, withIntermediateDirectories: true)
        ruleState = "Checking out \(commit.prefix(8)) for Claude"
        defer { ruleState = nil }
        guard let r = try? await Shell.run("git", ["worktree", "add", "--detach", "--force", dir.path, commit], cwd: root), r.ok else { return nil }
        // Keep the three most recently used checkouts.
        let existing = ((try? fm.contentsOfDirectory(at: base, includingPropertiesForKeys: [.contentModificationDateKey])) ?? [])
            .sorted { a, b in
                let da = (try? a.resourceValues(forKeys: [.contentModificationDateKey]).contentModificationDate) ?? .distantPast
                let db = (try? b.resourceValues(forKeys: [.contentModificationDateKey]).contentModificationDate) ?? .distantPast
                return da > db
            }
        for old in existing.dropFirst(3) where old != dir {
            _ = try? await Shell.run("git", ["worktree", "remove", "--force", old.path], cwd: root)
        }
        return dir
    }
}
