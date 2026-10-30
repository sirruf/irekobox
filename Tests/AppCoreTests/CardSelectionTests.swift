import XCTest
import AppKit
@testable import AppCore

final class CardSelectionTests: XCTestCase {
    private let order = ["a", "b", "c", "d", "e"]

    func testClickSelectsOneCommandAddsAndRemoves() {
        var selection = CardSelection()
        selection.click("b", in: order, modifiers: [])
        selection.click("d", in: order, modifiers: [])
        XCTAssertEqual(selection.ids, ["d"])
        selection.click("a", in: order, modifiers: .command)
        XCTAssertEqual(selection.ids, ["a", "d"])
        selection.click("d", in: order, modifiers: .command)
        XCTAssertEqual(selection.ids, ["a"])
    }

    func testShiftClickTakesTheRangeFromTheLastClickEitherWay() {
        var selection = CardSelection()
        selection.click("b", in: order, modifiers: [])
        selection.click("d", in: order, modifiers: .shift)
        XCTAssertEqual(selection.ids, ["b", "c", "d"])

        selection.click("e", in: order, modifiers: [])
        selection.click("c", in: order, modifiers: .shift)
        XCTAssertEqual(selection.ids, ["c", "d", "e"])
    }

    func testShiftClickWithNothingClickedSelectsJustThatCard() {
        var selection = CardSelection()
        selection.click("c", in: order, modifiers: .shift)
        XCTAssertEqual(selection.ids, ["c"])
    }

    func testCardsThatAreGoneLeaveTheSelection() {
        var selection = CardSelection()
        selection.select(order)
        selection.keep(["a", "e"])
        XCTAssertEqual(selection.ids, ["a", "e"])
        selection.clear()
        XCTAssertTrue(selection.isEmpty)
    }
}
