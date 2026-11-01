import EnduragentCoachFixtures
import Foundation
import Testing

@testable import EnduragentCoach

@Suite struct ReviewNotPreparedTests {
	let turns = ReviewTurns()

	enum Ending: String, CaseIterable, Sendable, CustomTestStringConvertible {
		case fails
		case isStopped
		case runsOutOfToolRounds

		var testDescription: String { rawValue }
	}

	@Test(arguments: Ending.allCases)
	func aTurnThatPreparesButDoesNotFinishCommitsNothingAndSaysSo(_ ending: Ending) async throws {
		let coach = await turns.coach()
		let prepared = [turns.prepare(ReviewTurns.oneRide), .finish(reason: .toolCalls)]
		let pending: [ScriptedEvent] = [
			.toolCall(name: "get_pending_workout_changes", arguments: "{}"),
			.finish(reason: .toolCalls),
		]
		switch ending {
		case .fails:
			turns.script(prepared + [.fail(.http(status: 401))])
		case .isStopped:
			turns.script(prepared + [.hang])
		case .runsOutOfToolRounds:
			turns.script(
				prepared + Array(repeating: pending, count: 9).flatMap { $0 } + [
					.text("I ran out of steps."), .finish(reason: .stop),
				])
		}
		let turn = try #require(try await coach.send(draft("Plan my week"), to: .main).acceptedTurn)
		if ending == .isStopped {
			try await waitUntil { turns.transport.requests.count >= 2 }
			await coach.stop(.main)
		}

		let state = try #require(await coach.settledState(of: turn, in: .main))

		#expect(try await turns.head(of: coach).1 == nil)
		#expect(try await coach.desk.snapshot(chat: .main) == nil)
		#expect(try await turns.settled(turn).map(\.reviewNotPrepared) == [.turnDidNotFinish])
		#expect(try await turns.view(of: turn, on: coach).reviewNotice == ReviewTurns.notPrepared)
		#expect(turnNotice(of: state) != ReviewTurns.notPrepared)
	}

	@Test func aProviderRetryDropsTheDraftOfTheGenerationItReplaced() async throws {
		let coach = await turns.coach()
		turns.script([
			turns.prepare(ReviewTurns.oneRide), .finish(reason: .toolCalls),
			.fail(.http(status: 503)), .text("Ride easy on Wednesday."), .finish(reason: .stop),
		])

		let state = try await coach.sendAndSettle("Plan my week")

		let turn = try #require(await coach.currentSnapshot(.main)?.turns.first?.id)
		#expect(replyText(state) == "Ride easy on Wednesday.")
		#expect(turns.transport.requests.count == 3)
		#expect(turns.transport.requests.last?.messages.contains { $0.role == .tool } == false)
		#expect(try await turns.head(of: coach).1 == nil)
		#expect(try await coach.desk.snapshot(chat: .main) == nil)
		#expect(try await turns.settled(turn).map(\.reviewNotPrepared) == [.turnDidNotFinish])
		#expect(try await turns.view(of: turn, on: coach).reviewNotice == ReviewTurns.notPrepared)
	}

	@Test func aStepWithTwoPreparationsRefusesBothAndCommitsNothing() async throws {
		let coach = await turns.coach()

		let turn = try await turns.reply(
			after: [
				turns.prepare(
					#"{"kind":"complete","changes":[{"kind":"edit","eventId":201,"patch":{"name":"Tempo"}}]}"#
				),
				turns.prepare(
					#"{"kind":"complete","changes":[{"kind":"edit","eventId":202,"patch":{"name":"Recovery"}}]}"#
				),
			], on: coach)

		#expect(
			try turns.toolData().map { $0.objectFields["error"] } == [
				.string("concurrent_preparation"), .string("concurrent_preparation"),
			])
		#expect(try await turns.settled(turn).map(\.reviewNotPrepared) == [.refused])
		#expect(try await turns.view(of: turn, on: coach).reviewNotice == ReviewTurns.notPrepared)
		#expect(try await turns.head(of: coach).1 == nil)
		#expect(try await coach.desk.snapshot(chat: .main) == nil)
	}

	@Test func aSavedMemoryFactSurvivesAFailedPreparationAndBothAreReported() async throws {
		let coach = await turns.coach()
		turns.script([
			.saturdayScheduleWrite, turns.prepare(ReviewTurns.oneRide),
			.finish(reason: .toolCalls), .fail(.http(status: 401)),
		])

		let state = try await coach.sendAndSettle("Remember my Saturday ride and plan Tuesday")

		let turn = try #require(await coach.currentSnapshot(.main)?.turns.first?.id)
		#expect(
			try await turns.store.fetch(RecordQuery(scope: .synced([.memorySection]))).records
				.count == 1)
		#expect(try await turns.head(of: coach).1 == nil)
		#expect(
			turnNotice(of: state)
				== AthleteNotice(key: Catalog.chatNoticeSavedUnverified, actions: []))
		#expect(
			try await turns.view(of: turn, on: coach).reviewNotice
				== AthleteNotice(key: Catalog.workoutsNotPreparedInformationSaved, actions: []))
	}
}
