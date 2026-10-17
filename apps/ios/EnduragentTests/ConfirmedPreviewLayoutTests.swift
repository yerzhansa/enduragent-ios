import EnduragentCoach
import Testing

@testable import Enduragent

struct ConfirmedPreviewLayoutTests {
	@Test func eachControlSetShowsItsOwnButtonsInReadingOrder() {
		#expect(ConfirmedPreviewButton.layout(of: .approveOrCancel) == [.cancel, .add])
		#expect(ConfirmedPreviewButton.layout(of: .tryAgainOrCancel) == [.tryAgain, .cancel])
		#expect(ConfirmedPreviewButton.layout(of: .checkAgainOrCancel) == [.checkAgain, .cancel])
		#expect(ConfirmedPreviewButton.layout(of: .cancelOnly) == [.cancel])
	}
}

extension FixtureLaunchTests {
	@Test func theBarArmsOnlyAfterEveryCardAppearedAndEachButtonCarriesItsToken() async throws {
		let model = try await reviewing(TutorialCopy.rideRequest, launch: launch)
		let unarmed = try #require(model.chat?.review)
		#expect(ReviewBarView(model: model, review: unarmed).actions.isEmpty)
		for card in unarmed.cards {
			await model.cardAppeared(card)
		}
		try await until { model.chat?.review?.controls != ReviewControls.none }
		let armed = try #require(model.chat?.review)
		let token = try #require(armed.controls.approveToken)
		let bar = ReviewBarView(model: model, review: armed)
		#expect(bar.actions.map(\.decision) == [.cancel(token), .approve(token)])
		#expect(bar.actions.map(\.title) == [Catalog.commonCancel, Catalog.reviewAdd])
		#expect(bar.disabledButtons.isEmpty)
	}

	@Test func aReviewThatDeletesOffersRemoveFromCalendarAndNoAddToCalendar() async throws {
		let model = try await reviewing(FirstWeekFixture.reviewDeleteDirective, launch: launch)
		let shown = try #require(model.chat?.review)
		for card in shown.cards {
			await model.cardAppeared(card)
		}
		try await until { model.chat?.review?.controls != ReviewControls.none }
		let bar = ReviewBarView(model: model, review: try #require(model.chat?.review))
		#expect(shown.cards.map(\.action) == [.delete])
		#expect(
			bar.actions.map(\.title) == [Catalog.commonCancel, Catalog.workoutsBarApproveDeletions])
	}

	@Test func theFailingLastCardHookLeavesNoControlUntilTheReviewIsShownAgainWhole() async throws {
		var faulted = launch
		faulted.presentationFault = .failLastCardOnce
		let model = try await reviewing(FirstWeekFixture.reviewFortyDirective, launch: faulted)
		let shown = try #require(model.chat?.review)
		#expect(shown.cards.count == 40)
		for card in shown.cards {
			await model.cardAppeared(card)
		}
		let failed = try #require(model.reviewPresentation)
		#expect(failed.failure == 39)
		#expect(model.chat?.review?.controls == ReviewControls.none)
		#expect(ReviewBarView(model: model, review: shown).actions.isEmpty)

		await model.showReviewAgain()
		try await until { model.chat?.review.map { $0.ref != shown.ref } == true }
		let renewed = try #require(model.chat?.review)
		#expect(model.reviewPresentation?.round == 1)
		for card in renewed.cards {
			#expect(model.chat?.review?.controls == ReviewControls.none)
			await model.cardAppeared(card)
		}
		try await until { model.chat?.review?.controls != ReviewControls.none }
		let bar = ReviewBarView(model: model, review: try #require(model.chat?.review))
		#expect(bar.actions.map(\.title) == [Catalog.commonCancel, Catalog.reviewAdd])
	}

	private func reviewing(_ text: String, launch: FixtureLaunch) async throws -> ShellModel {
		let services = try fixtureServices(launch, defaults: defaults)
		let model = await model(services)
		await model.agreeAndStartChatting()
		model.trainingSettings.edit()
		model.connectKey = "fixture"
		await model.connect()
		try #require(model.didConnect)
		model.draft.text = text
		await model.send()
		try await until { model.chat?.review != nil }
		return model
	}
}
