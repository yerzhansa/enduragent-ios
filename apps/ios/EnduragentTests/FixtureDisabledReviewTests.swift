import EnduragentCoach
import Foundation
import Testing

@testable import Enduragent

extension FixtureLaunchTests {
	enum SavedButtonLayout: CaseIterable { case approval, checkAgain, repeatApproval, cancelOnly }

	@Test(arguments: SavedButtonLayout.allCases)
	func failedReadRetainsLabelsWithoutIntentsAndRestoresThem(layout: SavedButtonLayout)
		async throws
	{
		let services = try services()
		let fixture = try #require(services.fixture)
		let model = await model(services)
		await model.agreeAndStartChatting()
		model.trainingSettings.edit()
		model.connectKey = "fixture"
		await model.connect()
		model.draft.text =
			"Give me a 60 minute endurance ride for tomorrow with two 10 minute tempo blocks"
		await model.send()
		_ = try await settledTurn(model)
		let initial = try #require(model.chat?.review)
		await model.decide(.presented(initial.ref))
		try await until {
			if case .approveOrCancel? = model.chat?.review?.controls { return true }
			return false
		}
		if layout != .approval {
			guard case .approveOrCancel(let token)? = model.chat?.review?.controls else {
				throw DisabledReviewFixtureFailure()
			}
			fixture.intervals.writeFailure = URLError(.timedOut)
			await model.decide(.approve(token))
			try await until {
				if case .checkAgain? = model.chat?.review?.controls { return true }
				return false
			}
			fixture.intervals.writeFailure = nil
			if layout == .repeatApproval {
				await model.decide(.checkAgain(token.ref))
			} else if layout == .cancelOnly {
				try fixture.secrets.storeIntervalsConnection(
					IntervalsConnection(
						id: ConnectionID(), credential: .apiKey("fixture-athlete-b"),
						selection: .keyOwner,
						resolvedAthlete: IntervalsAthleteID(rawValue: "i2002")))
				await model.decide(.presented(token.ref))
			}
		}
		let expected: [ConfirmedPreviewButton] =
			switch layout {
			case .approval: [.cancel, .add]
			case .checkAgain: [.checkAgain]
			case .repeatApproval: [.checkAgain, .cancel, .saveAgain]
			case .cancelOnly: [.cancel]
			}
		try await until {
			guard let review = model.chat?.review else { return false }
			return ConfirmedPreviewCard(model: model, review: review).actions.map(\.button)
				== expected
		}
		let ready = try #require(model.chat?.review)
		fixture.records.failNextReviewRead()
		await model.decide(.presented(ready.ref))
		try await until { model.chat?.review?.notice?.key == Catalog.reviewStorageUnavailable }
		let failed = try #require(model.chat?.review)
		let card = ConfirmedPreviewCard(model: model, review: failed)
		#expect(card.actions.map(\.id) == ["chat.preview.retryRead"])
		#expect(card.actions.first?.decision == .checkAgain(failed.ref))
		#expect(card.disabledButtons == expected)
		#expect(failed.cards == ready.cards)
		#expect(model.reviewNotice == nil)
		#expect(
			model.phrasebook.say(try #require(failed.notice?.key))
				== "Couldn't read the saved workout review. Its buttons are temporarily disabled.")
		let calls = fixture.intervals.calls
		let requests = fixture.transport.requestCount
		fixture.records.failFetches = true
		await model.decide(try #require(card.actions.first).decision)
		#expect(model.chat?.review == failed)
		#expect(model.reviewNotice == nil)
		#expect(
			ConfirmedPreviewCard(model: model, review: failed).actions.map(\.id) == [
				"chat.preview.retryRead"
			])
		fixture.records.failFetches = false
		await model.decide(try #require(card.actions.first).decision)
		try await until {
			guard let review = model.chat?.review else { return false }
			return review.notice?.kind != .storageUnavailable
				&& ConfirmedPreviewCard(model: model, review: review).actions.map(\.button)
					== expected
		}
		#expect(fixture.intervals.calls == calls)
		#expect(fixture.transport.requestCount == requests)
	}
}

private struct DisabledReviewFixtureFailure: Error {}
