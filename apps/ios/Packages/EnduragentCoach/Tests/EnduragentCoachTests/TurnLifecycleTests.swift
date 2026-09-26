import Foundation
import Testing

@testable import EnduragentCoach

@Suite struct TurnLifecycleTests {
	let phoneA = DeviceID(rawValue: "phone-a")
	let phoneB = DeviceID(rawValue: "phone-b")
	let now = Date(timeIntervalSince1970: 897_984_000)
	let minted = TurnID(ulid: fixedUlid(1))
	let attempt = AttemptID(ulid: fixedUlid(2))

	func accepted(on device: DeviceID? = nil, draft: DraftID = DraftID()) -> TurnFacts {
		var facts = TurnFacts(turn: minted, chat: .main, origin: device ?? phoneA)
		facts.fragments.append(
			Fragment(
				ulid: fixedUlid(1),
				hlc: HybridLogicalClock(wallMs: 1, logical: 0, deviceId: phoneA),
				civilDate: "1998-06-13", index: 0, draft: draft, text: "hi", slash: nil))
		return facts
	}

	func claimed() -> TurnFacts {
		var facts = accepted()
		facts.claims.append(TurnClaimBody(chatId: .main, turn: minted, attempt: attempt))
		return facts
	}

	func settled(_ settlement: Settlement) -> TurnFacts {
		var facts = claimed()
		facts.settlements.append(
			SettledAttempt(
				ulid: fixedUlid(3),
				hlc: HybridLogicalClock(wallMs: 3, logical: 0, deviceId: phoneA),
				civilDate: "1998-06-13", attempt: attempt, settlement: settlement))
		return facts
	}

	func writes(_ event: TurnEvent, on facts: TurnFacts?) -> Result<TurnWrites, TurnRefusal> {
		TurnLifecycle.writes(for: event, on: facts, chat: .main, device: phoneA, mint: { minted })
	}

	@Test func acceptOfANewDraftWritesFragmentZeroOfAMintedTurn() throws {
		let draft = Draft(id: DraftID(), text: "hi")
		let result = try writes(.accept(draft, joining: nil, slash: .review), on: nil).get()
		#expect(
			result
				== .synced([
					.userMessage(
						UserMessageBody(
							chatId: .main, turn: minted, fragment: 0, draft: draft.id,
							athleteText: "hi", slash: .review))
				]))
	}

	@Test func acceptInsideTheWindowJoinsAsTheNextFragment() throws {
		let draft = Draft(id: DraftID(), text: "and Friday?")
		let result = try writes(.accept(draft, joining: minted, slash: nil), on: accepted()).get()
		#expect(
			result
				== .synced([
					.userMessage(
						UserMessageBody(
							chatId: .main, turn: minted, fragment: 1, draft: draft.id,
							athleteText: "and Friday?", slash: nil))
				]))
	}

	@Test func acceptOfAKnownDraftWritesNothing() throws {
		let draft = Draft(id: DraftID(), text: "hi")
		let result = try writes(
			.accept(draft, joining: nil, slash: nil), on: accepted(draft: draft.id)
		).get()
		#expect(result == .nothing)
	}

	@Test func claimOfAnAcceptedTurnWritesALocalClaim() throws {
		let result = try writes(.claim(attempt), on: accepted()).get()
		#expect(
			result
				== .local([.turnClaim(TurnClaimBody(chatId: .main, turn: minted, attempt: attempt))]
				))
	}

	@Test func claimOfATurnAcceptedElsewhereIsRefused() {
		#expect(writes(.claim(attempt), on: accepted(on: phoneB)) == .failure(.acceptedElsewhere))
		#expect(writes(.claim(attempt), on: nil) == .failure(.unknownTurn))
	}

	@Test func claimIsAcceptedOnlyAfterAStopOrFailureThatSavedNothing() throws {
		let replied = settled(.replied(.model("done"), lineage: nil))
		#expect(writes(.claim(attempt), on: replied) == .failure(.alreadyAnswered))
		let failed = settled(.failed(.model(.providerDown(.outage)), saved: .none))
		let retry = AttemptID(ulid: fixedUlid(9))
		#expect(
			try writes(.claim(retry), on: failed).get()
				== .local([.turnClaim(TurnClaimBody(chatId: .main, turn: minted, attempt: retry))]))
		let interrupted = settled(.interrupted(partial: "so", cause: .athleteStopped, saved: .none))
		#expect(
			try writes(.claim(retry), on: interrupted).get()
				== .local([.turnClaim(TurnClaimBody(chatId: .main, turn: minted, attempt: retry))]))
		let saved = WriteSummary(
			memorySections: 1, ledgerEvents: 0, planSaves: 0, calendarWrites: 0)
		let failedAfterSave = settled(
			.failed(.model(.budgetExhausted(.generateCalls)), saved: saved))
		#expect(writes(.claim(retry), on: failedAfterSave) == .failure(.alreadyAnswered))
		let stoppedAfterSave = settled(
			.interrupted(partial: "so", cause: .athleteStopped, saved: saved))
		#expect(writes(.claim(retry), on: stoppedAfterSave) == .failure(.alreadyAnswered))
	}

	@Test func settleWritesOneSyncedSettlementForTheClaimedAttempt() throws {
		let settlement = Settlement.replied(.model("done"), lineage: nil)
		let result = try writes(.settle(attempt, settlement), on: claimed()).get()
		#expect(
			result
				== .synced([
					.turnSettled(
						TurnSettledBody(
							chatId: .main, turn: minted, attempt: attempt, settlement: settlement))
				]))
	}

	@Test func settleOfSettledAttemptWritesNothing() throws {
		let facts = settled(.replied(.model("done"), lineage: nil))
		let again = try writes(
			.settle(attempt, .failed(.model(.contextOverflow), saved: .none)), on: facts
		).get()
		#expect(again == .nothing)
	}

	@Test func stopBeforeStartSettlesAnUnclaimedTurnAsInterrupted() throws {
		let result = try writes(.stopBeforeStart(attempt), on: accepted()).get()
		#expect(
			result
				== .synced([
					.turnSettled(
						TurnSettledBody(
							chatId: .main, turn: minted, attempt: attempt,
							settlement: .interrupted(
								partial: "", cause: .stoppedBeforeStart, saved: .none)))
				]))
		#expect(writes(.stopBeforeStart(attempt), on: claimed()) == .failure(.attemptInFlight))
	}

	@Test func stateOfUnclaimedTurnAfterRelaunchIsAwaitingRestart() {
		let state = TurnLifecycle.state(
			of: accepted(), live: nil, overlay: .notInThisProcess, device: phoneA, now: now)
		#expect(state == .accepted(.awaitingRestart))
		#expect(state.retryable)
		let dead = TurnLifecycle.state(
			of: claimed(), live: nil, overlay: .notInThisProcess, device: phoneA, now: now)
		#expect(dead == .accepted(.awaitingRestart))
	}

	@Test func v1QuestionWithoutAReplyIsBeforeUpgradeAndNeverClaimed() {
		var legacy = accepted()
		legacy.legacy = true
		let state = TurnLifecycle.state(
			of: legacy, live: nil, overlay: .notInThisProcess, device: phoneA, now: now)
		#expect(state == .accepted(.beforeUpgrade))
		#expect(!state.retryable)
		#expect(writes(.claim(attempt), on: legacy) == .failure(.alreadyAnswered))
	}

	@Test func stateOfATurnAcceptedElsewhereIsOnOtherDevice() {
		let state = TurnLifecycle.state(
			of: accepted(on: phoneB), live: nil, overlay: .notInThisProcess, device: phoneA,
			now: now)
		#expect(state == .accepted(.onOtherDevice))
		#expect(!state.retryable)
	}

	@Test func stateFollowsTheWindowAndTheQueueWhileTheProcessLives() {
		let collecting = TurnLifecycle.state(
			of: accepted(), live: nil, overlay: .collecting(until: now), device: phoneA, now: now)
		#expect(collecting == .accepted(.collecting(until: now)))
		let queued = TurnLifecycle.state(
			of: accepted(), live: nil, overlay: .queued(position: 2), device: phoneA, now: now)
		#expect(queued == .accepted(.queued(position: 2)))
		#expect(!queued.retryable)
	}

	@Test func liveAttemptWinsUntilItIsSettled() {
		let live = LiveAttempt(
			turn: minted, attempt: attempt, text: "Thursday", activity: .generating(step: 1))
		let processing = TurnLifecycle.state(
			of: claimed(), live: live, overlay: .notInThisProcess, device: phoneA, now: now)
		#expect(
			processing
				== .processing(
					TurnState.Processing(
						attempt: attempt, liveText: "Thursday", activity: .generating(step: 1))))
		let done = TurnLifecycle.state(
			of: settled(.replied(.model("Thursday is on."), lineage: nil)), live: live,
			overlay: .notInThisProcess, device: phoneA, now: now)
		#expect(done == .completed(TurnState.Completed(reply: .model("Thursday is on."))))
		#expect(!done.retryable)
	}

	@Test func failedSettlementCarriesOneNoticeWithTryAgain() throws {
		let state = TurnLifecycle.state(
			of: settled(.failed(.model(.generationFailed(.emptyAfterError)), saved: .none)),
			live: nil, overlay: .notInThisProcess, device: phoneA, now: now)
		guard case .failed(let failed) = state else {
			Issue.record("expected failed, got \(state)")
			return
		}
		#expect(failed.notice.key == Catalog.chatNoticeResponseFailure)
		#expect(failed.notice.action == .tryAgain(minted))
		#expect(state.retryable)
		let storage = TurnLifecycle.state(
			of: settled(.failed(.local(.recordStorage), saved: .none)),
			live: nil, overlay: .notInThisProcess, device: phoneA, now: now)
		guard case .failed(let unsaved) = storage else {
			Issue.record("expected failed, got \(storage)")
			return
		}
		#expect(unsaved.notice.key == Catalog.coachHistoryDiskFull)
		#expect(unsaved.notice.action == nil)
		#expect(!storage.retryable)
	}

	@Test func failedSettlementAfterSavedWorkOffersNoTryAgain() {
		let saved = WriteSummary(
			memorySections: 1, ledgerEvents: 0, planSaves: 0, calendarWrites: 0)
		let state = TurnLifecycle.state(
			of: settled(.failed(.model(.budgetExhausted(.generateCalls)), saved: saved)),
			live: nil, overlay: .notInThisProcess, device: phoneA, now: now)
		guard case .failed(let failed) = state else {
			Issue.record("expected failed, got \(state)")
			return
		}
		#expect(failed.notice.key == Catalog.coachErrorUnknown)
		#expect(failed.notice.action == nil)
		#expect(!state.retryable)
	}

	@Test func interruptedSettlementKeepsThePartialTextAndOffersTryAgainOnlyWhenNothingSaved() {
		let clean = TurnLifecycle.state(
			of: settled(.interrupted(partial: "Thursday is", cause: .athleteStopped, saved: .none)),
			live: nil, overlay: .notInThisProcess, device: phoneA, now: now)
		guard case .interrupted(let interrupted) = clean else {
			Issue.record("expected interrupted, got \(clean)")
			return
		}
		#expect(interrupted.partial == "Thursday is")
		#expect(interrupted.notice.key == Catalog.chatNoticeResponseStopped)
		#expect(interrupted.notice.action == .tryAgain(minted))
		#expect(clean.retryable)
		let saved = WriteSummary(
			memorySections: 1, ledgerEvents: 0, planSaves: 0, calendarWrites: 0)
		let afterWrite = TurnLifecycle.state(
			of: settled(.interrupted(partial: "", cause: .athleteStopped, saved: saved)),
			live: nil, overlay: .notInThisProcess, device: phoneA, now: now)
		#expect(!afterWrite.retryable)
	}
}
