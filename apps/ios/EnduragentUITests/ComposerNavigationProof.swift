import XCTest

@MainActor
final class ComposerNavigationProof: XCTestCase {
	func testFocusedDraftRemainsReachableAfterEveryPushedScreen() {
		continueAfterFailure = false
		let app = XCUIApplication()
		TutorialHarness.launch(app)
		TutorialHarness.completeOnboarding(app)
		TutorialHarness.exchange(app, TutorialHarness.weekQuestion)
		TutorialHarness.startNewConversation(app)
		TutorialHarness.exchange(app, TutorialHarness.weekQuestion)
		let composer = TutorialHarness.named(app, "chat.composer")
		composer.tap()
		composer.typeText(TutorialHarness.draft)
		assertComposer(app, name: "before-navigation", requiresKeyboard: true)
		TutorialHarness.openSettings(app)
		returnToDraft(app, name: "settings")
		let settingsChildren = [
			("settings.credits", TutorialHarness.named(app, "credits.balance")),
			("settings.training", TutorialHarness.named(app, "training.edit")),
		]
		for (identifier, content) in settingsChildren {
			TutorialHarness.openSettings(app)
			let link = TutorialHarness.named(app, identifier)
			TutorialHarness.wait(link, until: .hittable)
			link.tap()
			TutorialHarness.wait(content)
			returnToDraft(app, name: identifier)
		}
		TutorialHarness.openDebug(app)
		returnToDraft(app, name: "debug")
		let debugChildren = [
			("debug.records", TutorialHarness.named(app, "records.device")),
			("debug.credits", TutorialHarness.named(app, "debug.credits.claimStarter")),
			("debug.session", TutorialHarness.named(app, "session.historyBudgetRatio.stored")),
			("debug.leases", app.navigationBars["Leases"]),
		]
		for (identifier, content) in debugChildren {
			TutorialHarness.openDebug(app)
			TutorialHarness.debugRow(app, identifier).tap()
			TutorialHarness.wait(content)
			returnToDraft(app, name: identifier)
		}
		TutorialHarness.openDebug(app)
		TutorialHarness.debugRow(app, "debug.language").tap()
		let french = TutorialHarness.named(app, "language.choice.fr")
		TutorialHarness.wait(french, until: .hittable)
		french.tap()
		TutorialHarness.wait(until: { french.isSelected }, message: "French was not selected")
		returnToDraft(app, name: "changed-language")
		TutorialHarness.openHistory(app)
		TutorialHarness.wait(TutorialHarness.historyRows(app).firstMatch, until: .hittable)
		returnToDraft(app, name: "history")
		TutorialHarness.openHistory(app)
		let archived = TutorialHarness.historyRows(app).firstMatch
		TutorialHarness.wait(archived, until: .hittable)
		archived.tap()
		TutorialHarness.wait(TutorialHarness.named(app, "archive.readOnly"))
		returnToDraft(app, name: "archived-conversation")
		composer.typeText("!")
		TutorialHarness.wait(composer, until: .value(TutorialHarness.draft + "!"))
		TutorialHarness.attach(self, name: "composer-navigation-edited-draft", app: app)
	}

	private func returnToDraft(_ app: XCUIApplication, name: String) {
		let composer = TutorialHarness.named(app, "chat.composer")
		XCTAssertFalse(composer.exists && composer.isHittable)
		TutorialHarness.returnToChat(app)
		assertComposer(app, name: "\(name)-returned")
		TutorialHarness.named(app, "chat.composer").tap()
		assertComposer(app, name: "\(name)-refocused", requiresKeyboard: true)
	}

	private func assertComposer(
		_ app: XCUIApplication, name: String, requiresKeyboard: Bool = false
	) {
		let composer = TutorialHarness.named(app, "chat.composer")
		let container = TutorialHarness.named(app, "chat.composer.container")
		let keyboard = app.keyboards.firstMatch
		let settled = TutorialHarness.wait(
			until: {
				guard composer.exists, composer.isHittable,
					composer.value as? String == TutorialHarness.draft,
					container.exists, app.frame.contains(container.frame)
				else { return false }
				if keyboard.exists {
					return container.frame.maxY <= keyboard.frame.minY
				}
				return !requiresKeyboard && container.frame.maxY >= app.frame.maxY - 60
			}, required: false,
			message: "\(name): draft must be hittable above the keyboard or at the screen bottom")
		let keyboardFrame = keyboard.exists ? keyboard.frame : .null
		let composerFrame = composer.exists ? composer.frame : .null
		let containerFrame = container.exists ? container.frame : .null
		let hittable = composer.exists && composer.isHittable
		let draft = composer.exists ? String(describing: composer.value) : "absent"
		let frames = XCTAttachment(
			string:
				"keyboard \(keyboard.exists) \(keyboardFrame), composer \(composerFrame), container \(containerFrame), hittable \(hittable), draft \(draft)"
		)
		frames.name = "composer-navigation-\(name)-frames"
		frames.lifetime = .keepAlways
		add(frames)
		TutorialHarness.attach(self, name: "composer-navigation-\(name)", app: app)
		XCTAssertTrue(
			settled, "\(name): draft must be hittable above the keyboard or at the screen bottom")
	}
}
