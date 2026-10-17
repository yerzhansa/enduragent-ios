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
	@Test func theArmedCardsButtonsEachCarryItsTokenAndAnUnarmedCardHasNone() async throws {
		let services = try fixtureServices(launch, defaults: defaults)
		let model = await model(services)
		await model.agreeAndStartChatting()
		model.trainingSettings.edit()
		model.connectKey = "fixture"
		await model.connect()
		try #require(model.didConnect)
		model.draft.text = TutorialCopy.rideRequest
		await model.send()
		try await until { model.chat?.review != nil }
		let unarmed = try #require(model.chat?.review)
		#expect(ConfirmedPreviewCard(model: model, review: unarmed).actions.isEmpty)
		await model.decide(.presented(unarmed.ref))
		try await until { model.chat?.review?.controls != ReviewControls.none }
		let armed = try #require(model.chat?.review)
		let token = try #require(armed.controls.approveToken)
		let card = ConfirmedPreviewCard(model: model, review: armed)
		#expect(card.actions.map(\.decision) == [.cancel(token), .approve(token)])
		#expect(card.actions.map(\.title) == [Catalog.commonCancel, Catalog.reviewAdd])
		#expect(card.disabledButtons.isEmpty)
	}

	@Test func aReviewThatDeletesOffersApplyChangesAndNoAddToCalendar() async throws {
		let services = try fixtureServices(launch, defaults: defaults)
		let model = await model(services)
		await model.agreeAndStartChatting()
		model.trainingSettings.edit()
		model.connectKey = "fixture"
		await model.connect()
		try #require(model.didConnect)
		model.draft.text = FirstWeekFixture.reviewDeleteDirective
		await model.send()
		try await until { model.chat?.review != nil }
		let shown = try #require(model.chat?.review)
		await model.decide(.presented(shown.ref))
		try await until { model.chat?.review?.controls != ReviewControls.none }
		let card = ConfirmedPreviewCard(model: model, review: try #require(model.chat?.review))
		#expect(shown.cards.map(\.action) == [.delete])
		#expect(card.actions.map(\.title) == [Catalog.commonCancel, Catalog.workoutsApprove])
	}
}
