import EnduragentCoach
import XCTest

@MainActor
final class ReviewLanguageDeProof: XCTestCase {
	func testEveryReviewStringIsTranslatedAndNoControlIsClipped() {
		ReviewLanguage.sweep(self, .de)
	}
}

@MainActor
final class ReviewLanguagePtPTProof: XCTestCase {
	func testEveryReviewStringIsTranslatedAndNoControlIsClipped() {
		ReviewLanguage.sweep(self, .ptPT)
	}
}

@MainActor
final class ReviewLanguageZhHantProof: XCTestCase {
	func testEveryReviewStringIsTranslatedAndNoControlIsClipped() {
		ReviewLanguage.sweep(self, .zhHant)
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
