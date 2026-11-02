// swift-tools-version: 6.0
import PackageDescription

let package = Package(
    name: "Spelunk",
    platforms: [.macOS(.v15)],
    dependencies: [
        .package(url: "https://github.com/ChimeHQ/SwiftTreeSitter", exact: "0.9.0"),
        .package(url: "https://github.com/tree-sitter/tree-sitter-rust", exact: "0.23.2"),
    ],
    targets: [
        .executableTarget(
            name: "Spelunk",
            dependencies: [
                .product(name: "SwiftTreeSitter", package: "SwiftTreeSitter"),
                .product(name: "TreeSitterRust", package: "tree-sitter-rust"),
            ],
            path: "Sources/Spelunk",
            swiftSettings: [.swiftLanguageMode(.v5)]
        ),
        .testTarget(
            name: "SpelunkTests",
            dependencies: ["Spelunk"],
            path: "Tests/SpelunkTests",
            swiftSettings: [.swiftLanguageMode(.v5)]
        ),
    ]
)
