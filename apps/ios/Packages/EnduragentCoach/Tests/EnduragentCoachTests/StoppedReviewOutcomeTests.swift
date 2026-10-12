import EnduragentCoachFixtures
import Foundation
import Testing

@testable import EnduragentCoach

extension RetryLadderTests {
	@Test(arguments: [false, true])
	func uncertainStoppedCardApprovalRemovesTryAgain(reopenBeforeApproval: Bool) async throws {
		let held = HeldClock()
		let base = FakeIntervalsClient(athleteName: "Ada", ftp: 250)
		let intervals = HeldApprovalWrites(base: base, clock: held, failure: URLError(.timedOut))
		transport.respond = ScriptedReply.sequence(
			workoutProposal + [.fail(.http(status: 429, headers: ["retry-after": "7"]))],
			otherwise: transport.respond)
		let original = await heldApprovalCoach(held, model: transport, intervals: intervals)
		let turn = try #require(
			try await original.send(draft("Add a ride"), to: .main).acceptedTurn)
		try await held.waitUntilHeld(.seconds(7))
		await original.stop(.main)
		#expect(
			turnNotice(of: try #require(await settledTurn(turn, on: original)))?.actions
				== [.tryAgain(turn)])
		let coach =
			reopenBeforeApproval
			? await heldApprovalCoach(HeldClock(), model: transport, intervals: intervals)
			: original
		let token = try await presentReview(on: coach)
		let approving = Task { await coach.decide(.approve(token), in: .main) }
		defer { approving.cancel() }
		try await held.waitUntilHeld(.seconds(13))
		held.advance(by: .seconds(13))
		guard case .uncertain = await approving.value else {
			Issue.record("expected an uncertain write")
			return
		}
		let settled = try #require(await settledTurn(turn, on: coach))
		guard case .interrupted(let interrupted) = settled else {
			Issue.record("expected an interrupted turn")
			return
		}
		#expect(interrupted.saved.calendarWrites == 1)
		#expect(interrupted.saved.unverifiedCalendarWrites == 1)
		#expect(interrupted.notice.actions.isEmpty)
		#expect(
			interrupted.notice.sentence(in: displayLocale())
				== "The calendar change may have been saved. Check your calendar before asking again."
		)
		for current in [coach] + (await reopenedApprovalCoaches(intervals: intervals)) {
			#expect(await current.currentSnapshot(.main)?.turns.first?.state == settled)
			#expect(await current.currentSnapshot(.main)?.notes.isEmpty == true)
			await #expect(throws: RetryRefusal.self) {
				try await current.retry(turn, in: .main)
			}
		}
		#expect(transport.requests.filter { $0.charge == .chatAttempt }.count == 2)
	}

	@Test(arguments: [false, true])
	func dispatchedRejectionAfterStopKeepsUnknownEvidence(memorySaved: Bool) async throws {
		let held = HeldClock()
		let base = FakeIntervalsClient(athleteName: "Ada", ftp: 250)
		let intervals = HeldApprovalWrites(
			base: base, clock: held,
			failure: IntervalsError(code: "http", details: "Rejected", status: 422))
		let memory: [ScriptedEvent] =
			memorySaved
			? [
				.untypedSaturdayScheduleWrite,
				.finish(reason: .toolCalls),
			] : []
		transport.respond = ScriptedReply.sequence(
			memory + workoutProposal + [.text("Review ready."), .hang]
				+ [.text("Try a shorter ride."), .finish(reason: .stop)],
			otherwise: transport.respond)
		let coach = await heldApprovalCoach(held, model: transport, intervals: intervals)
		let turn = try #require(try await coach.send(draft("Add a ride"), to: .main).acceptedTurn)
		await coach.waitForLiveText(turn)
		let token = try await presentReview(on: coach)
		let approving = Task { await coach.decide(.approve(token), in: .main) }
		defer { approving.cancel() }
		try await held.waitUntilHeld(.seconds(13))
		await coach.stop(.main)
		#expect(
			(turnNotice(of: try #require(await settledTurn(turn, on: coach)))?.actions ?? [])
				.isEmpty)
		held.advance(by: .seconds(13))
		guard case .uncertain = await approving.value else {
			Issue.record("a dispatched rejection is not proof of absence")
			return
		}
		let settled = try #require(await settledTurn(turn, on: coach))
		guard case .interrupted(let interrupted) = settled else {
			Issue.record("expected an interrupted turn")
			return
		}
		#expect(interrupted.saved.calendarWrites == 1)
		#expect(interrupted.saved.unverifiedCalendarWrites == 1)
		#expect(interrupted.saved.memorySections == (memorySaved ? 1 : 0))
		#expect(interrupted.notice.actions.isEmpty)
		for current in [coach] + (await reopenedApprovalCoaches(intervals: intervals)) {
			#expect(await current.currentSnapshot(.main)?.turns.first?.state == settled)
			await #expect(throws: RetryRefusal.self) { try await current.retry(turn, in: .main) }
		}

		#expect(base.calls.filter(\.isWrite).isEmpty)
	}

	func reopenedApprovalCoaches(intervals: any IntervalsClient) async -> [Coach] {
		let logs: [any RecordLog] = [
			store, DeviceAliasLog(inner: store, deviceId: DeviceID(rawValue: "second-phone")),
		]
		var coaches: [Coach] = []
		for log in logs {
			coaches.append(
				await heldApprovalCoach(
					HeldClock(), model: transport, intervals: intervals, records: log))
		}
		return coaches
	}
}
