import Testing
import ParseleyCore

@Suite struct WelcomeTourTests {
    @Test func startsAtFirstStep() {
        let tour = WelcomeTour()
        #expect(tour.current == .copyNumbers)
        #expect(tour.doneCount == 0)
        #expect(tour.total == 8)
        #expect(!tour.isFinished)
    }

    @Test func completingCurrentStepThenAdvancing() {
        var tour = WelcomeTour()
        let r1 = tour.record(.copiedNumbers); #expect(r1)
        #expect(tour.isDone(.copyNumbers))
        tour.advance()
        #expect(tour.current == .openPanel)
    }

    @Test func doingAStepEarlyCountsAndIsSkippedOver() {
        var tour = WelcomeTour()
        let r2 = tour.record(.openedPanel); #expect(!r2, "not the step on screen")
        #expect(tour.isDone(.openPanel))
        tour.record(.copiedNumbers)
        tour.advance()
        #expect(tour.current == .copyStat, "openPanel already done")
    }

    @Test func repeatingAnEventDoesNotRecelebrate() {
        var tour = WelcomeTour()
        let r3 = tour.record(.copiedNumbers); #expect(r3)
        let r4 = tour.record(.copiedNumbers); #expect(!r4)
    }

    @Test func skipMarksSkippedUntilDoneLater() {
        var tour = WelcomeTour()
        tour.skip()
        #expect(tour.isSkipped(.copyNumbers))
        #expect(tour.current == .openPanel)
        tour.record(.copiedNumbers)
        #expect(!tour.isSkipped(.copyNumbers))
        #expect(tour.isDone(.copyNumbers))
    }

    @Test func advancingPastTheLastStepFinishes() {
        var tour = WelcomeTour()
        tour.go(to: .autoPaste)
        tour.record(.autoPasteEnabled)
        tour.advance()
        #expect(tour.isFinished)
        tour.back()
        #expect(tour.current == .autoPaste)
    }

    @Test func backStopsAtFirstStep() {
        var tour = WelcomeTour()
        tour.back()
        #expect(tour.current == .copyNumbers)
        tour.go(to: .feedSeries)
        tour.back()
        #expect(tour.current == .startSeries)
    }

    @Test func fullRunInOrder() {
        var tour = WelcomeTour()
        let events: [WelcomeTour.Event] = [.copiedNumbers, .openedPanel, .copiedStat, .startedSeries,
                                           .seriesHasThreeValues, .ranCommand, .savedSeriesTotal, .autoPasteEnabled]
        for event in events {
            let completedCurrent = tour.record(event)
            #expect(completedCurrent, "\(event)")
            tour.advance()
        }
        #expect(tour.isFinished)
        #expect(tour.doneCount == 8)
    }

    @Test func stepsHaveTitles() {
        #expect(WelcomeTour.Step.allCases.allSatisfy { !$0.title.isEmpty })
        #expect(NumberStats(text: WelcomeTour.sampleText)?.count == 3, "sample yields stats")
    }
}
