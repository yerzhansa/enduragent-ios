import EnduragentCoach
import Testing

@testable import Enduragent

struct ReviewStageRow: Sendable, CustomTestStringConvertible {
	let stage: FixtureReviewStage
	let notice: CatalogKey
	let controls: ControlSet?

	var testDescription: String { stage.rawValue }

	static let all = [
		ReviewStageRow(
			stage: .partial, notice: Catalog.workoutsPartial, controls: .tryAgainOrCancel),
		ReviewStageRow(
			stage: .unconfirmed, notice: Catalog.workoutsUnconfirmed, controls: .checkAgainOrCancel),
		ReviewStageRow(
			stage: .refreshed, notice: Catalog.workoutsRefreshedNothingChanged,
			controls: .approveOrCancel),
		ReviewStageRow(
			stage: .blocked, notice: Catalog.workoutsBlockedMissing, controls: .cancelOnly),
		ReviewStageRow(stage: .storage, notice: Catalog.reviewStorageUnavailable, controls: nil),
	]
}

extension FixtureLaunchTests {
	@Test(arguments: ReviewStageRow.all)
	func eachReviewStageLaunchLeavesTheMixedReviewInItsStageWithOnlyItsControls(
		_ row: ReviewStageRow
	) async throws {
		var configured = launch
		configured.reviewStage = row.stage
		let model = await model(try fixtureServices(configured, defaults: defaults))
		await model.agreeAndStartChatting()
		let token = try await presentedReview(
			on: model, asking: FirstWeekFixture.reviewMixedDirective)

		await model.decide(.approve(token))

		try await until { model.chat?.review?.notice?.key == row.notice }
		let review = try #require(model.chat?.review)
		#expect(review.cards.count == 4)
		guard let controls = row.controls else {
			#expect(review.controls == .none)
			return
		}
		await model.decide(.presented(review.ref))
		try await until { model.chat?.review?.controls.offered != nil }
		#expect(model.chat?.review?.controls.offered == controls)
		#expect(model.chat?.review?.notice?.key == row.notice)
	}

	@Test func theNotPreparedDirectiveLeavesTheCouldNotBePreparedNoticeOnItsTurn() async throws {
		let model = await model(try services())
		await model.agreeAndStartChatting()
		model.trainingSettings.edit()
		model.connectKey = "fixture"
		await model.connect()
		try #require(model.didConnect)
		model.draft.text = FirstWeekFixture.reviewNotPreparedDirective

		await model.send()

		let turn = try await settledTurn(model)
		#expect(turn.reviewNotice?.key == Catalog.workoutsNotPrepared)
		#expect(model.chat?.review == nil)
	}
}
