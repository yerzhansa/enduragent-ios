import Foundation
import Testing

@testable import EnduragentCoach

@Suite struct TurnLifecycleTests {
	let phoneA = DeviceID(rawValue: "phone-a")
	let phoneB = DeviceID(rawValue: "phone-b")
	let now = Date(timeIntervalSince1970: 897_984_000)
	let minted = TurnID(ulid: fixedUlid(1))
	let attempt = AttemptID(ulid: fixedUlid(2))
	let process = ProcessID(ulid: fixedUlid(60))
	let earlierProcess = ProcessID(ulid: fixedUlid(59))

	func accepted(on device: DeviceID? = nil) -> TurnFacts {
		var facts = TurnFacts(turn: minted, chat: .main, origin: device ?? phoneA)
		facts.fragments.append(
			Fragment(
				ulid: fixedUlid(1),
				hlc: HybridLogicalClock(wallMs: 1, logical: 0, deviceId: phoneA),
				civilDate: "1998-06-13", timeZone: amsterdamZone, index: 0, draft: DraftID(),
				text: "hi", slash: nil))
		return facts
	}

	func claimed(by claimer: ProcessID? = nil) -> TurnFacts {
		var facts = accepted()
		facts.claims.append(
			ClaimedAttempt(
				hlc: HybridLogicalClock(wallMs: 2, logical: 0, deviceId: phoneA),
				body: TurnClaimBody(
					chatId: .main, turn: minted, attempt: attempt, process: claimer ?? process,
					lease: .continuedProcessing)))
		return facts
	}

	func settled(_ settlement: Settlement) -> TurnFacts {
		var facts = claimed()
		facts.settlements.append(
			SettledAttempt(
				ulid: fixedUlid(3),
				hlc: HybridLogicalClock(wallMs: 3, logical: 0, deviceId: phoneA),
				attempt: attempt, settlement: settlement))
		return facts
	}

	func claim(_ attempt: AttemptID, on facts: TurnFacts?) -> Result<TurnClaimBody, TurnRefusal> {
		TurnLifecycle.claim(
			attempt, on: facts, chat: .main, device: phoneA, process: process,
			lease: .continuedProcessing)
	}

	@Test func claimOfAnAcceptedTurnWritesALocalClaim() throws {
		#expect(
			try claim(attempt, on: accepted()).get()
				== TurnClaimBody(
					chatId: .main, turn: minted, attempt: attempt, process: process,
					lease: .continuedProcessing))
	}

	@Test func claimOfATurnAcceptedElsewhereIsRefused() {
		#expect(claim(attempt, on: accepted(on: phoneB)) == .failure(.acceptedElsewhere))
		#expect(claim(attempt, on: nil) == .failure(.unknownTurn))
	}

	@Test func anOpenClaimMustFinishOrRecoverBeforeAnotherClaim() {
		#expect(claim(attempt, on: claimed()) == .failure(.attemptInFlight))
		#expect(claim(attempt, on: claimed(by: earlierProcess)) == .failure(.unrecovered))
	}

	@Test func claimIsAcceptedOnlyAfterAStopOrFailureThatSavedNothing() throws {
		let replied = settled(.replied(.model("done"), lineage: nil))
		#expect(claim(attempt, on: replied) == .failure(.alreadyAnswered))
		let failed = settled(.failed(.model(.providerDown(.outage)), saved: .none))
		let retry = AttemptID(ulid: fixedUlid(9))
		let expected = TurnClaimBody(
			chatId: .main, turn: minted, attempt: retry, process: process,
			lease: .continuedProcessing)
		#expect(try claim(retry, on: failed).get() == expected)
		let interrupted = settled(.interrupted(partial: "so", cause: .athleteStopped, saved: .none))
		#expect(try claim(retry, on: interrupted).get() == expected)
		let saved = WriteSummary(
			memorySections: 1, ledgerEvents: 0, planSaves: 0, calendarWrites: 0)
		let failedAfterSave = settled(
			.failed(.model(.budgetExhausted(.generateCalls)), saved: saved))
		#expect(claim(retry, on: failedAfterSave) == .failure(.alreadyAnswered))
		let stoppedAfterSave = settled(
			.interrupted(partial: "so", cause: .athleteStopped, saved: saved))
		#expect(claim(retry, on: stoppedAfterSave) == .failure(.alreadyAnswered))
	}

	@Test func settleWritesOneSyncedSettlementForTheClaimedAttempt() {
		let settlement = Settlement.replied(.model("done"), lineage: nil)
		let result = TurnLifecycle.settled(attempt, settlement, on: claimed(), chat: .main)
		#expect(
			result
				== TurnSettledBody(
					chatId: .main, turn: minted, attempt: attempt, settlement: settlement))
	}

	@Test func settleOfSettledAttemptWritesNothing() {
		let facts = settled(.replied(.model("done"), lineage: nil))
		let again = TurnLifecycle.settled(
			attempt, .failed(.model(.contextOverflow), saved: .none), on: facts, chat: .main)
		#expect(again == nil)
	}

	@Test func stopBeforeStartSettlesAnUnclaimedTurnAsInterrupted() throws {
		let result = try TurnLifecycle.stopBeforeStart(attempt, on: accepted(), chat: .main).get()
		#expect(
			result
				== TurnSettledBody(
					chatId: .main, turn: minted, attempt: attempt,
					settlement: .interrupted(partial: "", cause: .stoppedBeforeStart, saved: .none))
		)
		#expect(
			TurnLifecycle.stopBeforeStart(attempt, on: claimed(), chat: .main)
				== .failure(.attemptInFlight))
	}

	@Test func stateOfUnclaimedTurnAfterRelaunchIsAwaitingRestart() {
		let state = TurnLifecycle.state(
			of: accepted(), live: nil, overlay: .notInThisProcess, device: phoneA, process: process)
		#expect(state == .accepted(.awaitingRestart))
		let dead = TurnLifecycle.state(
			of: claimed(by: earlierProcess), live: nil, overlay: .notInThisProcess, device: phoneA,
			process: process)
		#expect(
			dead
				== .unrecovered(
					TurnState.Unrecovered(
						notice: AthleteNotice(key: Catalog.chatHistoryFailure, action: nil))))
		let running = TurnLifecycle.state(
			of: claimed(), live: nil, overlay: .queued(position: 1), device: phoneA,
			process: process)
		#expect(running == .accepted(.queued(position: 1)))
	}

	@Test func v1QuestionWithoutAReplyIsBeforeUpgradeAndNeverClaimed() {
		var legacy = accepted()
		legacy.legacy = true
		let state = TurnLifecycle.state(
			of: legacy, live: nil, overlay: .notInThisProcess, device: phoneA, process: process)
		#expect(state == .accepted(.beforeUpgrade))
		#expect(turnNotice(of: state)?.action == nil)
		#expect(claim(attempt, on: legacy) == .failure(.alreadyAnswered))
	}

	@Test func stateOfATurnAcceptedElsewhereIsOnOtherDevice() {
		let state = TurnLifecycle.state(
			of: accepted(on: phoneB), live: nil, overlay: .notInThisProcess, device: phoneA,
			process: process)
		#expect(state == .accepted(.onOtherDevice))
		#expect(turnNotice(of: state)?.action == nil)
	}

	@Test func stateFollowsTheWindowAndTheQueueWhileTheProcessLives() {
		let collecting = TurnLifecycle.state(
			of: accepted(), live: nil, overlay: .collecting(until: now), device: phoneA,
			process: process)
		#expect(collecting == .accepted(.collecting(until: now)))
		let queued = TurnLifecycle.state(
			of: accepted(), live: nil, overlay: .queued(position: 2), device: phoneA,
			process: process)
		#expect(queued == .accepted(.queued(position: 2)))
		#expect(turnNotice(of: queued)?.action == nil)
	}

	@Test func liveAttemptWinsUntilItIsSettled() {
		let live = LiveAttempt(
			turn: minted, attempt: attempt, text: "Thursday", activity: .generating(step: 1))
		let processing = TurnLifecycle.state(
			of: claimed(), live: live, overlay: .notInThisProcess, device: phoneA, process: process)
		#expect(
			processing
				== .processing(
					TurnState.Processing(
						attempt: attempt, activity: .generating(step: 1))))
		let done = TurnLifecycle.state(
			of: settled(.replied(.model("Thursday is on."), lineage: nil)), live: live,
			overlay: .notInThisProcess, device: phoneA, process: process)
		#expect(done == .completed(TurnState.Completed(reply: .model("Thursday is on."))))
		#expect(turnNotice(of: done)?.action == nil)
	}

	@Test func failedSettlementCarriesOneNoticeWithTryAgain() throws {
		let state = TurnLifecycle.state(
			of: settled(.failed(.model(.generationFailed(.emptyAfterError)), saved: .none)),
			live: nil, overlay: .notInThisProcess, device: phoneA, process: process)
		guard case .failed(let failed) = state else {
			Issue.record("expected failed, got \(state)")
			return
		}
		#expect(failed.notice?.key == Catalog.chatNoticeResponseFailure)
		#expect(failed.notice?.action == .tryAgain(minted))
		let storage = TurnLifecycle.state(
			of: settled(.failed(.local(.recordStorage), saved: .none)),
			live: nil, overlay: .notInThisProcess, device: phoneA, process: process)
		guard case .failed(let unsaved) = storage else {
			Issue.record("expected failed, got \(storage)")
			return
		}
		#expect(unsaved.notice?.key == Catalog.coachHistoryDiskFull)
		#expect(unsaved.notice?.action == nil)
	}

	@Test func failedSettlementAfterSavedWorkOffersNoTryAgain() {
		let saved = WriteSummary(
			memorySections: 1, ledgerEvents: 0, planSaves: 0, calendarWrites: 0)
		let state = TurnLifecycle.state(
			of: settled(.failed(.model(.budgetExhausted(.generateCalls)), saved: saved)),
			live: nil, overlay: .notInThisProcess, device: phoneA, process: process)
		guard case .failed(let failed) = state else {
			Issue.record("expected failed, got \(state)")
			return
		}
		#expect(failed.notice?.key == Catalog.coachErrorUnknown)
		#expect(failed.notice?.action == nil)
	}

	@Test func interruptedSettlementKeepsThePartialTextAndOffersTryAgainOnlyWhenNothingSaved() {
		let clean = TurnLifecycle.state(
			of: settled(.interrupted(partial: "Thursday is", cause: .athleteStopped, saved: .none)),
			live: nil, overlay: .notInThisProcess, device: phoneA, process: process)
		guard case .interrupted(let interrupted) = clean else {
			Issue.record("expected interrupted, got \(clean)")
			return
		}
		#expect(interrupted.partial == "Thursday is")
		#expect(interrupted.notice.key == Catalog.chatTurnInterruptedNothingChanged)
		#expect(interrupted.notice.action == .tryAgain(minted))
		let saved = WriteSummary(
			memorySections: 1, ledgerEvents: 0, planSaves: 0, calendarWrites: 0)
		let afterWrite = TurnLifecycle.state(
			of: settled(.interrupted(partial: "", cause: .athleteStopped, saved: saved)),
			live: nil, overlay: .notInThisProcess, device: phoneA, process: process)
		#expect(turnNotice(of: afterWrite)?.action == nil)
	}
}
