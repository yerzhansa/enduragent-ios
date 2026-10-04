import EnduragentCoach
import EnduragentCoachFixtures
import XCTest

@MainActor
final class ModelPickerProof: XCTestCase {
	private let builtIn = "deepseek/deepseek-v4.1-flash-20260910"
	private let anthropic = "anthropic/claude-sonnet-4.5"
	private let refreshed = "fixture/refreshed-model"
	private var phrasebook: CatalogPhrasebook { CatalogPhrasebook(tag: .en) }

	func testChoosingAndRelaunchingKeepsTheMarkedModel() {
		let app = launch(response: .newer)
		openPicker(app, cache: "downloaded available")
		assertSelected(app, builtIn, name: "DeepSeek V4.1 Flash", provider: "DeepSeek")
		choose(app, refreshed)
		assertSelected(app, refreshed, name: "Refreshed Coach", provider: "DeepSeek")
		XCTAssertFalse(row(app, builtIn).isSelected)
		capture(app, "chosen")
		TutorialHarness.returnToChat(app)
		TutorialHarness.relaunchKeepingStore(app)
		TutorialHarness.wait(TutorialHarness.named(app, "chat.composer"))
		openPicker(app, cache: "downloaded retained stale")
		assertSelected(app, refreshed, name: "Refreshed Coach", provider: "DeepSeek")
		capture(app, "chosen-reopened")
		TutorialHarness.returnToChat(app)
		assertReply(app)
	}

	func testRefreshKeepsSelectedNameAfterRelaunch() {
		for response in [FixtureCatalogResponse.newer, .omittedSelectedModel] {
			let app = launch()
			openPicker(app, cache: "bundled retained offline")
			assertSelected(app, builtIn, name: "DeepSeek V4.1 Flash", provider: "DeepSeek")
			capture(app, "bundled-before-\(response.rawValue)")
			relaunch(app, response: response)
			openPicker(app, cache: "downloaded available")
			assertSelected(app, builtIn, name: "DeepSeek V4.1 Flash", provider: "DeepSeek")
			TutorialHarness.wait(row(app, refreshed), until: .hittable)
			TutorialHarness.wait(row(app, anthropic), until: .hittable)
			capture(app, "\(response.rawValue)")
			relaunch(app, response: .offline)
			openPicker(app, cache: "downloaded retained offline")
			assertSelected(app, builtIn, name: "DeepSeek V4.1 Flash", provider: "DeepSeek")
			TutorialHarness.wait(row(app, refreshed), until: .hittable)
			capture(app, "\(response.rawValue)-reopened")
			TutorialHarness.returnToChat(app)
			assertReply(app)
			app.terminate()
		}
	}

	func testFailedRefreshesKeepChoicesTappableAndCoachingAvailable() {
		let failures: [(FixtureCatalogResponse, String)] = [
			(.malformed, "malformed"), (.stale, "stale"), (.offline, "offline"),
			(.empty, "noUsableChoices"),
		]
		for (response, issue) in failures {
			let app = launch(response: .newer)
			openPicker(app, cache: "downloaded available")
			choose(app, refreshed)
			assertSelected(app, refreshed, name: "Refreshed Coach", provider: "DeepSeek")
			relaunch(app, response: response)
			openPicker(app, cache: "downloaded retained \(issue)")
			assertSelected(app, refreshed, name: "Refreshed Coach", provider: "DeepSeek")
			TutorialHarness.wait(row(app, anthropic), until: .hittable)
			capture(app, "retained-\(response.rawValue)")
			choose(app, builtIn)
			assertSelected(app, builtIn, name: "DeepSeek V4.1 Flash", provider: "DeepSeek")
			XCTAssertFalse(row(app, refreshed).isSelected)
			capture(app, "selected-after-\(response.rawValue)")
			TutorialHarness.returnToChat(app)
			assertReply(app)
			capture(app, "reply-after-\(response.rawValue)")
			app.terminate()
		}
	}

	func testCreditsHidePickerAndLeavingOrFailedSaveKeepsTheChoice() {
		let credits = launch(access: .credits)
		TutorialHarness.openSettings(credits)
		XCTAssertFalse(TutorialHarness.named(credits, "settings.model").exists)
		XCTAssertFalse(TutorialHarness.named(credits, "model.choices").exists)
		capture(credits, "credits-no-picker")
		TutorialHarness.returnToChat(credits)
		TutorialHarness.assertZeroFixtureRequests(credits)
		credits.terminate()
		for fails in [false, true] {
			let app = launch(response: .newer, fault: fails ? .failSelection : nil)
			openPicker(app, cache: "downloaded available")
			assertSelected(app, builtIn, name: "DeepSeek V4.1 Flash", provider: "DeepSeek")
			if fails {
				choose(app, refreshed)
				TutorialHarness.waitForIdentifier(
					app, "model.notice",
					reading:
						"Couldn't save your choice on this iPhone, so nothing was changed. Try again."
				)
				XCTAssertFalse(row(app, refreshed).isSelected)
			}
			assertSelected(app, builtIn, name: "DeepSeek V4.1 Flash", provider: "DeepSeek")
			capture(app, fails ? "save-failed" : "leave-without-choice")
			TutorialHarness.returnToChat(app)
			TutorialHarness.relaunchKeepingStore(app)
			TutorialHarness.wait(TutorialHarness.named(app, "chat.composer"))
			openPicker(app, cache: "downloaded retained stale")
			assertSelected(app, builtIn, name: "DeepSeek V4.1 Flash", provider: "DeepSeek")
			capture(app, fails ? "save-failed-reopened" : "unchanged-reopened")
			TutorialHarness.returnToChat(app)
			assertReply(app)
			app.terminate()
		}
	}

	func testAnotherProviderRequiresConsentAndDecliningSendsNothing() {
		let app = launch()
		openPicker(app, cache: "bundled retained offline")
		choose(app, anthropic)
		assertAnthropicConsent(app)
		capture(app, "another-provider-consent")
		TutorialHarness.named(app, "consent.decline").tap()
		TutorialHarness.wait(TutorialHarness.named(app, "chat.composer"), until: .hittable)
		TutorialHarness.openDebug(app)
		XCTAssertEqual(
			TutorialHarness.debugRow(app, "fixture.modelRequestCount").label, "0 model requests")
		TutorialHarness.returnToChat(app)
		openPicker(app, cache: "bundled retained offline")
		assertSelected(app, builtIn, name: "DeepSeek V4.1 Flash", provider: "DeepSeek")
		XCTAssertFalse(row(app, anthropic).isSelected)
		capture(app, "another-provider-declined")
		choose(app, anthropic)
		assertAnthropicConsent(app)
		TutorialHarness.agreeToProviderConsent(
			app, recipient: (model: "Claude Sonnet 4.5", provider: "Anthropic"))
		openPicker(app, cache: "bundled retained offline")
		assertSelected(app, anthropic, name: "Claude Sonnet 4.5", provider: "Anthropic")
		capture(app, "another-provider-accepted")
		TutorialHarness.relaunchKeepingStore(app)
		TutorialHarness.wait(TutorialHarness.named(app, "chat.composer"))
		openPicker(app, cache: "bundled retained offline")
		assertSelected(app, anthropic, name: "Claude Sonnet 4.5", provider: "Anthropic")
		capture(app, "another-provider-reopened")
		TutorialHarness.returnToChat(app)
		assertReply(app)
	}

	func testFailedSaveAfterAnotherProviderConsentKeepsThePreviousModel() {
		let app = launch(fault: .failSelection)
		TutorialHarness.openSettings(app)
		TutorialHarness.wait(TutorialHarness.named(app, "settings.model"), until: .hittable)
		capture(app, "settings-row")
		TutorialHarness.returnToChat(app)
		openPicker(app, cache: "bundled retained offline")
		assertSelected(app, builtIn, name: "DeepSeek V4.1 Flash", provider: "DeepSeek")
		choose(app, anthropic)
		assertAnthropicConsent(app)
		TutorialHarness.named(app, "consent.accept").tap()
		TutorialHarness.waitForIdentifier(
			app, "consent.error",
			reading: "Couldn't save your choice on this iPhone, so nothing was changed. Try again.")
		TutorialHarness.waitForIdentifier(
			app, "consent.modelRequestCount", reading: "0 model requests")
		capture(app, "another-provider-save-failed")
		TutorialHarness.named(app, "consent.decline").tap()
		TutorialHarness.wait(TutorialHarness.named(app, "chat.composer"), until: .hittable)
		XCTAssertFalse(TutorialHarness.named(app, "consent.resume").exists)
		capture(app, "another-provider-save-failed-declined")
		openPicker(app, cache: "bundled retained offline")
		assertSelected(app, builtIn, name: "DeepSeek V4.1 Flash", provider: "DeepSeek")
		XCTAssertFalse(row(app, anthropic).isSelected)
		capture(app, "another-provider-save-failed-kept")
		TutorialHarness.relaunchKeepingStore(app)
		TutorialHarness.wait(TutorialHarness.named(app, "chat.composer"), until: .hittable)
		XCTAssertFalse(TutorialHarness.named(app, "consent.accept").exists)
		openPicker(app, cache: "bundled retained offline")
		assertSelected(app, builtIn, name: "DeepSeek V4.1 Flash", provider: "DeepSeek")
		capture(app, "another-provider-save-failed-reopened")
		TutorialHarness.returnToChat(app)
		assertReply(app)
	}

	private func launch(
		access: FixtureAccessMethod = .catalogOpenRouter,
		response: FixtureCatalogResponse = .offline, fault: FixtureCredentialWriteFault? = nil
	) -> XCUIApplication {
		let app = XCUIApplication()
		TutorialHarness.launch(
			app,
			arguments: FixtureArguments(
				onboarded: true, credentialWriteFault: fault,
				accessMethod: access, catalogResponse: response))
		TutorialHarness.agreeToProviderConsent(app)
		return app
	}

	private func relaunch(_ app: XCUIApplication, response: FixtureCatalogResponse) {
		app.terminate()
		var arguments = FixtureArguments()
		do {
			try arguments.update(from: app.launchArguments)
		} catch {
			XCTFail("Could not read catalog launch arguments: \(error)")
			return
		}
		arguments.store = .keep
		arguments.catalogResponse = response
		TutorialHarness.launch(app, arguments: arguments)
		TutorialHarness.wait(TutorialHarness.named(app, "chat.composer"))
	}

	private func openPicker(_ app: XCUIApplication, cache: String) {
		TutorialHarness.openSettings(app)
		let picker = TutorialHarness.named(app, "settings.model")
		TutorialHarness.wait(picker, until: .hittable)
		picker.tap()
		TutorialHarness.wait(TutorialHarness.named(app, "model.choices"))
		TutorialHarness.waitForIdentifier(app, "fixture.catalogState", reading: cache)
	}

	private func row(_ app: XCUIApplication, _ id: String) -> XCUIElement {
		TutorialHarness.named(app, "model.choices").descendants(matching: .any)
			.matching(identifier: "model.choice.\(id)").firstMatch
	}

	private func choose(_ app: XCUIApplication, _ id: String) {
		let choice = row(app, id)
		TutorialHarness.wait(choice, until: .hittable)
		TutorialHarness.wait(choice, until: .enabled)
		choice.tap()
	}

	private func assertSelected(
		_ app: XCUIApplication, _ id: String, name: String, provider: String
	) {
		let choice = row(app, id)
		TutorialHarness.wait(
			until: { choice.exists && choice.isSelected },
			message: "The picker did not mark \(id)")
		XCTAssertEqual(
			choice.label,
			phrasebook.say(Catalog.setupAiModelVia, ["model": name, "provider": provider]))
	}

	private func assertAnthropicConsent(_ app: XCUIApplication) {
		TutorialHarness.waitForIdentifier(
			app, "consent.body",
			reading: phrasebook.say(
				Catalog.onboardingConsentBody,
				["model": "Claude Sonnet 4.5", "provider": "Anthropic"]))
		TutorialHarness.waitForIdentifier(
			app, "consent.modelRequestCount", reading: "0 model requests")
		XCTAssertFalse(TutorialHarness.named(app, "chat.composer").exists)
	}

	private func assertReply(_ app: XCUIApplication) {
		TutorialHarness.exchange(app, TutorialHarness.weekQuestion)
		TutorialHarness.waitForLabel(app, TutorialHarness.weekReply)
		TutorialHarness.assertZeroFixtureRequests(app)
	}

	private func capture(_ app: XCUIApplication, _ scenario: String) {
		let appearance = TutorialHarness.meanLuminance(app.screenshot()) < 0.4 ? "dark" : "light"
		TutorialHarness.attach(self, name: "model-picker-\(scenario)-\(appearance)", app: app)
	}
}
