import EnduragentCoach
import Foundation
import Testing

@testable import Enduragent

@Suite struct FeedbackLineTests {
	private let english = testLocaleResolver()(.automatic)
	private let kept = "The plan card skipped Tuesday."

	private func shown(_ line: FeedbackLine) -> String? {
		line.sentence.map { english.say($0, line.arguments) }
	}

	@Test(arguments: [
		(FeedbackRefusal.empty, "Write a note first."),
		(
			.tooLong(units: 4_001),
			"Keep your note to 4,000 characters or fewer. Nothing was sent."
		),
		(.containsNul, "The note has a character that can't be sent. Nothing was sent."),
	])
	func aRefusalShowsItsSentenceAndOffersSend(refusal: FeedbackRefusal, sentence: String) {
		let line = FeedbackLine.of(
			draft: "", feedback: .notConfirmed, keptText: kept, refusal: refusal)
		#expect(shown(line) == sentence)
		#expect(line.button == .send)
	}

	@Test(arguments: [
		(FeedbackStatus?.none, String?.none, FeedbackButton.send),
		(.idle, nil, .send),
		(.sending, "Sending…", .sending),
		(.received, "Received. Thank you for the note.", .send),
	])
	func eachSettledOrSendingStateShowsItsLine(
		feedback: FeedbackStatus?, sentence: String?, button: FeedbackButton
	) {
		let line = FeedbackLine.of(draft: kept, feedback: feedback, keptText: nil, refusal: nil)
		#expect(shown(line) == sentence)
		#expect(line.button == button)
	}

	@Test(arguments: [
		(
			FeedbackStatus.notSent(.noConnection),
			"Not sent. The phone had no connection. Your note is kept."
		),
		(
			.notSent(.busy),
			"Not sent. The feedback service is busy. Try again in a minute. Your note is kept."
		),
		(
			.notSent(.refused),
			"Not sent. The feedback service refused the note. Your note is kept."
		),
		(
			.notSent(.stopped),
			"Not sent. The app stopped before the note left this phone. Your note is kept."
		),
		(
			.notConfirmed,
			"Not confirmed. The note may have arrived, but no answer came. Your note is kept, and Try again sends the same note."
		),
	])
	func aKeptNoteOffersTryAgainUntilTheDraftChanges(feedback: FeedbackStatus, sentence: String) {
		for draft in [kept, "  \(kept)\n", "\u{FEFF}\(kept)\u{FEFF}"] {
			let line = FeedbackLine.of(
				draft: draft, feedback: feedback, keptText: kept, refusal: nil)
			#expect(shown(line) == sentence)
			#expect(line.button == .tryAgain)
		}
		let edited = FeedbackLine.of(
			draft: "\(kept) Also Wednesday.", feedback: feedback, keptText: kept, refusal: nil)
		#expect(shown(edited) == sentence)
		#expect(edited.button == .send)
	}

	@Test func theJournalLineAppearsOnlyWhileTheLogIsNotSaving() {
		#expect(journalLine(.saving) == nil)
		#expect(
			journalLine(
				.notSaving(since: Date(timeIntervalSince1970: 0), firstCause: .rewriteFailed))
				== Catalog.diagnosticsNotSaving)
	}
}
