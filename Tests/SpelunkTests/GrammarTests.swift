import XCTest
@testable import Spelunk

/// Network-dependent: clones and compiles real grammars. Enabled with SPELUNK_IT_GRAMMARS=1.
final class GrammarTests: XCTestCase {
    func testInstallPythonAndTypeScript() async throws {
        guard ProcessInfo.processInfo.environment["SPELUNK_IT_GRAMMARS"] != nil else { throw XCTSkip("SPELUNK_IT_GRAMMARS not set") }
        let dir = FileManager.default.temporaryDirectory.appendingPathComponent("grammars-\(UUID())")
        let reg = GrammarRegistry(directory: dir)
        let log: @Sendable (String) -> Void = { print("  [install] \($0)") }
        _ = try await reg.install(url: "https://github.com/tree-sitter/tree-sitter-python", subdirectory: nil, revision: nil, log: log)
        _ = try await reg.install(url: "https://github.com/tree-sitter/tree-sitter-javascript", subdirectory: nil, revision: nil, log: log)
        let ts = try await reg.install(url: "https://github.com/tree-sitter/tree-sitter-typescript", subdirectory: nil, revision: nil, log: log)
        XCTAssertEqual(Set(ts.map(\.name)), ["typescript", "tsx"])
        XCTAssertEqual(reg.grammar(forPath: "a.js")?.spec.name, "javascript")
        for g in reg.all { print("grammar \(g.spec.name) exts=\(g.spec.extensions) abi=\(g.language?.ABIVersion ?? -1) hl=\(g.highlights != nil) tags=\(g.tags != nil) err=\(g.error ?? "-")") }

        let py = try XCTUnwrap(reg.grammar(forPath: "x/y.py"))
        let pySrc = """
        import os

        class Greeter:
            \"\"\"Says hello.\"\"\"
            def greet(self, name: str) -> str:
                # comment
                return f"hi {name}" + str(42)

        def main():
            Greeter().greet("x")
        """
        let info = try XCTUnwrap(DynamicSyntax.analyze(pySrc, grammar: py))
        let kinds = Set(info.tokens.map(\.kind))
        print("py token kinds: \(kinds.map(\.rawValue).sorted())")
        XCTAssertTrue(kinds.contains(.keyword) && kinds.contains(.string) && kinds.contains(.comment) && kinds.contains(.function))
        let outline = info.flatOutline.map { "\($0.kind.rawValue):\($0.qualifiedName)" }
        print("py outline: \(outline)")
        XCTAssertTrue(outline.contains("classItem:Greeter"))
        XCTAssertTrue(outline.contains("method:greet"))
        XCTAssertTrue(outline.contains("function:main"))

        let tsg = try XCTUnwrap(reg.grammar(forPath: "a.ts"))
        let tsInfo = try XCTUnwrap(DynamicSyntax.analyze("interface A { x: number }\nexport function f(a: A): string { return `${a.x}` }\n", grammar: tsg))
        print("ts token kinds: \(Set(tsInfo.tokens.map(\.kind.rawValue)).sorted()) outline: \(tsInfo.flatOutline.map(\.name))")
        XCTAssertTrue(tsInfo.tokens.contains { $0.kind == .keyword })
        try? FileManager.default.removeItem(at: dir)
    }
}
