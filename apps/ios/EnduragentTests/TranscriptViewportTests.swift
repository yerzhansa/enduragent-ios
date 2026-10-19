import CoreGraphics
import Testing

@testable import Enduragent

struct TranscriptViewportTests {
	let transcript = TranscriptViewport(frame: CGRect(x: 0, y: 100, width: 390, height: 500))

	@Test func aCardCountsOnlyWhenAtLeastHalfOfItIsInsideTheVisibleTranscript() {
		#expect(transcript.shows(CGRect(x: 16, y: 120, width: 358, height: 140)))
		#expect(transcript.shows(CGRect(x: 16, y: 520, width: 358, height: 140)))
		#expect(!transcript.shows(CGRect(x: 16, y: 540, width: 358, height: 140)))
		#expect(!transcript.shows(CGRect(x: 16, y: 620, width: 358, height: 140)))
		#expect(!transcript.shows(CGRect(x: 16, y: -100, width: 358, height: 140)))
	}

	@Test func aCardTallerThanTheTranscriptCountsOnceItFillsHalfOfIt() {
		#expect(transcript.shows(CGRect(x: 16, y: 340, width: 358, height: 1300)))
		#expect(!transcript.shows(CGRect(x: 16, y: 360, width: 358, height: 1300)))
	}

	@Test func nothingCountsBeforeTheTranscriptIsMeasured() {
		let unmeasured = TranscriptViewport(frame: .null)
		#expect(!unmeasured.shows(CGRect(x: 16, y: 120, width: 358, height: 140)))
		#expect(!TranscriptViewport(frame: .zero).shows(.zero))
	}
}
