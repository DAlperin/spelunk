import Foundation

extension ReviewSession {
    /// For a local review (jj change or git branch), finds the open pull request whose head branch is
    /// a bookmark on the reviewed change and attaches its threads, checks and review composer. The
    /// diff stays local.
    func linkPullRequest() async {
        guard github != nil, linkedPR == nil else { return }
        if case .githubPR = target { return }
        var names: [String] = []
        switch target {
        case .jj(_, let to):
            let revs = to
            let out = (try? await Shell.output("jj", ["log", "--no-graph", "--ignore-working-copy", "-r", revs, "-T", "local_bookmarks.map(|b| b.name()).join(\"\\n\") ++ \"\\n\""], cwd: root)) ?? ""
            names = out.split(separator: "\n").map(String.init).filter { !$0.isEmpty }
        case .git(_, let head):
            let ref = head ?? "HEAD"
            if let b = try? await Shell.output("git", ["rev-parse", "--abbrev-ref", ref], cwd: root) {
                let n = b.trimmingCharacters(in: .whitespacesAndNewlines)
                if n != "HEAD" && !n.isEmpty { names = [n] }
            }
        case .githubPR:
            return
        }
        for name in names {
            guard let json = try? await Shell.output("gh", ["pr", "list", "--head", name, "--state", "open", "--json", "number,headRefOid", "--limit", "1"], cwd: root),
                  let arr = try? JSONSerialization.jsonObject(with: Data(json.utf8)) as? [[String: Any]],
                  let pr = arr.first, let n = pr["number"] as? Int else { continue }
            linkedPR = n
            linkedBookmark = name
            linkedPRHead = pr["headRefOid"] as? String
            await refreshPullRequest(n)
            await checkLinkedHead()
            return
        }
    }

    /// Whether the reviewed code is what the pull request has pushed; review comments anchor to the
    /// pushed head, so line numbers can drift when the local change is ahead.
    func checkLinkedHead() async {
        guard let head = linkedPRHead else { return }
        var local: String?
        switch target {
        case .jj(_, let to):
            let rev = to == "@" ? "@-" : to
            local = try? await Shell.output("jj", ["log", "--no-graph", "--ignore-working-copy", "-r", rev, "-T", "commit_id"], cwd: root)
            if to == "@", tracksWorkingCopy {
                let empty = (try? await Shell.output("jj", ["log", "--no-graph", "--ignore-working-copy", "-r", "@", "-T", "if(empty, \"1\", \"0\")"], cwd: root))?
                    .trimmingCharacters(in: .whitespacesAndNewlines) == "1"
                if !empty { local = try? await Shell.output("jj", ["log", "--no-graph", "--ignore-working-copy", "-r", "@", "-T", "commit_id"], cwd: root) }
            }
        case .git(_, let h):
            local = try? await Shell.output("git", ["rev-parse", h ?? "HEAD"], cwd: root)
        case .githubPR:
            return
        }
        linkedInSync = local?.trimmingCharacters(in: .whitespacesAndNewlines) == head
    }
}
