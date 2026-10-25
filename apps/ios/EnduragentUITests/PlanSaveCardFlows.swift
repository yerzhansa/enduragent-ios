import EnduragentCoach
import XCTest

@MainActor
enum PlanSaveCard {
	static func lifecycle(_ test: XCTestCase, _ language: LanguageTag, _ size: PlanCardSize) {
		var arguments = FixtureArguments()
		arguments.planTap = .twice
		let screen = PlanSaveCardScreen.begin(test, language, size, arguments: arguments)
		let first = PlanFixture.weeks(12)
		screen.exchange(PlanFixture.directive)
		screen.show()
		screen.waitForCard(first)
		screen.expectOpening(first, newest: PlanFixture.reply, "waiting")
		screen.expectControls(true, of: first, "waiting")
		screen.expectBar(under: first, "waiting")
		screen.expectReadingOrder(first, screen.expected(first), "waiting")
		screen.expectValuesUnderLabels(of: first, "waiting")
		screen.expectWholeButtons("waiting")
		screen.expectDisclaimerLast("waiting")
		screen.capture("waiting")
		screen.audit("waiting")
		tap(PlanSaveCardScreen.save, on: screen)
		screen.expectControls(false, of: first, "saved")
		screen.expectState(Catalog.chatPlanSaveSaved, of: first, "saved")
		screen.expectAnswer(Catalog.chatPlanSaveNotSavedAlreadyDecided, of: first, "saved")
		screen.capture("saved")

		let second = PlanFixture.weeks(10)
		sendAtDefaultSize(PlanFixture.directive(weeks: 10), on: screen)
		screen.waitForCard(second)
		screen.expectOpening(second, newest: PlanFixture.reply, "replacing")
		screen.expectControls(true, of: second, "replacing")
		screen.expectReadingOrder(
			second, screen.expected(second, replaces: first.name), "replacing")
		screen.expectDisclaimerLast("replacing")
		screen.capture("replacing")
		tap(PlanSaveCardScreen.cancel, on: screen)
		screen.expectControls(false, of: second, "canceled")
		screen.expectState(Catalog.chatPlanSaveCanceled, of: second, "canceled")
		screen.expectLine(
			"chat.planSave.replaces", of: second,
			reading: screen.run.say(Catalog.chatPlanSaveReplaces, ["name": first.name]),
			"canceled")
		screen.capture("canceled")

		let third = PlanFixture.weeks(8)
		if size == .largest { screen.relaunch(at: .standard) }
		screen.exchange(PlanFixture.directive(weeks: 8))
		screen.relaunch(at: size)
		screen.waitForCard(third)
		screen.expectOpening(third, newest: PlanFixture.reply, "reopened")
		screen.expectControls(true, of: third, "reopened")
		screen.relaunch(at: size, clock: PlanFixture.laterClock)
		screen.waitForCard(third)
		screen.expectState(Catalog.chatPlanSaveExpired, of: third, "expired")
		screen.expectControls(false, of: third, "expired")
		screen.capture("expired")
	}

	static func saving(_ test: XCTestCase, _ language: LanguageTag, _ size: PlanCardSize) {
		var arguments = FixtureArguments()
		arguments.planSaveStage = .saving
		let (screen, plan) = waiting(test, language, size, arguments: arguments)
		tap(PlanSaveCardScreen.save, on: screen)
		screen.expectState(Catalog.chatPlanSaveSaving, of: plan, "saving")
		screen.expectControls(false, of: plan, "saving")
		screen.capture("saving")
		screen.relaunch(at: size)
		screen.waitForCard(plan)
		screen.expectState(Catalog.chatPlanSaveSaving, of: plan, "saving-reopened")
		screen.expectControls(false, of: plan, "saving-reopened")
		screen.capture("saving-reopened")
	}

	static func storage(_ test: XCTestCase, _ language: LanguageTag, _ size: PlanCardSize) {
		var arguments = FixtureArguments()
		arguments.planSaveStage = .storage
		let (screen, plan) = waiting(test, language, size, arguments: arguments)
		tap(PlanSaveCardScreen.save, on: screen)
		screen.expectState(Catalog.chatPlanSaveStorageUnavailable, of: plan, "storage")
		screen.expectAnswer(nil, of: plan, "storage")
		screen.expectControls(false, of: plan, "storage")
		screen.capture("storage")
		screen.audit("storage")
	}

	static func refusedAsExpired(
		_ test: XCTestCase, _ language: LanguageTag, _ size: PlanCardSize
	) {
		var arguments = FixtureArguments()
		arguments.planTap = .expired
		let (screen, plan) = waiting(test, language, size, arguments: arguments)
		tap(PlanSaveCardScreen.save, on: screen)
		screen.expectState(Catalog.chatPlanSaveExpired, of: plan, "refused-expired")
		screen.expectAnswer(Catalog.chatPlanSaveNotSavedExpired, of: plan, "refused-expired")
		screen.expectControls(false, of: plan, "refused-expired")
		screen.capture("refused-expired")
		screen.audit("refused-expired")
	}

	static func refusedAsReplaced(
		_ test: XCTestCase, _ language: LanguageTag, _ size: PlanCardSize
	) {
		var arguments = FixtureArguments()
		arguments.planTap = .replaced
		let (screen, plan) = waiting(test, language, size, arguments: arguments)
		tap(PlanSaveCardScreen.save, on: screen)
		let newer = PlanFixture.weeks(10)
		screen.waitForCard(newer, from: .up)
		screen.expectControls(true, of: newer, "refused-replaced-newer")
		screen.waitForCard(plan)
		screen.expectState(Catalog.chatPlanSaveExpired, of: plan, "refused-replaced")
		screen.expectAnswer(Catalog.chatPlanSaveNotSavedReplaced, of: plan, "refused-replaced")
		screen.capture("refused-replaced")
		screen.audit("refused-replaced")
	}

	static func athleteChanged(_ test: XCTestCase, _ language: LanguageTag, _ size: PlanCardSize) {
		let screen = PlanSaveCardScreen.begin(test, language, size)
		let plan = PlanFixture.weeks(12)
		screen.exchange(PlanFixture.directive)
		TutorialHarness.fixtureControl(screen.run.app, "fixture.switchAthlete")
		screen.show()
		screen.waitForCard(plan)
		screen.expectControls(true, of: plan, "athlete-changed")
		tap(PlanSaveCardScreen.save, on: screen)
		screen.expectAnswer(
			Catalog.chatPlanSaveNotSavedAthleteChanged, ["service": "intervals.icu"], of: plan,
			"athlete-changed")
		screen.expectControls(true, of: plan, "athlete-changed")
		let state = screen.part("chat.planSave.state", of: plan)
		XCTAssertFalse(
			state.exists && state.label == screen.run.say(Catalog.chatPlanSaveSaved),
			"\(screen.name("athlete-changed")): the plan was saved for another athlete")
		screen.capture("athlete-changed")
		screen.audit("athlete-changed")
	}

	static func longName(_ test: XCTestCase, _ language: LanguageTag, _ size: PlanCardSize) {
		let screen = PlanSaveCardScreen.begin(test, language, size)
		let plan = PlanFixture.long
		screen.exchange(PlanFixture.longDirective)
		screen.show()
		screen.waitForCard(plan)
		screen.expectOpening(plan, newest: PlanFixture.reply, "long")
		screen.expectControls(true, of: plan, "long")
		screen.expectWholeName(plan, "long")
		screen.expectValuesUnderLabels(of: plan, "long")
		screen.expectReadingOrder(plan, screen.expected(plan), "long")
		screen.expectWholeButtons("long")
		screen.capture("long")
		screen.audit("long")
	}

	static func notPrepared(_ test: XCTestCase, _ language: LanguageTag, _ size: PlanCardSize) {
		let screen = PlanSaveCardScreen.begin(test, language, size)
		screen.exchange(PlanFixture.notPreparedDirective)
		screen.show()
		let notice = screen.run.app.descendants(matching: .any).matching(
			NSPredicate(
				format: "identifier == %@ AND label == %@", "chat.turn.planSaveNotice",
				screen.run.say(Catalog.chatPlanSaveNotPrepared))
		).firstMatch
		TutorialHarness.wait(notice, within: .turn)
		XCTAssertFalse(
			screen.run.named("chat.planSave.title").exists,
			"\(screen.name("not-prepared")): a card was drawn for a plan that was not prepared")
		screen.capture("not-prepared")
		screen.audit("not-prepared")
	}

	static func waiting(
		_ test: XCTestCase, _ language: LanguageTag, _ size: PlanCardSize,
		arguments: FixtureArguments
	) -> (PlanSaveCardScreen, PlanFixture) {
		let screen = PlanSaveCardScreen.begin(test, language, size, arguments: arguments)
		let plan = PlanFixture.weeks(12)
		screen.exchange(PlanFixture.directive)
		screen.show()
		screen.waitForCard(plan)
		screen.expectControls(true, of: plan, "waiting")
		return (screen, plan)
	}

	static func tap(_ identifier: String, on screen: PlanSaveCardScreen) {
		switch screen.size {
		case .standard:
			screen.run.tap(identifier)
		case .largest:
			let button = ReviewCardReading(run: screen.run).reach(identifier)
			TutorialHarness.wait(button, until: .hittable)
			button.tap()
		}
	}

	static func sendAtDefaultSize(_ text: String, on screen: PlanSaveCardScreen) {
		if screen.size == .largest { screen.relaunch(at: .standard) }
		screen.exchange(text)
		if screen.size == .largest { screen.relaunch(at: .largest) }
	}
}
