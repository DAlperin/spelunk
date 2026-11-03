import XCTest
@testable import Spelunk

final class AnchorTests: XCTestCase {
    let original = """
    struct Engine { n: u32 }

    impl Engine {
        fn start(&mut self) {
            self.n = 1;
            self.run();
        }

        fn run(&self) {
            println!("{}", self.n);
        }
    }
    """

    func doc(_ text: String) -> SourceDocument { SourceDocument(path: "src/engine.rs", text: text) }

    func anchor(line: Int) -> (CodeLocation, CodeAnchor) {
        let loc = CodeLocation(path: "src/engine.rs", range: SourceRange(line: line, col: 8))
        return (loc, CodeAnchor.make(loc, in: doc(original)))
    }

    func testUnchangedFileKeepsLine() {
        let (loc, a) = anchor(line: 5)
        XCTAssertEqual(a.symbol, "Engine::start")
        XCTAssertEqual(a.resolve(line: loc.line, in: doc(original)), .unchanged)
    }

    func testLinesInsertedAboveMoveTheLocation() {
        let (loc, a) = anchor(line: 5)
        let edited = "// header\n// more\n\n" + original
        XCTAssertEqual(a.resolve(line: loc.line, in: doc(edited)), .moved(toLine: 8))
    }

    func testReorderedFunctionsFollowTheSymbol() {
        let (loc, a) = anchor(line: 9)
        let reordered = """
        struct Engine { n: u32 }

        impl Engine {
            fn run(&self) {
                println!("{}", self.n);
            }

            fn start(&mut self) {
                self.n = 1;
                self.run();
            }
        }
        """
        XCTAssertEqual(a.symbol, "Engine::run")
        XCTAssertEqual(a.resolve(line: loc.line, in: doc(reordered)), .moved(toLine: 4))
    }

    func testChangedLineKeepsItsDistanceIntoTheSymbol() {
        let (loc, a) = anchor(line: 4)
        let edited = original.replacingOccurrences(of: "self.n = 1;", with: "self.n = 2;").replacingOccurrences(of: "struct Engine { n: u32 }", with: "struct Engine {\n    n: u32,\n}")
        XCTAssertEqual(a.resolve(line: loc.line, in: doc(edited)), .moved(toLine: 6))
    }

    func testMissingCodeIsLost() {
        let (loc, a) = anchor(line: 10)
        XCTAssertEqual(a.resolve(line: loc.line, in: doc("fn other() {}\n")), .lost)
    }

    func testPlainTextRoundTrip() {
        var t = Trace(title: "Start: the engine", origin: .manual)
        t.steps = [
            TraceStep(title: "Engine::start", location: CodeLocation(path: "src/engine.rs", range: SourceRange(line: 3)),
                      note: "Sets n: then runs", edge: .manual, source: .manual),
            TraceStep(title: "run", location: CodeLocation(path: "src/a\\b.rs", range: SourceRange(line: 8)),
                      note: "Prints", edge: .manual, source: .manual),
        ]
        let text = t.plainText()
        XCTAssertTrue(text.contains("src/engine.rs:Engine\\:\\:start:Sets n: then runs"))
        let parsed = Trace.parsePlainText(text)
        XCTAssertEqual(parsed?.title, "Start: the engine")
        XCTAssertEqual(parsed?.steps.map(\.symbol), ["Engine::start", "run"])
        XCTAssertEqual(parsed?.steps.map(\.file), ["src/engine.rs", "src/a\\b.rs"])
        XCTAssertEqual(parsed?.steps.first?.note, "Sets n: then runs")
        XCTAssertNil(Trace.parsePlainText("just a title\n"))
    }
}
