// swift-tools-version: 6.0
import PackageDescription

let package = Package(
    name: "Spelunk",
    platforms: [.macOS(.v15)],
    dependencies: [
        // main tracks the tree-sitter 0.25 runtime, which loads ABI 15 grammars (0.9.0 stops at ABI 14).
        .package(url: "https://github.com/ChimeHQ/SwiftTreeSitter", revision: "cbe31cb3601aa29c1f64b6e4328733511126d6d5"),
        .package(url: "https://github.com/tree-sitter/tree-sitter-rust", exact: "0.24.2"),
    ],
    targets: [
        .executableTarget(
            name: "Spelunk",
            dependencies: [
                .product(name: "SwiftTreeSitter", package: "SwiftTreeSitter"),
                .product(name: "TreeSitterRust", package: "tree-sitter-rust"),
            ],
            path: "Sources/Spelunk",
            swiftSettings: [.swiftLanguageMode(.v6)]
        ),
        .testTarget(
            name: "SpelunkTests",
            dependencies: ["Spelunk"],
            path: "Tests/SpelunkTests",
            swiftSettings: [.swiftLanguageMode(.v6)]
        ),
    ]
)
