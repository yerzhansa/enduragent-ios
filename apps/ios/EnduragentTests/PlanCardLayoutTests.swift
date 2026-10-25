import EnduragentCoach
import Testing

@testable import Enduragent

extension FixtureLaunchTests {
	@Test func aPreparedPlanShowsItsNameGoalLengthAndEveryPhaseUnderItsTurn() async throws {
		let model = try await preparing(FirstWeekFixture.planSaveDirective, launch: launch)
		let turn = try await settledTurn(model)
		let card = try #require(model.chat?.plans.first)
		let display = model.displayLocale
		let text = PlanCardText(card, answer: nil, in: display)
		#expect(card.placement == .afterTurn(turn.id))
		#expect(text.title == "Save this training plan?")
		#expect(text.preparedEarlier == nil)
		#expect(text.name == "12-Week Gran Fondo Plan")
		#expect(
			text.identity == [
				pair("goal", "Goal", "Finish the June gran fondo"),
				pair("duration", "Duration", "12 weeks"),
			])
		#expect(
			text.phases == [
				phase(
					1, focus: "Base building", weeks: "5 weeks",
					hours: display.number(7, precision: .compact)),
				phase(
					2, focus: "Threshold", weeks: "5 weeks",
					hours: display.number(8.5, precision: .compact)),
				phase(
					3, focus: "Taper", weeks: "2 weeks",
					hours: display.number(4.5, precision: .compact)),
			])
		#expect(text.replaces == nil)
		#expect(text.state == nil)
		#expect(text.answer == nil)
	}

	@Test func aSparsePlanLeavesOutEveryFieldItLacks() async throws {
		let model = try await preparing(FirstWeekFixture.planSaveSparseDirective, launch: launch)
		let text = PlanCardText(
			try #require(model.chat?.plans.first), answer: nil, in: model.displayLocale)
		#expect(text.name == FirstWeekFixture.planSaveSparseName)
		#expect(text.identity.isEmpty)
		#expect(
			text.phases == [
				PlanCardText.Phase(
					title: "Phase 1", pairs: [pair("focus", "Focus", "General fitness")]),
				PlanCardText.Phase(
					title: "Phase 2", pairs: [pair("weeks", "Duration", "3 weeks")]),
				PlanCardText.Phase(
					title: "Phase 3",
					pairs: [
						pair(
							"hours", "Hours per week",
							model.displayLocale.number(5.5, precision: .compact))
					]),
			])
		#expect(text.replaces == nil)
	}

	@Test func noSaveControlExistsUntilTheTitleIsPresentedAndThenBothDecisionsCarryItsToken()
		async throws
	{
		let model = try await preparing(FirstWeekFixture.planSaveDirective, launch: launch)
		let shown = try #require(model.chat?.plans.first)
		#expect(shown.state == .waiting(.unarmed))
		#expect(shown.armedToken == nil)
		await model.planDecisions.present(shown.ref)
		let token = try await armed(model)
		#expect(token.ref == shown.ref)
		await model.planDecisions.decide(.cancel(token))
		try await until { model.chat?.plans.first?.state == .canceled }
		let canceled = try #require(model.chat?.plans.first)
		#expect(canceled.armedToken == nil)
		#expect(
			PlanCardText(canceled, answer: nil, in: model.displayLocale).state
				== "Canceled. This plan was not saved.")
		#expect(model.planDecisions.answers[canceled.id] == nil)
	}

	@Test func aSecondPlanNamesTheSavedPlanItReplacesAndTheSavedCardNamesNone() async throws {
		let model = try await preparing(FirstWeekFixture.planSaveDirective, launch: launch)
		_ = try await settledTurn(model)
		try await save(model)
		model.draft.text = FirstWeekFixture.planSaveDirective(weeks: 10)
		await model.send()
		try await until { model.chat?.plans.count == 2 }
		let plans = try #require(model.chat?.plans)
		let saved = PlanCardText(plans[0], answer: nil, in: model.displayLocale)
		let next = PlanCardText(plans[1], answer: nil, in: model.displayLocale)
		#expect(plans[0].state == .saved)
		#expect(saved.state == "Saved. This is now your training plan.")
		#expect(saved.replaces == nil)
		#expect(next.name == "10-Week Gran Fondo Plan")
		#expect(next.replaces == "Replaces your saved plan: 12-Week Gran Fondo Plan")
	}

	@Test func aCardCarriedAcrossNewConversationSitsAtTheTopAndSaysItWasPreparedEarlier()
		async throws
	{
		let model = try await preparing(FirstWeekFixture.planSaveDirective, launch: launch)
		_ = try await settledTurn(model)
		await model.newConversation()
		try await until { model.chat?.opening != .continuing }
		try await until { model.chat?.plans.first?.placement == .preparedEarlier }
		let carried = try #require(model.chat?.plans.first)
		#expect(model.chat?.plans.count == 1)
		#expect(model.chat?.turns.isEmpty == true)
		#expect(
			PlanCardText(carried, answer: nil, in: model.displayLocale).preparedEarlier
				== "Prepared earlier")
	}

	@Test(arguments: [
		(
			FixturePlanTap.twice, PlanCardState.saved, PlanNotSaved.alreadyDecided,
			"This plan was already saved or canceled."
		),
		(
			FixturePlanTap.expired, PlanCardState.expired, PlanNotSaved.expired,
			"Not saved: the ten minutes to save this plan have passed."
		),
	])
	func eachRefusedTapFixtureLeavesItsAnswerOnTheCard(
		_ tap: FixturePlanTap, _ state: PlanCardState, _ refusal: PlanNotSaved, _ answer: String
	) async throws {
		var tapping = launch
		tapping.planTap = tap
		let model = try await preparing(FirstWeekFixture.planSaveDirective, launch: tapping)
		_ = try await settledTurn(model)
		try await save(model)
		try await until { model.chat?.plans.first?.state == state }
		let card = try #require(model.chat?.plans.first)
		#expect(model.planDecisions.answers[card.id] == .notSaved(refusal))
		#expect(
			PlanCardText(
				card, answer: model.planDecisions.answers[card.id], in: model.displayLocale
			)
			.answer == answer)
	}

	@Test func theReplacedTapFixtureRefusesTheOlderCardAndLeavesTheNewerOneWaiting() async throws {
		var tapping = launch
		tapping.planTap = .replaced
		let model = try await preparing(FirstWeekFixture.planSaveDirective, launch: tapping)
		_ = try await settledTurn(model)
		let first = try #require(model.chat?.plans.first)
		try await save(model)
		try await until { model.chat?.plans.count == 2 }
		let plans = try #require(model.chat?.plans)
		#expect(plans.map(\.id).first == first.id)
		#expect(plans[0].state == .expired)
		#expect(plans[1].state == .waiting(.unarmed))
		#expect(plans[1].summary.name == "10-Week Gran Fondo Plan")
		#expect(model.planDecisions.answers[first.id] == .notSaved(.replaced))
		#expect(
			PlanCardText(plans[0], answer: .notSaved(.replaced), in: model.displayLocale).answer
				== "Not saved: a newer plan is waiting to be saved.")
	}

	@Test func theStorageStageShowsOneStorageLineAndNoControls() async throws {
		var failing = launch
		failing.planSaveStage = .storage
		let model = try await preparing(FirstWeekFixture.planSaveDirective, launch: failing)
		_ = try await settledTurn(model)
		try await save(model)
		try await until { model.chat?.plans.first?.state == .storageUnavailable }
		let card = try #require(model.chat?.plans.first)
		let text = PlanCardText(
			card, answer: model.planDecisions.answers[card.id], in: model.displayLocale)
		#expect(card.armedToken == nil)
		#expect(model.planDecisions.answers[card.id] == .storageUnavailable)
		#expect(
			text.state
				== "This plan could not be saved because storage on this iPhone is unavailable.")
		#expect(text.answer == nil)
	}

	@Test func aSavedCardShowsNoStorageAnswerLeftFromTheTapThatStalled() async throws {
		let model = try await preparing(FirstWeekFixture.planSaveDirective, launch: launch)
		_ = try await settledTurn(model)
		try await save(model)
		try await until { model.chat?.plans.first?.state == .saved }
		let text = PlanCardText(
			try #require(model.chat?.plans.first), answer: .storageUnavailable,
			in: model.displayLocale)
		#expect(text.state == "Saved. This is now your training plan.")
		#expect(text.answer == nil)
	}

	@Test func aCanceledCardShowsNoRefusalLeftFromAnEarlierTap() async throws {
		let model = try await preparing(FirstWeekFixture.planSaveDirective, launch: launch)
		await model.planDecisions.present(try #require(model.chat?.plans.first).ref)
		await model.planDecisions.decide(.cancel(try await armed(model)))
		try await until { model.chat?.plans.first?.state == .canceled }
		let text = PlanCardText(
			try #require(model.chat?.plans.first), answer: .notSaved(.athleteChanged),
			in: model.displayLocale)
		#expect(text.state == "Canceled. This plan was not saved.")
		#expect(text.answer == nil)
	}

	@Test func twoPlanSavesInOneStepShowTheNotPreparedNoticeAndNoCard() async throws {
		let model = await model(try services())
		await model.agreeAndStartChatting()
		model.draft.text = FirstWeekFixture.planSaveNotPreparedDirective
		await model.send()
		let turn = try await settledTurn(model)
		#expect(turn.planSaveNotice?.key == Catalog.chatPlanSaveNotPrepared)
		#expect(
			turn.planSaveNotice?.sentence(in: model.displayLocale)
				== "The training plan could not be prepared for saving.")
		#expect(model.chat?.plans.isEmpty == true)
	}

	private func preparing(_ text: String, launch: FixtureLaunch) async throws -> ShellModel {
		let model = await model(try fixtureServices(launch, defaults: defaults))
		await model.agreeAndStartChatting()
		model.draft.text = text
		await model.send()
		try await until { model.chat?.plans.isEmpty == false }
		return model
	}

	private func armed(_ model: ShellModel) async throws -> PlanSaveToken {
		try await until { model.chat?.plans.last?.armedToken != nil }
		return try #require(model.chat?.plans.last?.armedToken)
	}

	private func save(_ model: ShellModel) async throws {
		let shown = try #require(model.chat?.plans.last)
		await model.planDecisions.present(shown.ref)
		await model.planDecisions.decide(.save(try await armed(model)))
	}

	private func pair(_ id: String, _ label: String, _ value: String) -> PlanCardText.Pair {
		PlanCardText.Pair(id: id, label: label, value: value)
	}

	private func phase(_ number: Int, focus: String, weeks: String, hours: String)
		-> PlanCardText.Phase
	{
		PlanCardText.Phase(
			title: "Phase \(number)",
			pairs: [
				pair("focus", "Focus", focus), pair("weeks", "Duration", weeks),
				pair("hours", "Hours per week", hours),
			])
	}
}
