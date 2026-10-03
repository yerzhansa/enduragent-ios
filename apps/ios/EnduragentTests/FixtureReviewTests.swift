import EnduragentCoach
import EnduragentCoachFixtures
import Foundation
import Testing

@testable import Enduragent

extension FixtureLaunchTests {
	@Test(arguments: [false, true])
	func unknownWriteNoticeAppearsOnlyOnTheCard(failedRead: Bool) async throws {
		let services = try services()
		let intervals = try #require(services.fixture?.intervals)
		let model = await model(services)
		await model.agreeAndStartChatting()
		model.trainingSettings.edit()
		model.connectKey = "fixture"
		await model.connect()
		try #require(model.didConnect)
		model.draft.text =
			"Give me a 60 minute endurance ride for tomorrow with two 10 minute tempo blocks"
		await model.send()
		try await until { model.chat?.review != nil }
		let review = try #require(model.chat?.review)
		await model.decide(.presented(review.ref))
		try await until {
			if case .approveOrCancel? = model.chat?.review?.controls { return true }
			return false
		}
		guard case .approveOrCancel(let token)? = model.chat?.review?.controls else {
			throw ReviewNotPresented()
		}
		intervals.writeFailure = URLError(.timedOut)
		await model.decide(.approve(token))
		try await until { model.chat?.review?.notice?.key == Catalog.reviewWritePending }
		if failedRead {
			let backing = try #require(services.fixture?.secretBacking)
			backing.locked = true
			defer { backing.locked = false }
			await model.decide(.checkAgain(review.ref))
			try await until { model.chat?.review?.notice?.key == Catalog.reviewWriteReadFailed }
		}
		let notice = try #require(model.chat?.review?.notice)
		let cardSentence = model.phrasebook.say(notice.key, notice.vars)
		let transcriptSentence = model.reviewNotice?.sentence(in: model.displayLocale)
		#expect([cardSentence, transcriptSentence].compactMap { $0 }.count == 1)
		#expect(
			cardSentence
				== model.phrasebook.say(
					failedRead ? Catalog.reviewWriteReadFailed : Catalog.reviewWritePending))
	}

	@Test(arguments: [false, true])
	func unknownWriteCanBeRecoveredThroughTheCard(cancel: Bool) async throws {
		let services = try services()
		let intervals = try #require(services.fixture?.intervals)
		let model = await model(services)
		await model.agreeAndStartChatting()
		let token = try await presentedReview(on: model)
		intervals.writeFailure = IntervalsError(code: "http", details: "Lost response", status: 502)
		await model.decide(.approve(token))
		try await until {
			guard case .checkAgain? = model.chat?.review?.controls else { return false }
			return true
		}
		let pending = try #require(model.chat?.review)
		let check = try #require(
			ConfirmedPreviewCard(model: model, review: pending).actions.first {
				$0.id == "chat.preview.checkAgain"
			})
		#expect(model.phrasebook.say(check.title) == "Check again")
		intervals.writeFailure = nil
		await model.decide(check.decision)
		try await until {
			guard case .retryRemainingOrCancel? = model.chat?.review?.controls else { return false }
			return true
		}
		let absent = try #require(model.chat?.review)
		let actions = ConfirmedPreviewCard(model: model, review: absent).actions
		#expect(actions.contains { $0.id == "chat.preview.checkAgain" })
		let action = try #require(
			actions.first { $0.id == (cancel ? "chat.preview.cancel" : "chat.preview.saveAgain") })
		await model.decide(action.decision)
		if cancel {
			try await until { model.chat?.review == nil && model.chat?.notes.count == 1 }
			#expect(
				model.chat?.notes.values.flatMap { $0 }.first?.sentence(in: model.displayLocale)
					== "Cancelled. This workout may still have been saved. Check your calendar.")
			#expect(model.reviewNotice == nil)
			#expect(!intervals.calls.contains { $0.isCalendarWrite })
		} else {
			#expect(model.reviewNotice == nil)
			try await until { model.chat?.review == nil && model.chat?.notes.count == 1 }
			#expect(intervals.calls.filter(\.isCalendarWrite).count == 1)
			#expect(
				model.chat?.notes.values.flatMap { $0 }.first?.sentence(in: model.displayLocale)
					.hasPrefix("Done") == true)
		}
	}

	@Test func failedRecoveryReadKeepsOnlyDisabledPreviousButtons() async throws {
		let services = try services()
		let intervals = try #require(services.fixture?.intervals)
		let faults = try #require(services.fixture?.records)
		let model = await model(services)
		await model.agreeAndStartChatting()
		let token = try await presentedReview(on: model)
		intervals.writeFailure = IntervalsError(code: "http", details: "Lost response", status: 502)
		await model.decide(.approve(token))
		try await until {
			guard case .checkAgain? = model.chat?.review?.controls else { return false }
			return true
		}
		faults.failFetches = true
		await model.decide(.presented(token.ref))
		try await until { model.chat?.review?.notice?.kind == .storageUnavailable }
		let failed = try #require(model.chat?.review)
		let actions = ConfirmedPreviewCard(model: model, review: failed).actions
		#expect(actions.map(\.id) == ["chat.preview.retryRead"])
		#expect(ConfirmedPreviewCard(model: model, review: failed).disabledButtons == [.checkAgain])
		#expect(failed.controls == .none)
		faults.failFetches = false
		await model.decide(.checkAgain(failed.ref))
		try await until {
			guard case .checkAgain? = model.chat?.review?.controls else { return false }
			return true
		}
		let recovered = try #require(model.chat?.review)
		#expect(
			ConfirmedPreviewCard(model: model, review: recovered).actions.map(\.id)
				== ["chat.preview.checkAgain"])
		#expect(!intervals.calls.contains { $0.isCalendarWrite })
	}

	@Test(arguments: [false, true])
	func reviewCardNoticeClearsWhenContinuingOrStartingANewConversation(newConversation: Bool)
		async throws
	{
		let services = try services()
		let backing = try #require(services.fixture?.secretBacking)
		let model = await model(services)
		await model.agreeAndStartChatting()
		let token = try await presentedReview(on: model)
		_ = try await settledTurn(model)
		backing.locked = true
		defer { backing.locked = false }
		await model.decide(.approve(token))
		try await until { model.chat?.review?.notice?.key == Catalog.reviewCannotVerify }
		let blocked = try #require(model.chat?.review)
		#expect(model.reviewNotice == nil)
		#expect(blocked.controls == .none)
		#expect(ConfirmedPreviewCard(model: model, review: blocked).actions.isEmpty)
		backing.locked = false

		if newConversation {
			await model.newConversation()
			#expect(model.reviewNotice == nil)
			#expect(!model.newConversationUncertain)
			try await until { model.chat?.turns.isEmpty == true }
		} else {
			model.draft.text = "How did Saturday go"
			await model.send()
			#expect(model.reviewNotice == nil)
			#expect(!model.notSent)
			#expect(model.draft.text.isEmpty)
			let turn = try await settledTurn(model, at: 1)
			#expect(turn.athleteText == "How did Saturday go")
		}
		#expect(model.reviewNotice == nil)
		#expect(model.chat?.review?.notice == nil)
	}

	@Test func canceledReviewStaysGoneAfterTheNextMessage() async throws {
		let services = try services()
		let model = await model(services)
		await model.agreeAndStartChatting()
		let token = try await presentedReview(on: model)

		await model.decide(.cancel(token))

		#expect(model.reviewNotice == nil)
		try await until { model.chat?.review == nil }
		let proposing = try await settledTurn(model)
		model.draft.text = "How did Saturday go"
		await model.send()
		_ = try await settledTurn(model, after: proposing.state)
		#expect(model.chat?.turns.count == 2)
		#expect(model.chat?.review == nil)
		#expect(
			services.fixture?.intervals.calls.contains(where: \.isCalendarWrite) == false)
	}

	@Test func failedVerificationShowsOneCardNoticeAndUnlockRestoresApproval() async throws {
		let services = try services()
		let backing = try #require(services.fixture?.secretBacking)
		let model = await model(services)
		await model.agreeAndStartChatting()
		let token = try await presentedReview(on: model)
		backing.locked = true
		defer { backing.locked = false }

		await model.decide(.approve(token))

		try await until { model.chat?.review?.notice?.key == Catalog.reviewCannotVerify }
		let blocked = try #require(model.chat?.review)
		let notice = try #require(blocked.notice)
		let cardSentence = model.phrasebook.say(notice.key, notice.vars)
		#expect(
			cardSentence
				== "Couldn't check your intervals.icu connection, so nothing was changed. Try again in a moment."
		)
		#expect(
			[cardSentence, model.reviewNotice?.sentence(in: model.displayLocale)]
				.compactMap { $0 }.count == 1)
		#expect(blocked.ref == token.ref)
		#expect(!blocked.cards.isEmpty)
		#expect(blocked.controls == .none)
		#expect(ConfirmedPreviewCard(model: model, review: blocked).actions.isEmpty)
		#expect(services.fixture?.intervals.calls.contains(where: \.isCalendarWrite) == false)
		await model.decide(.presented(token.ref))
		#expect(model.reviewNotice == nil)
		#expect(model.chat?.review?.notice?.key == Catalog.reviewCannotVerify)
		backing.locked = false
		await model.decide(.presented(token.ref))
		try await until {
			if case .approveOrCancel? = model.chat?.review?.controls { return true }
			return false
		}
		let restored = try #require(model.chat?.review)
		#expect(restored.notice == nil)
		let actions = ConfirmedPreviewCard(model: model, review: restored).actions
		#expect(actions.map(\.id) == ["chat.preview.cancel", "chat.preview.add"])
		await model.decide(try #require(actions.first { $0.button == .add }).decision)
		#expect(model.reviewNotice == nil)
		try await until { model.chat?.notes.values.flatMap { $0 }.count == 1 }
		#expect(
			model.chat?.notes.values.flatMap { $0 }.first?.sentence(in: model.displayLocale)
				== "Done — Create workout \"Endurance with tempo\" on 6/16/1998.")
		#expect(services.fixture?.intervals.calls.filter(\.isCalendarWrite).count == 1)
	}

	@Test(arguments: [false, true])
	func failedConnectionCheckKeepsTheCardsRecoveryActions(absent: Bool) async throws {
		let services = try services()
		let fixture = try #require(services.fixture)
		let model = await model(services)
		await model.agreeAndStartChatting()
		let token = try await presentedReview(on: model)
		fixture.intervals.writeFailure = URLError(.timedOut)
		await model.decide(.approve(token))
		try await until {
			guard case .checkAgain? = model.chat?.review?.controls else { return false }
			return true
		}
		if absent {
			await model.decide(.checkAgain(token.ref))
			try await until {
				guard case .retryRemainingOrCancel? = model.chat?.review?.controls else {
					return false
				}
				return true
			}
		}
		let pending = try #require(model.chat?.review)
		let expected = ConfirmedPreviewCard(model: model, review: pending).actions.map(\.id)
		#expect(
			expected
				== (absent
					? ["chat.preview.checkAgain", "chat.preview.cancel", "chat.preview.saveAgain"]
					: ["chat.preview.checkAgain"]))
		let backing = try #require(fixture.secretBacking)
		backing.locked = true
		defer { backing.locked = false }
		await model.decide(.checkAgain(pending.ref))
		try await until { model.chat?.review?.notice?.key == Catalog.reviewWriteReadFailed }
		let failed = try #require(model.chat?.review)
		let actions = ConfirmedPreviewCard(model: model, review: failed).actions
		#expect(actions.map(\.id) == expected)
		#expect(model.reviewNotice == nil)
		backing.locked = false
		let check = try #require(actions.first { $0.id == "chat.preview.checkAgain" })
		await model.decide(check.decision)
		try await until {
			guard case .retryRemainingOrCancel? = model.chat?.review?.controls else { return false }
			return true
		}
		#expect(!fixture.intervals.calls.contains { $0.isCalendarWrite })
	}

	@Test func reviewUsesTheChosenLanguageAfterAnAccountChange() async throws {
		let services = try services()
		let model = await model(services)
		await model.agreeAndStartChatting()
		let token = try await presentedReview(on: model)
		await model.chooseLanguage(.fixed(.fr))
		try await model.waitForStatus { $0.language == .fixed(.fr) }
		#expect(model.phrasebook.say(Catalog.reviewTitle, [:]) == "Vérification de la séance")
		#expect(model.phrasebook.say(Catalog.reviewAdd, [:]) == "Ajouter au calendrier")
		_ = await services.coach.changeTraining(
			.replaceConfirmingAthleteSwitch(apiKey: "other-athlete", athlete: .keyOwner))
		try await until { model.chat?.review?.notice?.kind == .accountChanged }
		await model.decide(.approve(token))
		let notice = try #require(model.chat?.review?.notice)
		#expect(notice.key == Catalog.reviewAccountChanged)
		#expect(
			model.phrasebook.say(notice.key, notice.vars).hasPrefix("Cette séance a été préparée"))
		#expect(model.reviewNotice == nil)
		#expect(model.chat?.review?.controls == ReviewControls.none)
	}

	func presentedReview(on model: ShellModel) async throws -> ReviewControlToken {
		model.trainingSettings.edit()
		model.connectKey = "fixture"
		await model.connect()
		try #require(model.didConnect)
		model.draft.text =
			"Give me a 60 minute endurance ride for tomorrow with two 10 minute tempo blocks"
		await model.send()
		try await until { model.chat?.review != nil }
		let review = try #require(model.chat?.review)
		await model.decide(.presented(review.ref))
		try await until { model.chat?.review?.controls != ReviewControls.none }
		guard case .approveOrCancel(let token)? = model.chat?.review?.controls else {
			throw ReviewNotPresented()
		}
		return token
	}
}

private struct ReviewNotPresented: Error {}

extension FakeIntervalsCall {
	var isCalendarWrite: Bool {
		switch self {
		case .createEvent, .updateEvent, .deleteEvent: true
		default: false
		}
	}
}
