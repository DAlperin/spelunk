import Foundation

/// One commit's slice of the history graph: which lanes pass through its row, which lines meet at
/// its node, and where its parent edges leave the row. Lanes keep their column for their whole
/// length, so consecutive rows join up when each is drawn to its full height.
struct GraphLayout: Hashable, Sendable {
    struct Edge: Hashable, Sendable {
        var lane: Int
        /// The parent is reached through commits the log does not show.
        var elided: Bool
    }

    /// The node's lane.
    var node: Int
    /// A line arrives at the node from the row above.
    var incoming: Bool
    /// Lanes from above that end at this node (other children of the same commit).
    var merges: [Int]
    /// Lanes that run past this row.
    var through: [Int]
    /// Edges from the node to its parents' lanes in the row below.
    var outgoing: [Edge]
    /// Parents nowhere in the log: drawn as a short dashed stub.
    var stub: Bool
    /// Columns this row uses.
    var width: Int
}

enum CommitGraph {
    struct Node: Sendable {
        var id: String
        /// Parent ids, each marked when reached through commits outside the log.
        var parents: [(id: String, elided: Bool)]
    }

    /// Lays out commits given newest first (each before its parents).
    static func layout(_ nodes: [Node]) -> [GraphLayout] {
        let visible = Set(nodes.map(\.id))
        var lanes: [String?] = []
        var out: [GraphLayout] = []

        func freeSlot(avoiding: Int? = nil) -> Int {
            if let i = lanes.indices.first(where: { lanes[$0] == nil && $0 != avoiding }) { return i }
            lanes.append(nil)
            return lanes.count - 1
        }

        for n in nodes {
            let hits = lanes.indices.filter { lanes[$0] == n.id }
            let node = hits.first ?? freeSlot()
            let merges = Array(hits.dropFirst())
            for m in merges { lanes[m] = nil }
            lanes[node] = nil
            let through = lanes.indices.filter { lanes[$0] != nil }

            var outgoing: [GraphLayout.Edge] = []
            var stub = false
            for p in n.parents {
                guard visible.contains(p.id) else { stub = true; continue }
                if let existing = lanes.firstIndex(where: { $0 == p.id }) {
                    outgoing.append(.init(lane: existing, elided: p.elided))
                } else if lanes[node] == nil {
                    lanes[node] = p.id
                    outgoing.append(.init(lane: node, elided: p.elided))
                } else {
                    let slot = freeSlot(avoiding: node)
                    lanes[slot] = p.id
                    outgoing.append(.init(lane: slot, elided: p.elided))
                }
            }
            let width = ([node] + merges + through + outgoing.map(\.lane)).max().map { $0 + 1 } ?? 1
            out.append(GraphLayout(node: node, incoming: !hits.isEmpty, merges: merges, through: through,
                                   outgoing: outgoing, stub: stub && outgoing.isEmpty, width: width))
            while let last = lanes.last, last == nil { lanes.removeLast() }
        }
        return out
    }
}
