import EnduragentCoach
import Foundation
import Testing

@testable import Enduragent

extension FixtureLaunchTests {
	@Test(arguments: [false, true])
	func reviewNoticeClearsWhenContinuingOrStartingANewConversation(newConversation: Bool)
		async throws
	{
		let services = try services()
		let secrets = try #require(services.fixtureDirector?.secrets)
		let model = model(services)
		model.startChatting()
		let token = try await presentedReview(on: model)
		_ = try await settledTurn(model)
		secrets.locked = true
		await model.decide(.approve(token))
		try #require(model.reviewNotice?.key == Catalog.reviewCannotVerify)
		secrets.locked = false

		if newConversation {
			await model.newConversation()
			#expect(model.reviewNotice == nil)
			#expect(!model.newConversationUncertain)
			try await waitUntil { model.chat?.turns.isEmpty == true }
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
	}

	@Test func canceledReviewStaysGoneAfterTheNextMessage() async throws {
		let services = try services()
		let model = model(services)
		model.startChatting()
		let token = try await presentedReview(on: model)

		await model.decide(.cancel(token))

		#expect(model.reviewNotice == nil)
		try await waitUntil { model.chat?.review == nil }
		let proposing = try await settledTurn(model)
		model.draft.text = "How did Saturday go"
		await model.send()
		_ = try await settledTurn(model, after: proposing.state)
		#expect(model.chat?.turns.count == 2)
		#expect(model.chat?.review == nil)
		#expect(
			services.fixtureDirector?.intervals.calls.contains(where: \.isCalendarWrite) == false)
	}

	@Test func onlyATapShowsTheReviewOutcome() async throws {
		let services = try services()
		let secrets = try #require(services.fixtureDirector?.secrets)
		let model = model(services)
		model.startChatting()
		let token = try await presentedReview(on: model)
		secrets.locked = true

		await model.decide(.approve(token))

		#expect(
			model.reviewNotice?.sentence(in: model.phrasebook)
				== "Couldn't check your intervals.icu connection, so nothing was changed. Try again in a moment."
		)
		await model.decide(.presented(token.ref))
		#expect(model.reviewNotice?.key == Catalog.reviewCannotVerify)
		secrets.locked = false
		await model.decide(.approve(token))
		#expect(model.reviewNotice == nil)
		try await waitUntil { model.chat?.notes.count == 1 }
		#expect(
			model.chat?.notes.first?.sentence(in: model.phrasebook)
				== "Done — Create workout \"Endurance with tempo\" on 1998-06-16.")
	}

	@Test func reviewUsesTheChosenLanguageAfterAnAccountChange() async throws {
		let services = try services()
		let model = model(services)
		model.startChatting()
		let token = try await presentedReview(on: model)
		await model.chooseLanguage(.fixed(.fr))
		#expect(model.phrasebook.say(Catalog.reviewTitle, [:]) == "Vérification de la séance")
		#expect(model.phrasebook.say(Catalog.reviewAdd, [:]) == "Ajouter au calendrier")
		_ = await services.coach.changeTraining(
			.replaceConfirmingAthleteSwitch(apiKey: "other-athlete", athlete: .keyOwner))
		try await waitUntil { model.chat?.review?.notice?.kind == .accountChanged }
		await model.decide(.approve(token))
		let notice = try #require(model.reviewNotice)
		#expect(notice.key == Catalog.reviewAccountChanged)
		#expect(notice.sentence(in: model.phrasebook).hasPrefix("Cette séance a été préparée"))
		#expect(model.chat?.review?.controls == ReviewControls.none)
	}

	private func presentedReview(on model: ShellModel) async throws -> ReviewControlToken {
		model.connectKey = "fixture"
		await model.connect()
		try #require(model.didConnect)
		model.draft.text =
			"Give me a 60 minute endurance ride for tomorrow with two 10 minute tempo blocks"
		await model.send()
		try await waitUntil { model.chat?.review != nil }
		let review = try #require(model.chat?.review)
		await model.decide(.presented(review.ref))
		try await waitUntil { model.chat?.review?.controls != ReviewControls.none }
		guard case .approveOrCancel(let token)? = model.chat?.review?.controls else {
			throw ReviewNotPresented()
		}
		return token
	}

	private func waitUntil(_ condition: () -> Bool) async throws {
		let deadline = ContinuousClock.now + .seconds(20)
		while !condition(), ContinuousClock.now < deadline {
			try await Task.sleep(for: .milliseconds(20))
		}
		try #require(condition())
	}
}

private struct ReviewNotPresented: Error {}

extension FakeIntervalsCall {
	fileprivate var isCalendarWrite: Bool {
		switch self {
		case .createEvent, .updateEvent, .deleteEvent: true
		default: false
		}
	}
}
