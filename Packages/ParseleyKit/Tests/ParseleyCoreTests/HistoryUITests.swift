import Foundation
import Testing
import ParseleyCore

@Suite struct ListSelectionTests {
    @Test func emptyListHasNoSelection() {
        var s = ListSelection()
        s.update(ids: [])
        #expect(s.selectedID == nil)
        s.move(by: 1, in: [])
        #expect(s.selectedID == nil)
    }

    @Test func firstUpdateSelectsFirst() {
        var s = ListSelection()
        s.update(ids: [5, 4, 3])
        #expect(s.selectedID == 5)
    }

    @Test func moveClampsAtBothEnds() {
        var s = ListSelection()
        let ids: [Int64] = [1, 2, 3]
        s.update(ids: ids)
        s.move(by: -1, in: ids)
        #expect(s.selectedID == 1)
        s.move(by: 1, in: ids); s.move(by: 1, in: ids); s.move(by: 1, in: ids)
        #expect(s.selectedID == 3)
        s.move(by: -10, in: ids)
        #expect(s.selectedID == 1)
    }

    @Test func moveWithoutSelectionStartsAtNearestEnd() {
        var down = ListSelection()
        down.move(by: 1, in: [1, 2, 3])
        #expect(down.selectedID == 1)
        var up = ListSelection()
        up.move(by: -1, in: [1, 2, 3])
        #expect(up.selectedID == 3)
    }

    @Test func selectionFollowsClipWhenNewClipArrivesOnTop() {
        var s = ListSelection()
        s.update(ids: [3, 2, 1])
        s.move(by: 1, in: [3, 2, 1])            // select 2
        s.update(ids: [4, 3, 2, 1])             // new clip 4 copied meanwhile
        #expect(s.selectedID == 2)
    }

    @Test func deletingSelectedSelectsTheOneThatTakesItsPlace() {
        var s = ListSelection()
        s.update(ids: [1, 2, 3])
        s.select(2, in: [1, 2, 3])
        s.update(ids: [1, 3])
        #expect(s.selectedID == 3)
    }

    @Test func deletingLastSelectsNewLast() {
        var s = ListSelection()
        s.update(ids: [1, 2, 3])
        s.select(3, in: [1, 2, 3])
        s.update(ids: [1, 2])
        #expect(s.selectedID == 2)
    }

    @Test func queryChangeResetsToFirst() {
        var s = ListSelection()
        s.update(ids: [1, 2, 3])
        s.select(3, in: [1, 2, 3])
        s.update(ids: [2, 3], resetToFirst: true)
        #expect(s.selectedID == 2)
    }

    @Test func selectIgnoresUnknownID() {
        var s = ListSelection()
        s.update(ids: [1, 2])
        s.select(99, in: [1, 2])
        #expect(s.selectedID == 1)
    }
}

@Suite struct ClipPreviewTests {
    @Test(arguments: [
        ("hello", "hello"),
        ("  hello   world  ", "hello world"),
        ("\n\n  \nsecond line\nthird", "second line"),
        ("a\tb\tc", "a b c"),
        ("", ""),
        ("   \n\t", ""),
    ])
    func title(_ input: String, _ expected: String) {
        #expect(ClipPreview.title(input) == expected)
    }

    @Test func truncatesWithEllipsis() {
        let t = ClipPreview.title(String(repeating: "x", count: 100), maxLength: 10)
        #expect(t == "xxxxxxxxx…")
        #expect(t.count == 10)
        #expect(ClipPreview.title("exactly10!", maxLength: 10) == "exactly10!")
    }

    @Test func countsNonBlankLines() {
        #expect(ClipPreview.lineCount("a\n\nb\r\nc\n  \n") == 3)
        #expect(ClipPreview.lineCount("") == 0)
    }
}

@Suite struct PanelPlacementTests {
    let screen = CGRect(x: 0, y: 0, width: 1000, height: 800)
    let size = CGSize(width: 300, height: 200)

    @Test func placesBelowRightOfCursor() {
        let f = PanelPlacement.frame(size: size, cursor: CGPoint(x: 100, y: 700), visibleFrame: screen)
        #expect(f == CGRect(x: 108, y: 492, width: 300, height: 200))
    }

    @Test func flipsLeftNearRightEdge() {
        let f = PanelPlacement.frame(size: size, cursor: CGPoint(x: 950, y: 700), visibleFrame: screen)
        #expect(f.maxX == 942)
    }

    @Test func flipsAboveNearBottomEdge() {
        let f = PanelPlacement.frame(size: size, cursor: CGPoint(x: 100, y: 50), visibleFrame: screen)
        #expect(f.minY == 58)
    }

    @Test func staysInsideScreen() {
        for cursor in [CGPoint(x: 0, y: 0), CGPoint(x: 1000, y: 800), CGPoint(x: 500, y: 790), CGPoint(x: -50, y: 900)] {
            let f = PanelPlacement.frame(size: size, cursor: cursor, visibleFrame: screen)
            #expect(screen.contains(f), "cursor \(cursor) gave \(f)")
        }
    }

    @Test func worksOnSecondaryScreenWithOffsetOrigin() {
        let second = CGRect(x: -1440, y: 100, width: 1440, height: 900)
        let f = PanelPlacement.frame(size: size, cursor: CGPoint(x: -1400, y: 950), visibleFrame: second)
        #expect(second.contains(f))
        #expect(f.minX == -1392)
    }

    @Test func oversizedPanelPinsTopLeft() {
        let f = PanelPlacement.frame(size: CGSize(width: 2000, height: 1000), cursor: CGPoint(x: 500, y: 400), visibleFrame: screen)
        #expect(f.minX == 0)
        #expect(f.maxY == 800)
    }
}

@Suite struct MultiSelectionTests {
    let list: [Int64] = [10, 20, 30, 40, 50]

    @Test func commandClickAddsFocusedRowToo() {
        var m = MultiSelection()
        m.toggle(30, focused: 10)
        #expect(m.ids == [10, 30])
        #expect(m.isActive)
        m.toggle(50, focused: 30)
        #expect(m.ordered(in: list) == [10, 30, 50])
    }

    @Test func commandClickTogglesOffAndCollapsesBelowTwo() {
        var m = MultiSelection()
        m.toggle(30, focused: 10)
        m.toggle(30, focused: 30)
        #expect(m.ids.isEmpty)
        #expect(!m.isActive)
    }

    @Test func commandClickOnFocusedRowAloneSelectsNothing() {
        var m = MultiSelection()
        m.toggle(10, focused: 10)
        #expect(m.ids.isEmpty)
    }

    @Test func shiftClickSelectsRangeInEitherDirection() {
        var m = MultiSelection()
        m.extend(to: 40, from: 20, in: list)
        #expect(m.ordered(in: list) == [20, 30, 40])
        m.extend(to: 10, from: 30, in: list)
        #expect(m.ordered(in: list) == [10, 20, 30])
    }

    @Test func shiftClickOnSameRowOrUnknownClears() {
        var m = MultiSelection()
        m.extend(to: 20, from: 20, in: list)
        #expect(m.ids.isEmpty)
        m.extend(to: 99, from: 20, in: list)
        #expect(m.ids.isEmpty)
        m.extend(to: 20, from: nil, in: list)
        #expect(m.ids.isEmpty)
    }

    @Test func pruneDropsMissingAndCollapses() {
        var m = MultiSelection()
        m.extend(to: 30, from: 10, in: list)
        m.prune(to: [10, 30, 40])
        #expect(m.ids == [10, 30])
        m.prune(to: [10])
        #expect(m.ids.isEmpty)
    }

    @Test func containsHandlesNil() {
        var m = MultiSelection()
        m.toggle(20, focused: 10)
        #expect(m.contains(20))
        #expect(!m.contains(nil))
    }
}
