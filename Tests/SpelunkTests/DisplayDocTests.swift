import XCTest
@testable import Spelunk

final class DisplayDocTests: XCTestCase {
    func testPhantomLinesMapBackToRealPositions() {
        let doc = SourceDocument(path: "src/x.rs", text: "fn a() {\n    one();\n    three();\n}\n")
        let removed = PhantomLine(kind: .removed, otherLine: 2, text: "    two();", tokens: [])
        let d = DisplayDoc(doc: doc, phantoms: [2: [removed]])
        XCTAssertEqual(d.ns.components(separatedBy: "\n"), ["fn a() {", "    one();", "    two();", "    three();", "}", ""])
        XCTAssertEqual(d.displayLine(1), 1)
        XCTAssertEqual(d.displayLine(2), 3)
        XCTAssertNil(d.realPos(SourcePos(line: 2, col: 4)))
        XCTAssertEqual(d.realPos(SourcePos(line: 3, col: 4)), SourcePos(line: 2, col: 4))
        // A real token after the phantom shifts by the phantom's length.
        let three = doc.ns.range(of: "three")
        let shifted = d.displayOffset(realOffset: three.location)
        XCTAssertEqual(d.ns.substring(with: NSRange(location: shifted, length: 5)), "three")
        XCTAssertEqual(d.ns.substring(with: d.displayRange(SourceRange(start: SourcePos(line: 2, col: 4), end: SourcePos(line: 2, col: 9)))), "three")
    }

    func testTrailingPhantomAfterLastLine() {
        let doc = SourceDocument(path: "src/x.rs", text: "a\nb")
        let d = DisplayDoc(doc: doc, phantoms: [2: [PhantomLine(kind: .removed, otherLine: 2, text: "c", tokens: [])]])
        XCTAssertEqual(d.text, "a\nb\nc")
        XCTAssertNil(d.realPos(SourcePos(line: 2, col: 0)))
        XCTAssertEqual(d.realPos(SourcePos(line: 1, col: 0)), SourcePos(line: 1, col: 0))
    }

    func testIdentityWithoutPhantoms() {
        let doc = SourceDocument(path: "src/x.rs", text: "x\ny\n")
        let d = DisplayDoc(doc: doc, phantoms: [:])
        XCTAssertEqual(d.text, doc.text)
        XCTAssertEqual(d.displayOffset(realOffset: 2), 2)
    }
}
