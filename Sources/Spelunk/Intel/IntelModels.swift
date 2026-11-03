import Foundation
import Observation

enum IntelSource: String, Codable, Sendable, CaseIterable {
    case rustAnalyzer, sourceKit, scip, treeSitter, textSearch, claude, manual

    var label: String {
        switch self {
        case .rustAnalyzer: "rust-analyzer"
        case .sourceKit: "sourcekit-lsp"
        case .scip: "SCIP"
        case .treeSitter: "tree-sitter"
        case .textSearch: "text search"
        case .claude: "Claude"
        case .manual: "manual"
        }
    }

    /// Precision rank; higher wins when providers disagree.
    var precision: Int {
        switch self {
        case .rustAnalyzer, .sourceKit: 5
        case .scip: 4
        case .treeSitter: 2
        case .textSearch: 1
        case .claude: 1
        case .manual: 3
        }
    }
}

struct ReferenceHit: Identifiable, Hashable, Sendable {
    var location: CodeLocation
    var preview: String
    var isDefinition: Bool = false
    var enclosing: String?
    var source: IntelSource
    var id: String { location.id }
}

struct SymbolDetails: Sendable {
    var name: String
    var kindLabel: String
    var definition: CodeLocation?
    var signature: String?
    var docs: String?
    var source: IntelSource
}

/// One node in a lazily expanded call tree (callers or callees).
@MainActor @Observable
final class CallNode: Identifiable {
    let id = UUID()
    var name: String
    var detail: String
    var location: CodeLocation
    var callSites: [CodeLocation]
    var source: IntelSource
    var children: [CallNode]?
    var isLoading = false
    var note: String?
    var payload: LSPPayload?
    var isTest = false
    let ancestry: Set<String>

    init(name: String, detail: String, location: CodeLocation, callSites: [CodeLocation], source: IntelSource,
         payload: LSPPayload?, ancestry: Set<String>) {
        self.name = name; self.detail = detail; self.location = location; self.callSites = callSites
        self.source = source; self.payload = payload; self.ancestry = ancestry
    }

    var key: String { "\(location.path)#\(name)" }
    var isRecursive: Bool { ancestry.contains(key) }
}

/// Opaque LSP JSON value carried across actors.
struct LSPPayload: @unchecked Sendable {
    var value: [String: Any]
}

enum CallDirection: String, CaseIterable, Identifiable {
    case incoming = "Callers", outgoing = "Callees"
    var id: String { rawValue }
}
