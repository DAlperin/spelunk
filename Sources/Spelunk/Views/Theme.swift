import AppKit
import SwiftUI

enum Theme {
    static func dynamic(_ light: NSColor, _ dark: NSColor) -> NSColor {
        NSColor(name: nil) { $0.bestMatch(from: [.darkAqua, .aqua]) == .darkAqua ? dark : light }
    }

    static func hex(_ v: UInt32, _ a: CGFloat = 1) -> NSColor {
        NSColor(srgbRed: CGFloat((v >> 16) & 0xff) / 255, green: CGFloat((v >> 8) & 0xff) / 255, blue: CGFloat(v & 0xff) / 255, alpha: a)
    }

    static let text = dynamic(hex(0x1f2328), hex(0xd4d4d8))
    static let background = dynamic(hex(0xfbfbfa), hex(0x1c1c1f))
    static let gutter = dynamic(hex(0xf2f2f0), hex(0x232327))
    static let gutterText = dynamic(hex(0x9a9a9a), hex(0x6b6b72))
    static let currentLine = dynamic(hex(0x0969da, 0.07), hex(0x58a6ff, 0.09))
    static let target = dynamic(hex(0xffd33d, 0.35), hex(0xbb8009, 0.35))
    static let occurrence = dynamic(hex(0x0969da, 0.13), hex(0x58a6ff, 0.2))
    static let added = dynamic(hex(0x1a7f37, 0.12), hex(0x2ea043, 0.18))
    static let removed = dynamic(hex(0xcf222e, 0.11), hex(0xf85149, 0.17))
    static let addedMarker = dynamic(hex(0x1a7f37), hex(0x3fb950))
    static let removedMarker = dynamic(hex(0xcf222e), hex(0xf85149))
    static let traceLine = dynamic(hex(0x8250df, 0.10), hex(0xa371f7, 0.16))
    static let testRegion = dynamic(hex(0x000000, 0.025), hex(0xffffff, 0.025))

    static func color(_ k: TokenKind) -> NSColor {
        switch k {
        case .keyword: dynamic(hex(0xcf222e), hex(0xff7b72))
        case .selfKeyword: dynamic(hex(0xcf222e), hex(0xff7b72))
        case .type: dynamic(hex(0x0a7d8c), hex(0x4ec9b0))
        case .function: dynamic(hex(0x0550ae), hex(0x79c0ff))
        case .macro: dynamic(hex(0x8250df), hex(0xd2a8ff))
        case .string: dynamic(hex(0x0a3069), hex(0xa5d6ff))
        case .number, .constant: dynamic(hex(0xbc4c00), hex(0xffa657))
        case .comment: dynamic(hex(0x6e7781), hex(0x8b949e))
        case .docComment: dynamic(hex(0x57606a), hex(0x9ea7b3))
        case .attribute: dynamic(hex(0x953800), hex(0xe3b341))
        case .lifetime: dynamic(hex(0xbc4c00), hex(0xffa657))
        case .field: dynamic(hex(0x6639ba), hex(0xc7a3ff))
        case .module: dynamic(hex(0x57606a), hex(0xb0b0b8))
        case .operatorToken, .plain: text
        }
    }

    static var codeFont: NSFont {
        let size = CGFloat(UserDefaults.standard.double(forKey: "fontSize").nonZero ?? 13)
        return NSFont(name: "SF Mono", size: size) ?? .monospacedSystemFont(ofSize: size, weight: .regular)
    }
}

extension Double { var nonZero: Double? { self == 0 ? nil : self } }

extension ChangeTier {
    var color: Color {
        switch self {
        case .critical: .red
        case .behavior: .orange
        case .supporting: .blue
        case .tests: .teal
        case .mechanical: .gray
        }
    }
}

extension IntelSource {
    var color: Color {
        switch self {
        case .rustAnalyzer: .green
        case .scip: .blue
        case .treeSitter: .orange
        case .textSearch: .gray
        case .claude: .purple
        case .manual: .secondary
        }
    }
}

struct SourceBadge: View {
    let source: IntelSource
    var body: some View {
        Text(source.label)
            .font(.system(size: 9, weight: .medium))
            .padding(.horizontal, 5).padding(.vertical, 1)
            .background(source.color.opacity(0.15), in: Capsule())
            .foregroundStyle(source.color)
            .help("Answered by \(source.label)")
    }
}

struct TierBadge: View {
    let tier: ChangeTier
    var body: some View {
        Text(tier.shortTitle)
            .font(.system(size: 9, weight: .semibold))
            .padding(.horizontal, 5).padding(.vertical, 1)
            .background(tier.color.opacity(0.15), in: Capsule())
            .foregroundStyle(tier.color)
    }
}
