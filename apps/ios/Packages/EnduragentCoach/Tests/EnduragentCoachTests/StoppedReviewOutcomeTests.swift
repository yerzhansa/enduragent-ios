import Foundation
import Testing

@testable import EnduragentCoach

extension RetryLadderTests {
	@Test(arguments: [false, true])
	func uncertainStoppedCardApprovalRemovesTryAgain(reopenBeforeApproval: Bool) async throws {
		let held = HeldClock()
		let base = FakeIntervalsClient(athleteName: "Ada", ftp: 250)
		let intervals = HeldApprovalWrites(base: base, clock: held, failure: URLError(.timedOut))
		transport.script =
			workoutProposal + [.fail(.http(status: 429, headers: ["retry-after": "7"]))]
		let original = heldApprovalCoach(held, model: transport, intervals: intervals)
		let turn = try #require(
			try await original.send(draft("Add a ride"), to: .main).acceptedTurn)
		try await held.waitUntilHeld(.seconds(7))
		await original.stop(.main)
		#expect(await settledTurn(turn, on: original)?.retryable == true)
		let coach =
			reopenBeforeApproval
			? heldApprovalCoach(HeldClock(), model: transport, intervals: intervals) : original
		let token = try await presentReview(on: coach)
		let approving = Task { await coach.decide(.approve(token), in: .main) }
		defer { approving.cancel() }
		try await held.waitUntilHeld(.seconds(13))
		held.release(.seconds(13))
		guard case .uncertain = await approving.value else {
			Issue.record("expected an uncertain write")
			return
		}
		let settled = try #require(await settledTurn(turn, on: coach))
		guard case .interrupted(let interrupted) = settled else {
			Issue.record("expected an interrupted turn")
			return
		}
		#expect(!settled.retryable)
		#expect(interrupted.saved.calendarWrites == 1)
		#expect(interrupted.saved.unverifiedCalendarWrites == 1)
		#expect(interrupted.notice.action == nil)
		#expect(
			interrupted.notice.sentence(in: LanguageTag.en.phrasebook)
				== "The calendar change may have been saved. Check your calendar before asking again."
		)
		for current in [coach] + reopenedApprovalCoaches(intervals: intervals) {
			#expect(await current.currentSnapshot(.main)?.turns.first?.state == settled)
			#expect(await current.currentSnapshot(.main)?.notes.isEmpty == true)
			await #expect(throws: RetryRefusal.alreadyAnswered) {
				try await current.retry(turn, in: .main)
			}
		}
		#expect(transport.requests.filter { $0.charge == .chatAttempt }.count == 2)
	}

	@Test func rejectedPendingApprovalAfterStopRestoresTryAgain() async throws {
		let held = HeldClock()
		let base = FakeIntervalsClient(athleteName: "Ada", ftp: 250)
		let intervals = HeldApprovalWrites(
			base: base, clock: held,
			failure: IntervalsError(code: "http", details: "Rejected", status: 422))
		transport.script =
			workoutProposal + [.fail(.http(status: 429, headers: ["retry-after": "7"]))]
			+ [.text("Try a shorter ride."), .finish(reason: .stop)]
		let coach = heldApprovalCoach(held, model: transport, intervals: intervals)
		let turn = try #require(try await coach.send(draft("Add a ride"), to: .main).acceptedTurn)
		try await held.waitUntilHeld(.seconds(7))
		let token = try await presentReview(on: coach)
		let approving = Task { await coach.decide(.approve(token), in: .main) }
		defer { approving.cancel() }
		try await held.waitUntilHeld(.seconds(13))
		await coach.stop(.main)
		#expect(await settledTurn(turn, on: coach)?.retryable == false)
		held.release(.seconds(13))
		guard case .partiallyApplied = await approving.value else {
			Issue.record("expected a rejected write")
			return
		}
		let settled = try #require(await settledTurn(turn, on: coach))
		guard case .interrupted(let interrupted) = settled else {
			Issue.record("expected an interrupted turn")
			return
		}
		#expect(settled.retryable)
		#expect(interrupted.saved == .none)
		#expect(interrupted.notice.action == .tryAgain(turn))
		#expect(interrupted.notice.key == Catalog.chatTurnInterruptedNothingChanged)
		for current in [coach] + reopenedApprovalCoaches(intervals: intervals) {
			#expect(await current.currentSnapshot(.main)?.turns.first?.state == settled)
			#expect(await current.currentSnapshot(.main)?.notes.isEmpty == true)
		}
		try await coach.retry(turn, in: .main)
		#expect(
			replyText(try #require(await settledTurn(turn, on: coach))) == "Try a shorter ride.")
		#expect(base.calls.filter(\.isWrite).isEmpty)
	}

	func reopenedApprovalCoaches(intervals: any IntervalsClient) -> [Coach] {
		let logs: [any RecordLog] = [
			store, DeviceAliasLog(inner: store, deviceId: DeviceID(rawValue: "second-phone")),
		]
		return logs.map {
			heldApprovalCoach(HeldClock(), model: transport, intervals: intervals, records: $0)
		}
	}
}
