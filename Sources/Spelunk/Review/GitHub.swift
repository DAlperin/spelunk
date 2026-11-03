import Foundation
import Observation

/// GitHub access through the `gh` CLI, which supplies authentication. Reads use REST and GraphQL;
/// writes (reviews, replies, resolving threads) happen only from explicit user actions.
@MainActor @Observable
final class GitHubService {
    let root: URL
    var repo: String?
    var login: String?
    var problem: String?
    private var resolved = false

    init(root: URL) { self.root = root }

    struct PullRequestSummary: Identifiable, Decodable, Hashable {
        struct Author: Decodable, Hashable { var login: String }
        struct Check: Decodable, Hashable {
            var conclusion: String?
            var status: String?
            var state: String?
        }
        var number: Int
        var title: String
        var author: Author?
        var updatedAt: String
        var isDraft: Bool
        var headRefName: String
        var additions: Int
        var deletions: Int
        var reviewDecision: String?
        var url: String
        var id: Int { number }
    }

    enum PRFilter: String, CaseIterable, Identifiable {
        case reviewRequested = "Review requested"
        case mine = "Mine"
        case all = "All open"
        var id: String { rawValue }
        var search: String {
            switch self {
            case .reviewRequested: "review-requested:@me"
            case .mine: "author:@me"
            case .all: ""
            }
        }
    }

    func ensureRepo() async -> String? {
        if resolved { return repo }
        resolved = true
        guard Shell.which("gh") != nil else { problem = "gh CLI not found"; return nil }
        let r = try? await Shell.run("gh", ["repo", "view", "--json", "nameWithOwner", "-q", ".nameWithOwner"], cwd: root)
        if let r, r.ok { repo = r.stdout.trimmingCharacters(in: .whitespacesAndNewlines) } else {
            problem = r?.stderr.split(separator: "\n").first.map(String.init) ?? "Could not determine GitHub repository"
        }
        login = (try? await Shell.output("gh", ["api", "user", "-q", ".login"], cwd: root))?.trimmingCharacters(in: .whitespacesAndNewlines)
        return repo
    }

    func listPullRequests(_ filter: PRFilter, query: String) async throws -> [PullRequestSummary] {
        _ = await ensureRepo()
        // Check runs are left out: on large repositories, fetching every run for a page of pull
        // requests times out at GitHub. `checkStates` fetches just the rollup state afterwards.
        var args = ["pr", "list", "-L", "60", "--json",
                    "number,title,author,updatedAt,isDraft,headRefName,additions,deletions,reviewDecision,url"]
        let search = [filter.search, query].filter { !$0.isEmpty }.joined(separator: " ")
        if !search.isEmpty { args += ["--search", search] }
        let out = try await Shell.output("gh", args, cwd: root, timeout: 60)
        return try JSONDecoder().decode([PullRequestSummary].self, from: Data(out.utf8))
    }

    /// The combined check state (SUCCESS, FAILURE, PENDING, ...) of each pull request's head commit,
    /// in one GraphQL request.
    func checkStates(_ numbers: [Int]) async -> [Int: String] {
        guard let repo = await ensureRepo(), !numbers.isEmpty else { return [:] }
        let parts = repo.split(separator: "/").map(String.init)
        guard parts.count == 2 else { return [:] }
        let fields = numbers.map { "p\($0): pullRequest(number: \($0)) { commits(last: 1) { nodes { commit { statusCheckRollup { state } } } } }" }
        let q = "query($owner: String!, $name: String!) { repository(owner: $owner, name: $name) { \(fields.joined(separator: " ")) } }"
        let out: String
        do {
            out = try await Shell.output("gh", ["api", "graphql", "-F", "owner=\(parts[0])", "-F", "name=\(parts[1])", "-f", "query=\(q)"],
                                         cwd: root, timeout: 60)
        } catch {
            Log.debug("checkStates: \(error.localizedDescription.prefix(300))")
            return [:]
        }
        guard let obj = try? JSONSerialization.jsonObject(with: Data(out.utf8)) as? [String: Any],
              let r = (obj["data"] as? [String: Any])?["repository"] as? [String: Any] else { return [:] }
        var result: [Int: String] = [:]
        for n in numbers {
            let pr = r["p\(n)"] as? [String: Any]
            let commit = (((pr?["commits"] as? [String: Any])?["nodes"] as? [[String: Any]])?.first?["commit"]) as? [String: Any]
            if let state = (commit?["statusCheckRollup"] as? [String: Any])?["state"] as? String { result[n] = state }
        }
        return result
    }

    // MARK: Pull request details

    struct ThreadComment: Identifiable, Hashable, Sendable {
        var id: Int
        var author: String
        var body: String
        var createdAt: String
        var url: String
    }

    struct ReviewThread: Identifiable, Hashable, Sendable {
        var id: String
        var path: String
        var line: Int?
        var originalLine: Int?
        var startLine: Int?
        var side: String
        var isResolved: Bool
        var isOutdated: Bool
        var comments: [ThreadComment]
        /// 1-based line in the file version the thread's side refers to.
        var anchorLine: Int? { line ?? originalLine }
    }

    struct Check: Identifiable, Hashable, Sendable {
        var name: String
        var state: String
        var url: String?
        var id: String { name + (url ?? "") }
        var isFailure: Bool { ["FAILURE", "ERROR", "TIMED_OUT", "CANCELLED", "ACTION_REQUIRED", "STARTUP_FAILURE"].contains(state) }
        var isPending: Bool { ["PENDING", "QUEUED", "IN_PROGRESS", "EXPECTED", "WAITING", ""].contains(state) }
    }

    struct ReviewSummary: Hashable, Sendable {
        var author: String
        var state: String
    }

    struct PullRequestDetails: Sendable {
        var number: Int
        var title: String
        var url: String
        var state: String
        var isDraft: Bool
        var reviewDecision: String?
        var headSha: String
        var baseRef: String
        var headRef: String
        var author: String
        var checksState: String?
        var checks: [Check]
        var reviews: [ReviewSummary]
        var threads: [ReviewThread]
    }

    private static let detailsQuery = """
    query($owner:String!,$name:String!,$number:Int!){ repository(owner:$owner,name:$name){ pullRequest(number:$number){
      number title url state isDraft reviewDecision headRefOid baseRefName headRefName author{login}
      commits(last:1){ nodes{ commit{ statusCheckRollup{ state contexts(first:100){ nodes{ __typename
        ... on CheckRun{ name conclusion status detailsUrl } ... on StatusContext{ context state targetUrl } } } } } } }
      reviews(last:50){ nodes{ author{login} state } }
      reviewThreads(first:100){ nodes{ id isResolved isOutdated path line originalLine startLine diffSide
        comments(first:50){ nodes{ databaseId author{login} body createdAt url } } } }
    } } }
    """

    func details(_ number: Int) async throws -> PullRequestDetails {
        guard let repo = await ensureRepo() else { throw ClaudeError(message: problem ?? "No GitHub repository") }
        let parts = repo.split(separator: "/").map(String.init)
        let out = try await Shell.output("gh", ["api", "graphql", "-F", "owner=\(parts[0])", "-F", "name=\(parts[1])",
                                                "-F", "number=\(number)", "-f", "query=\(Self.detailsQuery)"], cwd: root)
        guard let obj = try JSONSerialization.jsonObject(with: Data(out.utf8)) as? [String: Any],
              let pr = ((obj["data"] as? [String: Any])?["repository"] as? [String: Any])?["pullRequest"] as? [String: Any] else {
            throw ClaudeError(message: "Unexpected GraphQL response")
        }
        func nodes(_ any: Any?) -> [[String: Any]] { ((any as? [String: Any])?["nodes"] as? [[String: Any]]) ?? [] }
        let rollup = nodes(pr["commits"]).first.flatMap { ($0["commit"] as? [String: Any])?["statusCheckRollup"] as? [String: Any] }
        let checks: [Check] = nodes(rollup?["contexts"]).map { c in
            if c["__typename"] as? String == "CheckRun" {
                let status = c["status"] as? String ?? ""
                let state = status == "COMPLETED" ? (c["conclusion"] as? String ?? "") : status
                return Check(name: c["name"] as? String ?? "?", state: state, url: c["detailsUrl"] as? String)
            }
            return Check(name: c["context"] as? String ?? "?", state: c["state"] as? String ?? "", url: c["targetUrl"] as? String)
        }
        let threads: [ReviewThread] = nodes(pr["reviewThreads"]).map { t in
            ReviewThread(
                id: t["id"] as? String ?? UUID().uuidString, path: t["path"] as? String ?? "",
                line: t["line"] as? Int, originalLine: t["originalLine"] as? Int, startLine: t["startLine"] as? Int,
                side: t["diffSide"] as? String ?? "RIGHT", isResolved: t["isResolved"] as? Bool ?? false,
                isOutdated: t["isOutdated"] as? Bool ?? false,
                comments: nodes(t["comments"]).map { c in
                    ThreadComment(id: c["databaseId"] as? Int ?? 0, author: (c["author"] as? [String: Any])?["login"] as? String ?? "ghost",
                                  body: c["body"] as? String ?? "", createdAt: c["createdAt"] as? String ?? "", url: c["url"] as? String ?? "")
                })
        }
        return PullRequestDetails(
            number: pr["number"] as? Int ?? number, title: pr["title"] as? String ?? "", url: pr["url"] as? String ?? "",
            state: pr["state"] as? String ?? "", isDraft: pr["isDraft"] as? Bool ?? false,
            reviewDecision: pr["reviewDecision"] as? String, headSha: pr["headRefOid"] as? String ?? "",
            baseRef: pr["baseRefName"] as? String ?? "", headRef: pr["headRefName"] as? String ?? "",
            author: (pr["author"] as? [String: Any])?["login"] as? String ?? "",
            checksState: rollup?["state"] as? String, checks: checks,
            reviews: nodes(pr["reviews"]).map { ReviewSummary(author: ($0["author"] as? [String: Any])?["login"] as? String ?? "", state: $0["state"] as? String ?? "") },
            threads: threads)
    }

    // MARK: Writes

    enum ReviewEvent: String, CaseIterable, Identifiable {
        case comment = "COMMENT", approve = "APPROVE", requestChanges = "REQUEST_CHANGES"
        var id: String { rawValue }
        var label: String {
            switch self {
            case .comment: "Comment"
            case .approve: "Approve"
            case .requestChanges: "Request changes"
            }
        }
    }

    func submitReview(number: Int, commitId: String, event: ReviewEvent, body: String, comments: [PendingComment]) async throws {
        guard let repo = await ensureRepo() else { throw ClaudeError(message: problem ?? "No GitHub repository") }
        var payload: [String: Any] = ["commit_id": commitId, "event": event.rawValue]
        if !body.isEmpty { payload["body"] = body }
        payload["comments"] = comments.map { c -> [String: Any] in
            var d: [String: Any] = ["path": c.path, "line": c.line, "side": c.side, "body": c.body]
            if let s = c.startLine, s < c.line { d["start_line"] = s; d["start_side"] = c.side }
            return d
        }
        try await post("repos/\(repo)/pulls/\(number)/reviews", payload)
    }

    /// Posts one line comment immediately, outside any review.
    func postComment(number: Int, commitId: String, comment c: PendingComment) async throws {
        guard let repo = await ensureRepo() else { throw ClaudeError(message: problem ?? "No GitHub repository") }
        var d: [String: Any] = ["commit_id": commitId, "path": c.path, "line": c.line, "side": c.side, "body": c.body]
        if let s = c.startLine, s < c.line { d["start_line"] = s; d["start_side"] = c.side }
        try await post("repos/\(repo)/pulls/\(number)/comments", d)
    }

    func reply(number: Int, to commentId: Int, body: String) async throws {
        guard let repo = await ensureRepo() else { throw ClaudeError(message: problem ?? "No GitHub repository") }
        try await post("repos/\(repo)/pulls/\(number)/comments/\(commentId)/replies", ["body": body])
    }

    func setResolved(threadId: String, _ resolved: Bool) async throws {
        let m = resolved ? "resolveReviewThread" : "unresolveReviewThread"
        let q = "mutation($id:ID!){ \(m)(input:{threadId:$id}){ thread{ isResolved } } }"
        _ = try await Shell.output("gh", ["api", "graphql", "-F", "id=\(threadId)", "-f", "query=\(q)"], cwd: root)
    }

    private func post(_ endpoint: String, _ payload: [String: Any]) async throws {
        let data = try JSONSerialization.data(withJSONObject: payload)
        let r = try await Shell.run("gh", ["api", "-X", "POST", endpoint, "--input", "-"], cwd: root, stdin: String(decoding: data, as: UTF8.self))
        guard r.ok else {
            let msg = (try? JSONSerialization.jsonObject(with: Data(r.stdout.utf8)) as? [String: Any]).flatMap { obj -> String? in
                let errors = (obj["errors"] as? [Any])?.map { "\($0)" }.joined(separator: "; ")
                return [obj["message"] as? String, errors].compactMap { $0 }.joined(separator: ": ")
            }
            throw ClaudeError(message: "GitHub: \(msg ?? r.stderr)")
        }
    }

    // MARK: Links

    /// A link to `path:line` at a commit GitHub has. Uses HEAD when a remote branch contains it,
    /// otherwise the merge-base with the remote default branch (lines may then differ from the working copy).
    func permalink(path: String, line: Int) async -> String? {
        guard let repo = await ensureRepo() else { return nil }
        let head = (try? await Shell.output("git", ["rev-parse", "HEAD"], cwd: root))?.trimmingCharacters(in: .whitespacesAndNewlines)
        var sha = head
        if let h = head, let contains = try? await Shell.output("git", ["branch", "-r", "--contains", h], cwd: root),
           contains.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
            for base in ["origin/HEAD", "upstream/HEAD", "origin/main", "upstream/main"] {
                if let mb = try? await Shell.output("git", ["merge-base", h, base], cwd: root) {
                    sha = mb.trimmingCharacters(in: .whitespacesAndNewlines)
                    break
                }
            }
        }
        guard let sha, !sha.isEmpty else { return nil }
        return "https://github.com/\(repo)/blob/\(sha)/\(path)#L\(line)"
    }
}

/// A review comment drafted locally, submitted with the next GitHub review.
struct PendingComment: Codable, Identifiable, Hashable, Sendable {
    var id = UUID()
    var path: String
    /// 1-based line in the side's file version.
    var line: Int
    var startLine: Int?
    /// "RIGHT" for the new version, "LEFT" for the old.
    var side: String
    var body: String
    /// The pull request and head commit the draft was written against.
    var prNumber: Int?
    var commitId: String?
}
