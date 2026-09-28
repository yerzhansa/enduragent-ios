import EnduragentCoach
import XCTest

extension TutorialHarness {
	static func completeOnboarding(_ app: XCUIApplication, language: LanguageTag = .en) {
		let phrasebook = CatalogPhrasebook(tag: language, locale: language.defaultLocale)
		waitForLabel(app, phrasebook.say(Catalog.onboardingNoticeHealth))
		named(app, "notice.continue").tap()
		let key = named(app, "connect.apiKey")
		wait(key)
		key.tap()
		key.typeText("fixture")
		named(app, "connect.connect").tap()
		wait(named(app, "connect.athleteName"))
		XCTAssertEqual(named(app, "connect.athleteName").label, "Ada Kovač")
		XCTAssertEqual(
			named(app, "connect.fitness").label,
			phrasebook.say(Catalog.onboardingConnectFitness, ["value": "42"]))
		XCTAssertEqual(
			named(app, "connect.fatigue").label,
			phrasebook.say(Catalog.onboardingConnectFatigue, ["value": "49"]))
		XCTAssertEqual(
			named(app, "connect.form").label,
			phrasebook.say(Catalog.onboardingConnectForm, ["value": "-7"]))
		named(app, "connect.continue").tap()
		wait(named(app, "starter.credits"))
		XCTAssertEqual(
			named(app, "starter.credits").label,
			phrasebook.say(Catalog.creditsBalance, ["count": "200", "formattedCount": "200"]))
		named(app, "starter.start").tap()
		wait(named(app, "chat.composer"))
		wait(named(app, "chat.welcome"))
	}

	static func startUnconnected(_ app: XCUIApplication) {
		waitForLabel(app, notice)
		named(app, "notice.continue").tap()
		let skip = named(app, "connect.skip")
		wait(skip)
		skip.tap()
		let start = named(app, "starter.start")
		wait(start)
		start.tap()
	}
}
