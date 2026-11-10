import XCTest
@testable import Spelunk

@MainActor
final class GuideTests: XCTestCase {
    private func tempFile() -> URL {
        let url = FileManager.default.temporaryDirectory.appendingPathComponent("guide-\(UUID().uuidString).json")
        addTeardownBlock { try? FileManager.default.removeItem(at: url) }
        return url
    }

    func testStepsCompleteInAnyOrderAndNeedEveryEvent() {
        let g = Guide(file: tempFile())
        XCTAssertEqual(g.focus?.id, "open")
        g.note(.wentBack)
        XCTAssertFalse(g.isDone(Guide.steps[1]), "a definition step needs the jump as well as Back")
        g.note(.searched)
        XCTAssertEqual(g.doneCount, 1)
        XCTAssertEqual(g.focus?.id, "open")
        g.note(.openedFile)
        g.note(.followedDefinition)
        XCTAssertEqual(g.focus?.id, "hunks")
        g.skip(g.focus!)
        XCTAssertEqual(g.focus?.id, "review")
    }

    func testProgressAndClosingAreSaved() {
        let file = tempFile()
        let g = Guide(file: file)
        g.windowOpened()
        XCTAssertTrue(g.visible)
        g.note(.openedPalette)
        g.close()
        let again = Guide(file: file)
        XCTAssertTrue(again.events.contains(.openedPalette))
        again.windowOpened()
        XCTAssertFalse(again.visible, "a closed guide stays closed in new windows")
        again.show()
        XCTAssertTrue(again.visible)
        XCTAssertFalse(Guide(file: file).closed, "showing it from the Help menu reopens it for later windows")
    }

    func testFinishedGuideDoesNotOpenByItself() {
        let g = Guide(file: tempFile())
        Guide.Event.allCases.forEach(g.note)
        XCTAssertTrue(g.finished)
        XCTAssertNil(g.focus)
        g.windowOpened()
        XCTAssertFalse(g.visible)
        g.restart()
        XCTAssertEqual(g.doneCount, 0)
        XCTAssertTrue(g.visible)
    }
}
