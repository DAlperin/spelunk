// swift-tools-version: 6.0
import PackageDescription

let package = Package(
    name: "Spelunk",
    platforms: [.macOS(.v15)],
    dependencies: [
        // main tracks the tree-sitter 0.25 runtime, which loads ABI 15 grammars (0.9.0 stops at ABI 14).
        .package(url: "https://github.com/ChimeHQ/SwiftTreeSitter", revision: "cbe31cb3601aa29c1f64b6e4328733511126d6d5"),
    ],
    targets: [
        .executableTarget(
            name: "Spelunk",
            dependencies: [
                .product(name: "SwiftTreeSitter", package: "SwiftTreeSitter"),
                "TreeSitterRustGrammar",
            ],
            path: "Sources/Spelunk",
            swiftSettings: [.swiftLanguageMode(.v5)]
        ),
        .target(
            name: "TreeSitterRustGrammar",
            path: "Sources/TreeSitterRustGrammar",
            exclude: ["LICENSE"],
            sources: ["src/parser.c", "src/scanner.c"],
            publicHeadersPath: "include",
            cSettings: [.headerSearchPath("src")]
        ),
        .testTarget(
            name: "SpelunkTests",
            dependencies: ["Spelunk"],
            path: "Tests/SpelunkTests",
            swiftSettings: [.swiftLanguageMode(.v5)]
        ),
    ]
)
