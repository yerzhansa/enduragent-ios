import EnduragentCoach
import EnduragentCoachFixtures
import XCTest

@MainActor
enum LanguageMatrix {
	static func onboarding(_ test: XCTestCase, _ language: LanguageTag) {
		let app = XCUIApplication()
		TutorialHarness.launch(app, language: language.rawValue)
		let run = MatrixRun(test: test, app: app, language: language)
		run.expectText(Catalog.onboardingNoticeHealth)
		run.expect("notice.continue", Catalog.commonContinue)
		run.screen("onboarding-notice")
		run.tap("notice.continue")
		let key = app.secureTextFields["connect.apiKey"]
		TutorialHarness.wait(key, until: .hittable)
		XCTAssertEqual(
			key.placeholderValue, run.say(Catalog.onboardingConnectApiKey), language.rawValue)
		run.expect("connect.connect", Catalog.onboardingConnectAction)
		run.expect("connect.skip", Catalog.onboardingConnectSkip)
		run.screen("onboarding-connect")
		TutorialHarness.type(app, "fixture", into: "connect.apiKey")
		run.tap("connect.connect")
		run.expect("connect.athleteID", Catalog.settingsTrainingAthlete, ["id": "i1001"])
		run.expect("connect.fitness", Catalog.onboardingConnectFitness, ["value": "42"])
		run.expect("connect.fatigue", Catalog.onboardingConnectFatigue, ["value": "49"])
		run.expect("connect.form", Catalog.onboardingConnectForm, ["value": "-7"])
		run.expect("connect.continue", Catalog.languageContinue)
		run.screen("onboarding-connected")
		run.tap("connect.continue")
		run.expect("starter.useCredits", Catalog.creditsTitle)
		run.expect("starter.openRouter", Catalog.accessSignIn)
		run.expect("starter.start", Catalog.onboardingStarterStart)
		run.expectTitle(Catalog.accessTitle)
		run.screen("onboarding-access")
		run.tap("starter.start")
		run.expectText(Catalog.onboardingConsentTitle)
		run.expect(
			"consent.body", Catalog.onboardingConsentBody,
			["model": "DeepSeek V4.1 Flash", "provider": "DeepSeek"])
		run.expect("consent.accept", Catalog.onboardingConsentAccept)
		run.expect("consent.decline", Catalog.onboardingConsentDecline)
		run.screen("onboarding-consent")
		run.tap("consent.accept")
		TutorialHarness.waitForWelcome(app, language: language)
		run.expectChrome()
		run.screen("conversation-welcome")
	}

	static func conversation(_ test: XCTestCase, _ language: LanguageTag) {
		let run = MatrixRun.begin(test, language)
		let app = run.app
		TutorialHarness.waitForWelcome(app, language: language)
		run.expectChrome()
		let composer = run.named("chat.composer")
		composer.tap()
		composer.typeText("/")
		for command in SlashCommand.allCases {
			run.expect("chat.slash.\(command.rawValue.dropFirst())", contains: command.menuTitle)
		}
		run.screen("command-choices")
		composer.typeText("language")
		run.tap("chat.send")
		run.expect("language.choice.automatic", Catalog.commonAutomatic)
		run.expectTitle(Catalog.languageChooseTitle)
		run.screen("command-language-picker")
		LanguagePickerEntry.command.close(app)
		TutorialHarness.exchange(app, TutorialHarness.workout)
		let add = run.named("chat.preview.add")
		TutorialHarness.wait(add, until: .enabled)
		run.expectText(Catalog.reviewTitle)
		run.expect("chat.preview.add", Catalog.reviewAdd)
		run.expect("chat.preview.cancel", Catalog.commonCancel)
		run.screen("review")
		add.tap()
		let done = run.named("chat.note")
		TutorialHarness.wait(done)
		XCTAssertTrue(done.label.contains("Endurance with tempo"), done.label)
		XCTAssertEqual(done.label == TutorialHarness.done, language == .en, done.label)
		run.screen("review-approved")
		TutorialHarness.send(app, "fixture:text-then-hang")
		TutorialHarness.waitForLabel(app, "This week has Tuesday sweet spot")
		TutorialHarness.wait(app.keyboards.firstMatch, until: .absent)
		run.expect("chat.working", Catalog.chatNoticeWorking)
		let stop = run.named("chat.stop")
		let send = run.named("chat.send")
		for button in [stop, send] {
			TutorialHarness.wait(button, until: .hittable)
			XCTAssertEqual(button.elementType, .button)
			TutorialHarness.assertIconButtonWidth(button)
			XCTAssertEqual(button.staticTexts.count, 0, "the button title must not be drawn")
		}
		XCTAssertEqual(stop.label, run.say(Catalog.chatComposerStop), language.rawValue)
		XCTAssertEqual(send.label, run.say(Catalog.chatComposerSend), language.rawValue)
		run.screen("working-stop-send")
		stop.tap()
		TutorialHarness.wait(stop, until: .absent)
		run.expectNotice(Catalog.chatTurnInterruptedNothingChanged)
		run.expect("chat.turn.tryAgain", Catalog.chatTranscriptRetry)
		run.screen("stopped-reply")
		TutorialHarness.startNewConversation(app, language: language)
		let started = run.named("chat.newConversation.notice")
		TutorialHarness.wait(started)
		XCTAssertTrue(
			[
				run.say(Catalog.chatNoticeNewConversationSuccess),
				run.say(Catalog.chatNoticeNewConversationMemoryWarning),
			].contains(started.label), started.label)
		run.screen("new-conversation")
	}

	static func settings(_ test: XCTestCase, _ language: LanguageTag) {
		let run = MatrixRun.begin(test, language)
		let app = run.app
		TutorialHarness.exchange(app, TutorialHarness.workout)
		TutorialHarness.wait(run.named("chat.preview.add"), until: .enabled)
		TutorialHarness.openSettings(app)
		run.expectTitle(Catalog.settingsTitle)
		run.expect("settings.accessMethod", Catalog.accessTitle)
		run.expect("settings.credits", Catalog.creditsTitle)
		run.expect("settings.training", Catalog.settingsTrainingTitle)
		run.expect("settings.language", contains: Catalog.settingsLanguageTitle)
		run.expect("settings.session", Catalog.settingsSessionTitle)
		run.screen("settings")
		run.tap("settings.accessMethod")
		run.expect("access.credits", Catalog.creditsTitle)
		run.expect("access.openRouter", Catalog.accessSignIn)
		run.expectTitle(Catalog.accessTitle)
		run.screen("settings-access-method")
		TutorialHarness.returnToChat(app)
		run.openSettingsRow("settings.credits")
		run.expect("credits.note", Catalog.creditsTesters)
		run.expect("credits.switchToOpenRouter", Catalog.accessSwitchToOpenRouter)
		run.expectTitle(Catalog.creditsTitle)
		run.screen("settings-credits")
		TutorialHarness.returnToChat(app)
		run.openSettingsRow("settings.session")
		run.expect("session.historyBudgetRatio.unit", Catalog.settingsSessionUnitsPercent)
		run.expect("session.contextWindowOverride.unit", Catalog.settingsSessionUnitsTokens)
		run.expectText(Catalog.settingsConversationFieldsHistoryTokenBudgetRatioLabel)
		run.expectText(Catalog.settingsSessionContextWindowLabel)
		run.expectTitle(Catalog.settingsSessionTitle)
		run.screen("settings-session")
		TutorialHarness.returnToChat(app)
		run.openSettingsRow("settings.training")
		run.expect("training.athleteID", Catalog.settingsTrainingAthlete, ["id": "i1001"])
		run.expect("training.edit", Catalog.settingsTrainingReplace)
		run.expect("training.keep", Catalog.settingsTrainingKeep)
		run.expect("training.disconnect", Catalog.settingsTrainingDisconnect)
		run.expectTitle(Catalog.settingsTrainingTitle)
		run.screen("settings-training")
		run.tap("training.edit")
		TutorialHarness.type(app, "other-athlete", into: "training.apiKey")
		run.tap("training.save")
		let alert = app.alerts.firstMatch
		TutorialHarness.wait(alert)
		let sentence = run.say(
			Catalog.settingsTrainingSwitchDetail, ["current": "i1001", "new": "i2002"])
		let cancel = alert.buttons[run.say(Catalog.commonCancel)]
		XCTAssertTrue(alert.staticTexts[run.say(Catalog.settingsTrainingSwitchTitle)].exists)
		XCTAssertTrue(
			alert.staticTexts.matching(NSPredicate(format: "label == %@", sentence)).firstMatch
				.exists, sentence)
		XCTAssertTrue(alert.buttons[run.say(Catalog.settingsTrainingSwitch)].exists)
		XCTAssertTrue(cancel.exists)
		run.screen("settings-switch-athlete")
		cancel.tap()
		TutorialHarness.wait(alert, until: .absent)
		TutorialHarness.returnToChat(app)
		TutorialHarness.fixtureControl(app, "fixture.failNextAppend")
		LanguagePickerEntry.settings.open(app)
		run.tap("language.choice.automatic")
		run.expect("language.saveFailed", Catalog.reviewSaveFailed)
		XCTAssertFalse(run.named("language.choice.automatic").isSelected)
		run.expectTitle(Catalog.languageChooseTitle)
		run.screen("language-choice-not-saved")
		LanguagePickerEntry.settings.close(app)
	}

	static func failures(_ test: XCTestCase, _ language: LanguageTag) {
		let run = MatrixRun.begin(test, language)
		let app = run.app
		TutorialHarness.exchange(app, "fixture:fail 402")
		run.expectNotice(Catalog.creditsErrorExhausted)
		run.expect("chat.turn.buyCredits", Catalog.chatTurnBuyCredits)
		run.expect("chat.turn.switchToOpenRouter", Catalog.accessSwitchToOpenRouter)
		run.screen("out-of-credits")
		TutorialHarness.exchange(app, "fixture:fail 400")
		run.expectNotice(Catalog.coachErrorUnknown)
		run.expect("chat.turn.tryAgain", Catalog.chatTranscriptRetry)
		run.screen("failed-reply")
		TutorialHarness.relaunchKeepingStore(app, keychain: .locked)
		TutorialHarness.send(app, TutorialHarness.weekQuestion)
		run.expectNotice(Catalog.accessErrorLocked)
		run.screen("locked-iphone")
		TutorialHarness.relaunchKeepingStore(app, keychain: .unavailable)
		run.expect("chat.composer.notice", Catalog.accessErrorStorageUnavailable)
		run.screen("secure-storage-unavailable")
		run.openSettingsRow("settings.training")
		run.expect("training.notice", Catalog.connectErrorStorageUnavailable)
		run.expect("training.displayAction", Catalog.chatTranscriptRetry)
		run.screen("training-storage-unavailable")
		TutorialHarness.returnToChat(app)
		TutorialHarness.relaunchKeepingStore(app, keychain: .unlocked)
		TutorialHarness.fixtureControl(app, "fixture.failNextAppend")
		TutorialHarness.send(app, TutorialHarness.draft)
		run.expect("chat.composer.notSent", Catalog.chatComposerNotSent)
		run.screen("draft-not-sent")
	}

	static func history(_ test: XCTestCase, _ language: LanguageTag) {
		let run = MatrixRun.begin(test, language)
		let app = run.app
		TutorialHarness.openHistory(app)
		run.expectText(Catalog.archiveEmpty)
		run.expectTitle(Catalog.archiveHistory)
		run.screen("history-empty")
		TutorialHarness.returnToChat(app)
		TutorialHarness.openDebug(app)
		TutorialHarness.debugRow(app, "fixture.seedOwnership").tap()
		let seeded = TutorialHarness.debugRow(app, "fixture.ownershipSeedResult")
		TutorialHarness.wait(
			until: { seeded.label == "seeded" }, message: "Ownership fixture was not seeded")
		TutorialHarness.returnToChat(app)
		TutorialHarness.fixtureControl(app, "fixture.switchAthlete")
		TutorialHarness.exchange(app, "Read the connected athlete's week")
		TutorialHarness.openHistory(app)
		let saved = AthleteOwnershipFixture.savedChat.rawValue
		TutorialHarness.wait(run.named("history.row.\(saved)"))
		run.expect(
			"history.athlete.\(saved)", Catalog.archiveSavedForAnotherAthlete, ["id": "i1001"])
		run.screen("history-earlier-athlete")
		run.tap("history.row.\(AthleteOwnershipFixture.unknownChat.rawValue)")
		TutorialHarness.wait(run.named("archive.content"))
		run.expect("archive.readOnly", Catalog.archiveReadOnly)
		run.expectTitle(Catalog.archiveConversation)
		run.screen("history-conversation")
		TutorialHarness.returnToChat(app)
	}

	static func uncertainSave(_ test: XCTestCase, _ language: LanguageTag) {
		let run = MatrixRun.begin(
			test, language, arguments: FixtureArguments(calendarSaveFault: .loseAnswerOnce))
		let app = run.app
		TutorialHarness.exchange(app, TutorialHarness.workout)
		TutorialHarness.wait(run.named("chat.preview.add"), until: .enabled)
		run.tap("chat.preview.add")
		run.expect("chat.preview.notice", Catalog.reviewWritePending)
		run.expect("chat.preview.checkAgain", Catalog.setupTelegramCheckAgain)
		run.screen("review-save-uncertain")
		TutorialHarness.relaunchKeepingStore(app)
		TutorialHarness.wait(run.named("chat.preview.checkAgain"), until: .enabled)
		TutorialHarness.fixtureControl(app, "fixture.failReviewRead")
		run.expect("chat.preview.notice", Catalog.reviewStorageUnavailable)
		run.expect("chat.preview.retryRead", Catalog.chatTranscriptRetry)
		run.screen("review-unreadable")
		run.tap("chat.preview.retryRead")
		TutorialHarness.wait(run.named("chat.preview.retryRead"), until: .absent)
		TutorialHarness.wait(run.named("chat.preview.checkAgain"), until: .enabled)
		run.tap("chat.preview.checkAgain")
		run.expect("chat.preview.saveAgain", Catalog.reviewSaveApprovedAgain)
		run.expect("chat.preview.cancel", Catalog.commonCancel)
		run.screen("review-save-again")
		run.tap("chat.preview.cancel")
		run.expect("chat.note", Catalog.reviewCancelledUnknown)
		run.screen("review-cancelled")
	}

	static func openRouter(_ test: XCTestCase, _ language: LanguageTag) {
		let run = MatrixRun.begin(
			test, language,
			arguments: FixtureArguments(onboarded: true, accessMethod: .catalogOpenRouter))
		let app = run.app
		TutorialHarness.exchange(app, "fixture:fail 403")
		run.expectNotice(Catalog.accessErrorRequestBlocked)
		XCTAssertFalse(run.named("chat.turn.tryAgain").exists)
		run.screen("openrouter-blocked-request")
		TutorialHarness.openSettings(app)
		run.expect("settings.model", contains: Catalog.settingsCoachModel)
		run.screen("settings-openrouter")
		run.tap("settings.model")
		TutorialHarness.wait(run.named("model.choices"))
		run.expect(
			"model.choice.deepseek/deepseek-v4.1-flash-20260910", Catalog.setupAiModelVia,
			["model": "DeepSeek V4.1 Flash", "provider": "DeepSeek"])
		run.expectTitle(Catalog.settingsCoachChooseModel)
		run.screen("settings-model")
		TutorialHarness.returnToChat(app)
	}
}
