import Foundation

/// A second rust-analyzer rooted in a review head's worktree, so symbols in head documents are
/// answered about the head itself rather than mapped onto the working copy.
@MainActor
final class HeadIntel {
    let root: URL
    let server: LanguageServer
    let hub: IntelHub
    let version: CodeVersion

    init(root: URL, version: CodeVersion) {
        self.root = root
        self.version = version
        server = LanguageServer(root: root, spec: .rust)
        hub = IntelHub(root: root, ra: server, servers: [server], scip: SCIPService(root: root), docs: DocumentCache(root: root))
        server.start()
    }

    var ready: Bool { server.status.isUsable }

    func stop() { server.stop() }
}

extension ReviewSession {
    /// Starts the head's own rust-analyzer (once). Its first index takes as long as the working copy's.
    func startHeadIntel() async {
        guard headIntel == nil, !afterIsWorkingCopy else { return }
        do {
            let dir = try await headCheckout()
            headIntel = HeadIntel(root: dir, version: headVersion)
        } catch {
            ruleState = nil
            githubError = error.localizedDescription
        }
    }

    func stopHeadIntel() {
        headIntel?.stop()
        headIntel = nil
    }
}

extension Workspace {
    /// Where to ask about a symbol in a document: the review head's own rust-analyzer at the exact
    /// position when it is running for that head, otherwise the working copy's intelligence at the
    /// mapped position.
    func intelTarget(_ d: SourceDocument, name: String, range: SourceRange) -> (hub: IntelHub, pos: SourcePos, version: CodeVersion?) {
        if !d.isWorkingCopy, let r = review, let h = r.headIntel, h.ready, d.version == h.version, h.server.spec.handles(d.path) {
            return (h.hub, range.start, h.version)
        }
        return (intel, intelPosition(in: d, name: name, range: range), nil)
    }

    /// Marks a location from a head's intelligence as belonging to that head; files outside the
    /// repository are the same in every version.
    nonisolated static func tagged(_ l: CodeLocation, _ v: CodeVersion?) -> CodeLocation {
        guard let v, l.version == nil, !l.path.hasPrefix("/") else { return l }
        var c = l
        c.version = v
        return c
    }

    func tag(_ nodes: [CallNode], _ v: CodeVersion?, hub: IntelHub) {
        guard v != nil else { return }
        for n in nodes {
            n.location = Self.tagged(n.location, v)
            n.callSites = n.callSites.map { Self.tagged($0, v) }
            n.hub = hub
            n.version = v
            if let c = n.children { tag(c, v, hub: hub) }
        }
    }

    /// Expands a call tree node with the intelligence that produced it.
    func expand(_ node: CallNode, _ direction: CallDirection) async {
        let hub = node.hub ?? intel
        await hub.expand(node, direction)
        if let c = node.children { tag(c, node.version, hub: hub) }
    }
}
