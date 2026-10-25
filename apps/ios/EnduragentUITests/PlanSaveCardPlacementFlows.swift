import EnduragentCoach
import XCTest

extension PlanSaveCard {
	static func carried(_ test: XCTestCase, _ language: LanguageTag, _ size: PlanCardSize) {
		let screen = PlanSaveCardScreen.begin(test, language, size)
		let first = PlanFixture.weeks(12)
		screen.exchange(PlanFixture.directive)
		TutorialHarness.startNewConversation(screen.run.app, language: language)
		screen.show()
		screen.waitForCard(first)
		screen.expectOpening(first, newest: nil, "carried")
		expectDrawnOnceAtTheTop(screen, first, "carried")
		screen.expectControls(true, of: first, "carried")
		screen.expectBar(under: first, "carried")
		screen.expectReadingOrder(
			first, screen.expected(first, preparedEarlier: true), "carried")
		screen.expectWholeButtons("carried")
		screen.expectDisclaimerLast("carried")
		screen.capture("carried")
		screen.audit("carried")
		tap(PlanSaveCardScreen.cancel, on: screen)
		screen.expectControls(false, of: first, "carried-canceled")
		screen.expectState(Catalog.chatPlanSaveCanceled, of: first, "carried-canceled")
		expectDrawnOnceAtTheTop(screen, first, "carried-canceled")
		screen.capture("carried-canceled")

		let second = PlanFixture.weeks(10)
		if size == .largest { screen.relaunch(at: .standard) }
		screen.exchange(PlanFixture.directive(weeks: 10))
		TutorialHarness.startNewConversation(screen.run.app, language: language)
		screen.relaunch(at: size, clock: PlanFixture.laterClock)
		screen.waitForCard(second)
		expectDrawnOnceAtTheTop(screen, second, "carried-expired")
		screen.expectState(Catalog.chatPlanSaveExpired, of: second, "carried-expired")
		screen.expectControls(false, of: second, "carried-expired")
		screen.capture("carried-expired")
	}

	static func armsWhenScrolledIntoView(
		_ test: XCTestCase, _ language: LanguageTag, _ size: PlanCardSize
	) {
		let screen = PlanSaveCardScreen.begin(test, language, size)
		let plan = PlanFixture.weeks(12)
		screen.exchange(PlanFixture.directive)
		TutorialHarness.startNewConversation(screen.run.app, language: language)
		for _ in 1...3 { screen.exchange(TutorialHarness.weekQuestion) }
		screen.exchange(TutorialHarness.remember)
		screen.relaunch(at: size)
		let newest = TutorialHarness.text(screen.run.app, containing: TutorialHarness.rememberReply)
		TutorialHarness.wait(newest, within: .turn)
		TutorialHarness.wait(
			until: {
				let band = TutorialHarness.transcriptBand(screen.run.app)
				return newest.frame.maxY > band.minY && newest.frame.minY < band.maxY
			}, message: "\(screen.name("scrolled-away")): the newest message is not on screen")
		XCTAssertFalse(
			screen.run.named(PlanSaveCardScreen.save).exists,
			"\(screen.name("scrolled-away")): Save plan exists before the card's title was on screen"
		)
		screen.capture("scrolled-away")
		let title = screen.run.named("chat.transcript").descendants(matching: .any)
			.matching(identifier: "chat.planSave.title").firstMatch
		ReviewCardScreen.reveal(screen.run.app, title, direction: .down)
		TutorialHarness.bringIntoTranscript(screen.run.app, title)
		screen.expectControls(true, of: plan, "scrolled-into-view")
		screen.expectBar(under: plan, "scrolled-into-view")
		screen.capture("scrolled-into-view")
	}

	static func reviewThenApprove(
		_ test: XCTestCase, _ language: LanguageTag, _ size: PlanCardSize
	) {
		let (screen, plan) = reviewAndPlanWaiting(test, language, size)
		let approve = screen.run.named("chat.preview.add")
		reachReview(screen)
		approve.tap()
		TutorialHarness.wait(approve, until: .absent, within: .turn)
		screen.waitForCard(plan, from: .up)
		screen.expectControls(true, of: plan, "approved-plan-waiting")
		screen.expectState(nil, of: plan, "approved-plan-waiting")
		screen.capture("approved-plan-waiting")
	}

	static func reviewThenSave(_ test: XCTestCase, _ language: LanguageTag, _ size: PlanCardSize) {
		let (screen, plan) = reviewAndPlanWaiting(test, language, size)
		let before = counts(screen)
		screen.waitForCard(plan, from: .up)
		screen.expectControls(true, of: plan, "before-save")
		tap(PlanSaveCardScreen.save, on: screen)
		screen.expectState(Catalog.chatPlanSaveSaved, of: plan, "saved-review-waiting")
		reachReview(screen)
		screen.capture("saved-review-waiting")
		XCTAssertEqual(
			counts(screen), before,
			"\(screen.name("saved-review-waiting")): saving the plan reached the model or the calendar"
		)
	}

	private static func reviewAndPlanWaiting(
		_ test: XCTestCase, _ language: LanguageTag, _ size: PlanCardSize
	) -> (PlanSaveCardScreen, PlanFixture) {
		let screen = PlanSaveCardScreen.begin(test, language, size)
		let plan = PlanFixture.weeks(12)
		screen.exchange(TutorialHarness.workout)
		screen.exchange(PlanFixture.directive)
		screen.show()
		screen.waitForCard(plan)
		screen.expectControls(true, of: plan, "both-waiting")
		reachReview(screen)
		let reviewBar = screen.run.named("chat.review.bar")
		let planBar = screen.run.named(PlanSaveCardScreen.bar)
		let transcript = screen.run.named("chat.transcript")
		switch size {
		case .standard:
			TutorialHarness.wait(planBar)
			XCTAssertFalse(
				transcript.descendants(matching: .any).matching(identifier: "chat.review.bar")
					.firstMatch.exists
					|| transcript.descendants(matching: .any)
						.matching(identifier: PlanSaveCardScreen.bar).firstMatch.exists,
				"\(screen.name("both-waiting")): a bar is in the transcript at the default size")
			XCTAssertTrue(
				ReviewCardReading.follows(reviewBar.frame, planBar.frame)
					&& planBar.frame.maxY
						<= screen.run.named("chat.composer.container").frame.minY + 1,
				"\(screen.name("both-waiting")): the review bar \(reviewBar.frame) and the plan bar \(planBar.frame) are not docked in order above the composer"
			)
		case .largest:
			XCTAssertTrue(
				transcript.descendants(matching: .any).matching(identifier: "chat.review.bar")
					.firstMatch.exists,
				"\(screen.name("both-waiting")): the review bar is not in the transcript")
			screen.expectBar(under: plan, "both-waiting")
			screen.expectDisclaimerLast("both-waiting")
		}
		screen.capture("both-waiting")
		return (screen, plan)
	}

	private static func reachReview(_ screen: PlanSaveCardScreen) {
		let approve = screen.run.named("chat.preview.add")
		ReviewCardScreen.reveal(screen.run.app, approve, direction: .down)
		TutorialHarness.wait(approve, until: .enabled, within: .turn)
		if screen.size == .largest { ReviewCardReading(run: screen.run).reach(.add) }
		TutorialHarness.wait(approve, until: .hittable)
	}

	private static func counts(_ screen: PlanSaveCardScreen) -> [String] {
		let app = screen.run.app
		TutorialHarness.openDebug(app)
		let calendar = TutorialHarness.debugRow(app, "fixture.calendarCalls").label
		let model = TutorialHarness.debugRow(app, "fixture.modelRequestCount").label
		TutorialHarness.returnToChat(app)
		return [calendar, model]
	}

	private static func expectDrawnOnceAtTheTop(
		_ screen: PlanSaveCardScreen, _ plan: PlanFixture, _ name: String
	) {
		screen.revealTitle(of: plan)
		let transcript = screen.run.named("chat.transcript")
		XCTAssertEqual(
			transcript.descendants(matching: .any).matching(identifier: "chat.planSave.title")
				.count, 1, "\(screen.name(name)): the carried card is not drawn exactly once")
		XCTAssertTrue(
			screen.run.named("chat.planSave.preparedEarlier").exists,
			"\(screen.name(name)): the carried card does not say it was prepared earlier")
		XCTAssertEqual(
			transcript.descendants(matching: .any).matching(identifier: "chat.turn.planSaveNotice")
				.count, 0)
	}
}
