import EnduragentCoach
import EnduragentCoachFixtures
import Foundation
import Observation
import Testing

@testable import Enduragent

extension FixtureLaunchTests {
	@Test(arguments: [false, true])
	func unknownWriteCanBeRecoveredThroughTheCard(cancel: Bool) async throws {
		let services = try services()
		let intervals = try #require(services.fixture?.intervals)
		let model = model(services)
		await model.agreeAndStartChatting()
		let token = try await presentedReview(on: model)
		intervals.writeFailure = IntervalsError(code: "http", details: "Lost response", status: 502)
		await model.decide(.approve(token))
		try await waitUntil {
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
		try await waitUntil {
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
			#expect(model.reviewNotice?.key == Catalog.reviewWritePending)
			try await waitUntil {
				guard case .checkAgain? = model.chat?.review?.controls else { return false }
				return true
			}
			#expect(!intervals.calls.contains { $0.isCalendarWrite })
		} else {
			#expect(model.reviewNotice == nil)
			try await waitUntil { model.chat?.review == nil && model.chat?.notes.count == 1 }
			#expect(intervals.calls.filter(\.isCalendarWrite).count == 1)
			#expect(
				model.chat?.notes.first?.sentence(in: model.phrasebook).hasPrefix("Done") == true)
		}
	}

	@Test(arguments: [false, true])
	func reviewNoticeClearsWhenContinuingOrStartingANewConversation(newConversation: Bool)
		async throws
	{
		let services = try services()
		let backing = try #require(services.fixture?.secretBacking)
		let model = model(services)
		await model.agreeAndStartChatting()
		let token = try await presentedReview(on: model)
		_ = try await settledTurn(model)
		backing.locked = true
		await model.decide(.approve(token))
		try #require(model.reviewNotice?.key == Catalog.reviewCannotVerify)
		backing.locked = false

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
		await model.agreeAndStartChatting()
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
			services.fixture?.intervals.calls.contains(where: \.isCalendarWrite) == false)
	}

	@Test func onlyATapShowsTheReviewOutcome() async throws {
		let services = try services()
		let backing = try #require(services.fixture?.secretBacking)
		let model = model(services)
		await model.agreeAndStartChatting()
		let token = try await presentedReview(on: model)
		backing.locked = true

		await model.decide(.approve(token))

		#expect(
			model.reviewNotice?.sentence(in: model.phrasebook)
				== "Couldn't check your intervals.icu connection, so nothing was changed. Try again in a moment."
		)
		await model.decide(.presented(token.ref))
		#expect(model.reviewNotice?.key == Catalog.reviewCannotVerify)
		backing.locked = false
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
		await model.agreeAndStartChatting()
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

	private func waitUntil(_ condition: @escaping @MainActor () -> Bool) async throws {
		while !condition() {
			await withCheckedContinuation { continuation in
				withObservationTracking {
					if condition() { continuation.resume() }
				} onChange: {
					continuation.resume()
				}
			}
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
