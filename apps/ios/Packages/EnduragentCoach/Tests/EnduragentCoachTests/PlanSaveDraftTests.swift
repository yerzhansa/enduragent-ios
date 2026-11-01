import EnduragentCoachFixtures
import Foundation
import Testing

@testable import EnduragentCoach

@Suite struct PlanSaveDraftTests {
	let turns = PlanTurns()

	static let profile =
		#"{"experienceLevel":"intermediate","ftpWatts":250,"volumeTier":"medium","scheduleType":"flexible","goalType":"race","raceType":"gran_fondo","raceDate":"1998-08-09"}"#
	static let highVolume = profile.replacingOccurrences(of: #""medium""#, with: #""high""#)
	static let lowVolume = profile.replacingOccurrences(of: #""medium""#, with: #""low""#)
	static let coachPlan: JSONValue = .object([
		"name": .string("Gran Fondo Build"), "primaryGoal": .string("Finish the gran fondo strong"),
		"status": .string("active"), "notes": .string("Ride easy on Mondays."),
		"totalWeeks": .number(10),
		"phases": .array([
			.object([
				"name": .string("Aerobic development"), "focus": .string("Long rides in zone 2"),
				"durationWeeks": .number(6), "keyAdditions": .array([.string("Sunday long ride")]),
			]),
			.object([
				"name": .string("Race prep"), "focus": .string("Race-pace efforts"),
				"durationWeeks": .number(4),
			]),
		]),
		"zoneTables": .array([
			.object([
				"sport": .string("cycling"),
				"zones": .array(
					(1...7).map { zone in
						.object([
							"name": .string("Level \(zone)"), "range": .string("\(zone * 40) W"),
							"description": .string("\(zone * 10)% FTP"),
						])
					}),
			])
		]),
	])

	@Test func aSaveAfterADraftInAnEarlierTurnPreparesAndSavesTheDraftsWeeksPhasesAndZones()
		async throws
	{
		let coach = await turns.coach()
		let draft = try await draft(Self.profile, on: coach)

		_ = try await turns.reply(after: [[turns.save(Self.coachPlan)]], on: coach)

		let expected = try Self.merged(Self.coachPlan, draft)
		#expect(expected.value.objectFields["phases"] == draft.objectFields["phases"])
		#expect(try turns.toolData() == [Self.answer(for: expected)])
		let card = try #require(try await turns.cards(on: coach).last)
		#expect(card.ref.digest == expected.digest)
		#expect(card.summary == expected.summary(replacing: nil))
		#expect(card.summary.name == "Gran Fondo Build")
		#expect(card.summary.goal == "Finish the gran fondo strong")
		#expect(
			card.summary.phases.map(\.focus)
				== (draft.objectFields["phases"]?.arrayValue ?? []).map {
					$0.objectFields["focus"]?.stringValue
				})
		#expect(try await turns.prepared(in: turns.store).map(\.document) == [expected])

		let token = try await turns.armedToken(on: coach)
		#expect(await coach.decide(.save(token), in: .main) == .saved)

		let saved = try await turns.planLoad(on: coach)
		#expect(saved == expected.value)
		#expect(saved.objectFields["status"] == .string("active"))
		#expect(saved.objectFields["notes"] == .string("Ride easy on Mondays."))
	}

	@Test func theNewestOfTwoDraftsIsTheOneSaved() async throws {
		let coach = await turns.coach()
		let first = try await draft(Self.profile, on: coach)
		let newest = try await draft(Self.highVolume, on: coach)
		#expect(first.objectFields["phases"] != newest.objectFields["phases"])

		_ = try await turns.reply(after: [[turns.save(Self.coachPlan)]], on: coach)

		#expect(
			try await turns.prepared(in: turns.store).map(\.document) == [
				try Self.merged(Self.coachPlan, newest)
			])
	}

	@Test func aTurnThatDraftsTwiceSavesItsSecondDraftOverTheEarlierTurnsDraft() async throws {
		let coach = await turns.coach()
		let earlier = try await draft(Self.profile, on: coach)

		_ = try await turns.reply(
			after: [
				[.toolCall(name: "build_plan_skeleton", arguments: Self.highVolume)],
				[.toolCall(name: "build_plan_skeleton", arguments: Self.lowVolume)],
				[turns.save(Self.coachPlan)],
			], on: coach)

		let drafts = try turns.toolData()
		let first = try #require(drafts.first)
		let newest = try #require(drafts.dropFirst().first)
		let phases = [earlier, first, newest].map { $0.objectFields["phases"] }
		#expect(phases[0] != phases[1] && phases[1] != phases[2] && phases[0] != phases[2])
		let expected = try Self.merged(Self.coachPlan, newest)
		#expect(try await turns.prepared(in: turns.store).map(\.document) == [expected])
		let token = try await turns.armedToken(on: coach)
		#expect(await coach.decide(.save(token), in: .main) == .saved)
		#expect(try await turns.planLoad(on: coach) == expected.value)
	}

	@Test func aDraftFromAnEarlierStepOfTheSameTurnIsSaved() async throws {
		let coach = await turns.coach()

		_ = try await turns.reply(
			after: [
				[.toolCall(name: "build_plan_skeleton", arguments: Self.profile)],
				[turns.save(Self.coachPlan)],
			], on: coach)

		let draft = try #require(try turns.toolData().first)
		#expect(
			try await turns.prepared(in: turns.store).map(\.document) == [
				try Self.merged(Self.coachPlan, draft)
			])
	}

	@Test func aDraftFromBeforeNewConversationIsNotSavedAndTheCoachsPlanIsSavedAsSent()
		async throws
	{
		let coach = await turns.coach()
		_ = try await draft(Self.profile, on: coach)
		_ = await coach.resetAndSettle(in: .main)

		_ = try await turns.reply(after: [[turns.save(Self.coachPlan)]], on: coach)

		let sent = try PlanTurns.document(Self.coachPlan)
		#expect(try await turns.prepared(in: turns.store).map(\.document) == [sent])
		#expect(try turns.toolData() == [Self.answer(for: sent)])
		let token = try await turns.armedToken(on: coach)
		#expect(await coach.decide(.save(token), in: .main) == .saved)
		#expect(canonicalJSON(try await turns.planLoad(on: coach)) == sent.text)
	}

	@Test(arguments: [false, true])
	func aFailedDraftIsNotADraft(afterAnEarlierDraft: Bool) async throws {
		let coach = await turns.coach()
		let earlier = afterAnEarlierDraft ? try await draft(Self.profile, on: coach) : nil

		_ = try await turns.reply(
			after: [
				[.toolCall(name: "build_plan_skeleton", arguments: #"{"ftpWatts":250}"#)],
				[turns.save(Self.coachPlan)],
			], on: coach)

		#expect(try turns.toolData().first?.objectFields["error"] == .string("invalid_input"))
		let expected =
			try earlier.map { try Self.merged(Self.coachPlan, $0) }
			?? PlanTurns.document(Self.coachPlan)
		#expect(try await turns.prepared(in: turns.store).map(\.document) == [expected])
		if !afterAnEarlierDraft {
			let token = try await turns.armedToken(on: coach)
			#expect(await coach.decide(.save(token), in: .main) == .saved)
			#expect(canonicalJSON(try await turns.planLoad(on: coach)) == expected.text)
		}
	}

	private func draft(_ profile: String, on coach: Coach) async throws -> JSONValue {
		_ = try await turns.reply(
			after: [[.toolCall(name: "build_plan_skeleton", arguments: profile)]], on: coach,
			asking: "Draft me a plan")
		let draft = try #require(try turns.toolData().first)
		#expect(draft.objectFields["phases"]?.arrayValue?.isEmpty == false)
		return draft
	}

	private static func merged(_ plan: JSONValue, _ draft: JSONValue) throws -> PlanDocument {
		var fields = plan.objectFields
		for key in ["totalWeeks", "phases", "zoneTables"] {
			fields[key] = draft.objectFields[key]
		}
		return try PlanTurns.document(.object(fields))
	}

	private static func answer(for document: PlanDocument) -> JSONValue {
		.object([
			"pendingConfirmation": .bool(true), "summary": .string(document.pendingSummary),
		])
	}
}
