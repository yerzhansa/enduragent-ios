import EnduragentCoach
import XCTest

@MainActor
final class CreditsPurchaseProof: XCTestCase {
	private static let small = "icu.enduragent.app.credits.small"

	func testOutOfCreditsBuyCreditsBuysAPackAndTheCoachRepliesOnCredits() {
		let app = XCUIApplication()
		TutorialHarness.launch(app, arguments: FixtureArguments(creditsOutcome: .zero))
		TutorialHarness.completeOnboarding(app)
		TutorialHarness.exchange(app, "fixture:fail 402")
		TutorialHarness.wait(TutorialHarness.notice(app, reading: TutorialHarness.creditsExhausted))
		TutorialHarness.attach(self, name: "purchase-out-of-credits", app: app)
		TutorialHarness.named(app, "chat.turn.buyCredits").tap()
		TutorialHarness.waitForIdentifier(app, "credits.balance", reading: "0 credits")
		TutorialHarness.attach(self, name: "purchase-credits-screen", app: app)
		buy(app)
		TutorialHarness.waitForIdentifier(
			app, "credits.purchaseNotice", reading: "Added 401 credits")
		TutorialHarness.waitForIdentifier(app, "credits.balance", reading: "401 credits")
		XCTAssertFalse(TutorialHarness.named(app, "credits.notice").exists)
		TutorialHarness.attach(self, name: "purchase-added", app: app)
		TutorialHarness.returnToChat(app)
		TutorialHarness.exchange(app, TutorialHarness.weekQuestion)
		TutorialHarness.waitForLabel(app, "Two solid rides with a quieter stretch between them.")
		TutorialHarness.attach(self, name: "purchase-reply-on-credits", app: app)
	}

	func testABuyFromAnOpenRouterAccountSwitchesTheCoachToCredits() {
		let app = XCUIApplication()
		TutorialHarness.launch(app, arguments: FixtureArguments(accessMethod: .openRouter))
		TutorialHarness.completeOnboarding(app)
		openCredits(app)
		buy(app)
		TutorialHarness.waitForIdentifier(
			app, "credits.purchaseNotice",
			reading: "Added 401 credits. The coach now uses Credits.")
		TutorialHarness.waitForIdentifier(app, "credits.balance", reading: "601 credits")
		TutorialHarness.attach(self, name: "purchase-switched-to-credits", app: app)
		TutorialHarness.returnToChat(app)
		TutorialHarness.openSettings(app)
		TutorialHarness.named(app, "settings.accessMethod").tap()
		let credits = TutorialHarness.named(app, "access.credits")
		TutorialHarness.wait(credits, until: .hittable)
		XCTAssertTrue(credits.isSelected)
		XCTAssertFalse(TutorialHarness.named(app, "access.openRouter").isSelected)
		TutorialHarness.attach(self, name: "purchase-access-method-credits", app: app)
	}

	func testEachPurchaseOutcomeShowsItsSentence() {
		let outcomes: [(FixturePurchaseOutcome, String?)] = [
			(
				.pending,
				"Apple is still processing this purchase. The Credits are added when it's done."
			),
			(.cancel, nil),
			(.fail, "The purchase didn't finish."),
			(
				.notAddedYet,
				"Your purchase went through, but the Credits weren't added yet. The app tries again the next time it opens."
			),
			(
				.refused,
				"Your purchase went through, but the Credits can't be added. You can ask Apple for a refund."
			),
		]
		for (outcome, sentence) in outcomes {
			let app = XCUIApplication()
			TutorialHarness.launch(app, arguments: FixtureArguments(purchase: outcome))
			TutorialHarness.completeOnboarding(app)
			openCredits(app)
			buy(app)
			let buyButton = TutorialHarness.named(app, "credits.buy.\(Self.small)")
			TutorialHarness.wait(buyButton, until: .hittable)
			if let sentence {
				TutorialHarness.waitForIdentifier(app, "credits.purchaseNotice", reading: sentence)
			} else {
				XCTAssertFalse(TutorialHarness.named(app, "credits.purchaseNotice").exists)
			}
			TutorialHarness.waitForIdentifier(app, "credits.balance", reading: "200 credits")
			TutorialHarness.attach(self, name: "purchase-\(outcome.rawValue)", app: app)
			if outcome == .refused {
				let refund = TutorialHarness.named(app, "credits.purchaseAction")
				TutorialHarness.wait(refund, until: .hittable)
				XCTAssertEqual(refund.label, "Ask Apple for a refund")
				refund.tap()
				TutorialHarness.wait(
					TutorialHarness.named(app, "credits.purchaseNotice"), until: .absent)
				TutorialHarness.attach(self, name: "purchase-refund-requested", app: app)
			} else {
				XCTAssertFalse(TutorialHarness.named(app, "credits.purchaseAction").exists)
			}
			app.terminate()
		}
	}

	func testCreditsThatCannotBeBoughtSaySoWithoutBuyButtons() {
		let app = XCUIApplication()
		TutorialHarness.launch(app, arguments: FixtureArguments(purchase: .notForSale))
		TutorialHarness.completeOnboarding(app)
		openCredits(app)
		TutorialHarness.waitForIdentifier(
			app, "credits.notForSale",
			reading: "Credits can't be bought right now. Try again later.")
		XCTAssertFalse(TutorialHarness.named(app, "credits.buy.\(Self.small)").exists)
		TutorialHarness.waitForIdentifier(app, "credits.balance", reading: "200 credits")
		TutorialHarness.attach(self, name: "purchase-not-for-sale", app: app)
	}

	private func openCredits(_ app: XCUIApplication) {
		TutorialHarness.openSettings(app)
		TutorialHarness.named(app, "settings.credits").tap()
		TutorialHarness.waitForIdentifier(
			app, "credits.pack.\(Self.small)", reading: "401 credits · $4.99")
	}

	private func buy(_ app: XCUIApplication) {
		let buy = TutorialHarness.named(app, "credits.buy.\(Self.small)")
		TutorialHarness.wait(buy, until: .hittable)
		buy.tap()
	}
}
