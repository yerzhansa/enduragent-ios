import EnduragentCoach
import XCTest

@MainActor
final class ReviewLanguageDeProof: XCTestCase {
	func testEveryReviewStringIsTranslatedAndNoControlIsClipped() {
		ReviewLanguage.sweep(self, .de)
	}

	func testARefusedChangeAndTryAgainReadInTheLanguage() {
		ReviewLanguage.sweep(self, .de, .refusedThenRetried)
	}

	func testALostAnswerAndCheckAgainReadInTheLanguage() {
		ReviewLanguage.sweep(self, .de, .lostThenSeen)
	}

	func testASendingReviewReadsInTheLanguage() {
		ReviewLanguage.sweep(self, .de, .sending)
	}

	func testARefreshedReviewReadsInTheLanguage() {
		ReviewLanguage.sweep(self, .de, .refreshed)
	}

	func testABlockedReviewItsCancelAndANotPreparedTurnReadInTheLanguage() {
		ReviewLanguage.sweep(self, .de, .blockedThenCanceled)
	}

	func testAStalledReviewReadsInTheLanguage() {
		ReviewLanguage.sweep(self, .de, .stalled)
	}
}

@MainActor
final class ReviewLanguagePtPTProof: XCTestCase {
	func testEveryReviewStringIsTranslatedAndNoControlIsClipped() {
		ReviewLanguage.sweep(self, .ptPT)
	}

	func testARefusedChangeAndTryAgainReadInTheLanguage() {
		ReviewLanguage.sweep(self, .ptPT, .refusedThenRetried)
	}

	func testALostAnswerAndCheckAgainReadInTheLanguage() {
		ReviewLanguage.sweep(self, .ptPT, .lostThenSeen)
	}

	func testASendingReviewReadsInTheLanguage() {
		ReviewLanguage.sweep(self, .ptPT, .sending)
	}

	func testARefreshedReviewReadsInTheLanguage() {
		ReviewLanguage.sweep(self, .ptPT, .refreshed)
	}

	func testABlockedReviewItsCancelAndANotPreparedTurnReadInTheLanguage() {
		ReviewLanguage.sweep(self, .ptPT, .blockedThenCanceled)
	}

	func testAStalledReviewReadsInTheLanguage() {
		ReviewLanguage.sweep(self, .ptPT, .stalled)
	}
}

@MainActor
final class ReviewLanguageZhHantProof: XCTestCase {
	func testEveryReviewStringIsTranslatedAndNoControlIsClipped() {
		ReviewLanguage.sweep(self, .zhHant)
	}

	func testARefusedChangeAndTryAgainReadInTheLanguage() {
		ReviewLanguage.sweep(self, .zhHant, .refusedThenRetried)
	}

	func testALostAnswerAndCheckAgainReadInTheLanguage() {
		ReviewLanguage.sweep(self, .zhHant, .lostThenSeen)
	}

	func testASendingReviewReadsInTheLanguage() {
		ReviewLanguage.sweep(self, .zhHant, .sending)
	}

	func testARefreshedReviewReadsInTheLanguage() {
		ReviewLanguage.sweep(self, .zhHant, .refreshed)
	}

	func testABlockedReviewItsCancelAndANotPreparedTurnReadInTheLanguage() {
		ReviewLanguage.sweep(self, .zhHant, .blockedThenCanceled)
	}

	func testAStalledReviewReadsInTheLanguage() {
		ReviewLanguage.sweep(self, .zhHant, .stalled)
	}
}

@MainActor
enum ReviewLanguage {
	static func sweep(_ test: XCTestCase, _ language: LanguageTag) {
		let run = MatrixRun.begin(
			test, language, arguments: FixtureArguments(presentationFault: .failLastCardOnce))
		TutorialHarness.exchange(run.app, ReviewCardContent.mixed)
		TutorialHarness.wait(ReviewCardScreen.card(run.app, 0))
		run.expect("chat.preview.title", Catalog.reviewTitle)
		run.expect("chat.review.status", Catalog.workoutsBarUnseen)
		check(run, "arriving")

		let failed = ReviewReadingOrder.read(run.app, until: "chat.review.showAgain") { page in
			check(run, "failing-\(page)")
		}
		XCTAssertTrue(failed.disorder.isEmpty, "[\(language.rawValue)] \(failed.disorder)")
		run.expect(
			"chat.review.status", Catalog.workoutsBarCardFailed, ["position": "4", "count": "4"])
		run.expect("chat.review.showAgain", Catalog.workoutsBarShowAgain)
		XCTAssertFalse(run.named("chat.preview.add").exists)
		check(run, "card-failed")

		run.tap("chat.review.showAgain")
		TutorialHarness.wait(ReviewCardScreen.card(run.app, 0))
		let whole = ReviewReadingOrder.read(run.app, until: "chat.preview.add") { page in
			check(run, "shown-again-\(page)")
		}
		XCTAssertEqual(
			whole.parts, [.title] + (0..<4).map(ReviewReadingOrder.Part.card) + [.kept, .bar],
			"[\(language.rawValue)] \(whole.transcript)")
		XCTAssertEqual(
			whole.lines(of: .kept).first?.label, run.say(Catalog.workoutsKeptTitle),
			"[\(language.rawValue)] \(whole.transcript)")
		run.expect("chat.review.question", Catalog.workoutsBarQuestionMixed)
		run.expect("chat.preview.add", Catalog.workoutsApprove)
		run.expect("chat.preview.cancel", Catalog.commonCancel)
		check(run, "armed")

		run.tap("chat.preview.add")
		TutorialHarness.wait(run.named("chat.preview.add"), until: .absent, within: .turn)
		TutorialHarness.wait(run.named("chat.note"), within: .turn)
		check(run, "completed")
	}

	enum StageFlow {
		case refusedThenRetried, lostThenSeen, sending, refreshed, blockedThenCanceled, stalled

		var stage: FixtureReviewStage {
			switch self {
			case .refusedThenRetried: .partial
			case .lostThenSeen: .unconfirmed
			case .sending: .sending
			case .refreshed: .refreshed
			case .blockedThenCanceled: .blocked
			case .stalled: .storage
			}
		}
	}

	static func sweep(_ test: XCTestCase, _ language: LanguageTag, _ flow: StageFlow) {
		let run = MatrixRun.begin(
			test, language, arguments: FixtureArguments(reviewStage: flow.stage))
		TutorialHarness.exchange(run.app, ReviewCardContent.mixed)
		TutorialHarness.wait(ReviewCardScreen.card(run.app, 0))
		ReviewCardScreen.showEveryCard(run.app)
		ReviewStates.approve(run.app)
		switch flow {
		case .refusedThenRetried:
			stage(run, "partial", notice: Catalog.workoutsPartial, until: "chat.preview.tryAgain")
			expectFinished(run, lines: 2)
			expectStatus(run, card: 2, Catalog.workoutsCardProgressRefused)
			ReviewStates.tap(run.app, "chat.preview.tryAgain")
			note(run, "retried", closing: Catalog.workoutsCompleted)
		case .lostThenSeen:
			stage(
				run, "unconfirmed", notice: Catalog.workoutsUnconfirmed,
				until: "chat.preview.checkAgain")
			expectStatus(run, card: 0, Catalog.workoutsCardProgressMayHaveBeenSaved)
			ReviewStates.tap(run.app, "chat.preview.checkAgain")
			stage(
				run, "seen", notice: Catalog.workoutsStopped, vars: [:],
				until: "chat.preview.tryAgain")
			expectFinished(run, lines: 1)
		case .sending:
			stage(run, "sending", notice: Catalog.workoutsSending, until: "chat.review.notice")
			expectFinished(run, lines: 1)
			expectStatus(run, card: 1, Catalog.workoutsCardProgressSending)
		case .refreshed:
			stage(
				run, "refreshed", notice: Catalog.workoutsRefreshedNothingChanged,
				until: "chat.preview.add")
		case .blockedThenCanceled:
			stage(
				run, "blocked", notice: Catalog.workoutsBlockedMissing, until: "chat.preview.cancel"
			)
			ReviewStates.tap(run.app, "chat.preview.cancel")
			note(run, "canceled", closing: Catalog.workoutsCanceled)
			TutorialHarness.exchange(run.app, "fixture:review-not-prepared")
			run.expect("chat.turn.reviewNotice", Catalog.workoutsNotPrepared)
			check(run, "not-prepared")
		case .stalled:
			stage(
				run, "stalled", notice: Catalog.reviewStorageUnavailable, vars: [:],
				shownAs: "chat.preview.notice", until: "chat.preview.notice")
		}
	}

	private static func stage(
		_ run: MatrixRun, _ page: String, notice key: CatalogKey,
		vars: [String: String] = ["service": "intervals.icu"],
		shownAs identifier: String = "chat.review.notice", until control: String
	) {
		let notice = run.named(identifier)
		let sentence = run.say(key, vars)
		ReviewCardScreen.reveal(run.app, notice)
		TutorialHarness.wait(
			until: { notice.exists && notice.label.contains(sentence) },
			message:
				"[\(run.language.rawValue)] \(identifier) does not read \(sentence): \(notice.label)"
		)
		let read = ReviewReadingOrder.read(run.app, until: control) { index in
			check(run, "\(page)-\(index)")
		}
		XCTAssertTrue(read.disorder.isEmpty, "[\(run.language.rawValue)] \(page): \(read.disorder)")
	}

	private static func expectFinished(_ run: MatrixRun, lines count: Int) {
		let box = run.named("chat.preview.finished")
		ReviewCardScreen.reveal(run.app, box, direction: .down)
		run.expect("chat.preview.finished.title", Catalog.workoutsFinishedTitle)
		XCTAssertEqual(
			box.staticTexts.matching(identifier: "chat.preview.finished.line").count, count,
			"[\(run.language.rawValue)] \(box.label)")
	}

	private static func expectStatus(_ run: MatrixRun, card index: Int, _ key: CatalogKey) {
		ReviewStates.expectStatus(run.app, card: index, run.say(key))
	}

	private static func note(_ run: MatrixRun, _ page: String, closing key: CatalogKey) {
		let note = run.named("chat.note")
		TutorialHarness.wait(note, within: .turn)
		ReviewCardScreen.reveal(run.app, note)
		run.expect("chat.note.closing", key)
		check(run, page)
	}

	private static func check(_ run: MatrixRun, _ page: String) {
		let name = "u8-4-\(run.language.rawValue)-review-language-\(page)"
		TutorialHarness.attach(run.test, name: name, app: run.app)
		do {
			let transcript = run.named("chat.transcript")
			let bar = ReviewCardScreen.bar(run.app)
			let docked =
				bar.exists
				&& !transcript.descendants(matching: .any)
					.matching(identifier: ReviewCardReading.bar).firstMatch.exists
			let shown =
				MatrixSweep.shown(in: try transcript.snapshot())
				+ (docked ? MatrixSweep.shown(in: try bar.snapshot()) : [])
			XCTAssertFalse(shown.isEmpty, "\(name) shows no text")
			let findings = MatrixSweep.findings(
				in: shown, catalog: try MatrixCatalog.load(run.language))
			XCTAssertTrue(findings.isEmpty, "\(name): \(findings.joined(separator: "; "))")
		} catch {
			XCTFail("\(name): the review could not be read: \(error)")
		}
		ReviewLong.audit(run.app, name)
	}
}
