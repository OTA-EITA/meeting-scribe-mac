import Testing
@testable import MeetingScribe

struct TranscriptCoverageTests {
    @Test func findsTheTimeWithNoText() {
        let gaps = TranscriptCoverage.gaps(covered: [(0, 27.3)], duration: 53.5)
        #expect(gaps.count == 1)
        #expect(gaps[0].start == 27.3)
        #expect(gaps[0].end == 53.5)
    }

    @Test func findsAGapAtTheStartAndBetweenSegments() {
        let gaps = TranscriptCoverage.gaps(covered: [(30, 40), (50, 60)], duration: 60)
        #expect(gaps.map(\.start) == [0, 40])
        #expect(gaps.map(\.end) == [30, 50])
    }

    @Test func ignoresShortPauses() {
        let gaps = TranscriptCoverage.gaps(covered: [(0, 10), (12, 20)], duration: 21)
        #expect(gaps.isEmpty)
    }

    @Test func toleratesOverlappingSegments() {
        let gaps = TranscriptCoverage.gaps(covered: [(0, 20), (5, 10), (25, 30)], duration: 30)
        #expect(gaps.count == 1)
        #expect(gaps[0].start == 20)
    }

    @Test func picksLiveSegmentsThatTheFinalPassMissed() {
        let live: [TranscriptCoverage.Span] = [(0, 10), (10, 20), (28, 40), (41, 50)]
        let final: [TranscriptCoverage.Span] = [(0, 27)]
        #expect(TranscriptCoverage.uncovered(candidates: live, covered: final) == [2, 3])
    }

    @Test func keepsALiveSegmentThatIsOnlySlightlyCovered() {
        let picked = TranscriptCoverage.uncovered(candidates: [(20, 30)], covered: [(0, 23)])
        #expect(picked == [0])
    }
}
