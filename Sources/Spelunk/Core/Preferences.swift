import Foundation

/// Every user preference: its key and default in one place. Defaults are registered at launch, so
/// Settings (through `@AppStorage` with the same keys) and the code that reads them agree.
enum Prefs {
    enum Key {
        // Editor
        static let fontSize = "fontSize"
        static let lineSpacing = "editor.lineSpacing"
        static let tabWidth = "editor.tabWidth"
        static let minimap = "editor.minimap"
        static let minimapWidth = "editor.minimapWidth"
        static let hunkBoundary = "editor.hunkBoundary"
        static let hoverEnabled = "hover.enabled"
        static let hoverDelay = "hover.delay"
        // Review
        static let autoClassify = "review.autoClassify"
        static let groupRelated = "review.groupRelated"
        static let hideMechanical = "review.hideMechanical"
        static let quickBatch = "review.quickBatch"
        static let groupMaxGroups = "grouping.maxGroups"
        static let groupOverlap = "grouping.overlap"
        static let groupDistinctLength = "grouping.plainWordLength"
        static let refreshDelay = "review.refreshDelay"
        static let autoAttachments = "review.autoAttachments"
        // Claude
        static let claudePath = "claudePath"
        static let claudeConcurrency = "claude.concurrency"
        static let claudeTimeoutMinutes = "claude.timeoutMinutes"
        static let keepJobs = "claude.keepJobs"
        static let cacheDays = "claude.cacheDays"
        // Code intelligence
        static let autoStartServers = "autoStartRA"
        static let rustAnalyzerPath = "rustAnalyzerPath"
        static let sourceKitPath = "sourceKitPath"
        static let scipFirst = "intel.scipFirstWhileCold"
        static let openDocuments = "intel.openDocuments"
        static let documentCacheSize = "intel.documentCacheSize"
        static let headServer = "intel.headServer"
    }

    static let defaults: [String: Any] = [
        Key.fontSize: 13.0,
        Key.lineSpacing: 1.18,
        Key.tabWidth: 4,
        Key.minimap: true,
        Key.minimapWidth: 70.0,
        Key.hunkBoundary: true,
        Key.hoverEnabled: true,
        Key.hoverDelay: 0.6,
        Key.autoClassify: true,
        Key.groupRelated: true,
        Key.hideMechanical: true,
        Key.quickBatch: 120,
        Key.groupMaxGroups: 80,
        Key.groupOverlap: 0.6,
        Key.groupDistinctLength: 14,
        Key.refreshDelay: 0.6,
        Key.autoAttachments: true,
        Key.claudePath: "",
        Key.claudeConcurrency: 4,
        Key.claudeTimeoutMinutes: 30,
        Key.keepJobs: 60,
        Key.cacheDays: 90,
        Key.autoStartServers: true,
        Key.rustAnalyzerPath: "",
        Key.sourceKitPath: "",
        Key.scipFirst: true,
        Key.openDocuments: 24,
        Key.documentCacheSize: 300,
        Key.headServer: false,
    ]

    static func register() { _ = registration }
    private static let registration: Void = UserDefaults.standard.register(defaults: defaults)

    private static var d: UserDefaults { _ = registration; return .standard }
    static var fontSize: Double { d.double(forKey: Key.fontSize) }
    static var lineSpacing: Double { d.double(forKey: Key.lineSpacing) }
    static var tabWidth: Int { max(1, d.integer(forKey: Key.tabWidth)) }
    static var minimap: Bool { d.bool(forKey: Key.minimap) }
    static var minimapWidth: Double { d.double(forKey: Key.minimapWidth) }
    static var hunkBoundary: Bool { d.bool(forKey: Key.hunkBoundary) }
    static var hoverEnabled: Bool { d.bool(forKey: Key.hoverEnabled) }
    static var hoverDelay: Double { d.double(forKey: Key.hoverDelay) }
    static var autoClassify: Bool { d.bool(forKey: Key.autoClassify) }
    static var hideMechanical: Bool { d.bool(forKey: Key.hideMechanical) }
    static var quickBatch: Int { max(10, d.integer(forKey: Key.quickBatch)) }
    static var groupMaxGroups: Int { max(1, d.integer(forKey: Key.groupMaxGroups)) }
    static var groupOverlap: Double { d.double(forKey: Key.groupOverlap) }
    static var groupDistinctLength: Int { max(4, d.integer(forKey: Key.groupDistinctLength)) }
    static var refreshDelay: Double { d.double(forKey: Key.refreshDelay) }
    static var autoAttachments: Bool { d.bool(forKey: Key.autoAttachments) }
    static var claudeConcurrency: Int { max(1, d.integer(forKey: Key.claudeConcurrency)) }
    static var claudeTimeout: TimeInterval { Double(max(1, d.integer(forKey: Key.claudeTimeoutMinutes))) * 60 }
    static var keepJobs: Int { max(1, d.integer(forKey: Key.keepJobs)) }
    static var cacheDays: Double { Double(max(1, d.integer(forKey: Key.cacheDays))) }
    static var autoStartServers: Bool { d.bool(forKey: Key.autoStartServers) }
    static var scipFirst: Bool { d.bool(forKey: Key.scipFirst) }
    static var openDocuments: Int { max(4, d.integer(forKey: Key.openDocuments)) }
    static var headServer: Bool { d.bool(forKey: Key.headServer) }
    static var documentCacheSize: Int { max(20, d.integer(forKey: Key.documentCacheSize)) }
}
