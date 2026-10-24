import EnduragentCoachFixtures
import Foundation
import Testing

@testable import EnduragentCoach

@Suite struct PlanChainTests {
	let expiresAt = Date(timeIntervalSince1970: 899_165_400)
	let base = PlanDocumentTests.base
	let build: JSONValue = .object(["name": .string("Build")])

	@Test func aWaitingConfirmationIsLiveOneSecondBeforeItExpiresAndExpiredAtExactlyItsExpiry()
		throws
	{
		let rows = PlanStepRows(confirmation: 1, turn: 20)
		let prepared = try rows.step(rows.prepared(base, expiresAt: expiresAt), wall: 1)
		let chain = PlanChain(head: .record(prepared.ulid), records: [prepared])
		let confirmation = try #require(chain.newest)

		#expect(confirmation.id == rows.id)
		#expect(confirmation.origin == rows.origin)
		#expect(confirmation.created == prepared)
		#expect(confirmation.prepared.expiresAt == expiresAt)
		guard case .live(let live) = chain.phase(of: confirmation, at: expiresAt - 1) else {
			Issue.record("one second before its expiry the confirmation is not live")
			return
		}
		#expect(live.confirmation == confirmation)
		#expect(live.head == .record(prepared.ulid))
		#expect(chain.phase(of: confirmation, at: expiresAt) == .expired)
		#expect(chain.phase(of: confirmation, at: expiresAt + 60) == .expired)
	}

	@Test func aLaterConfirmationInTheConversationReplacesTheOlderOne() throws {
		let older = PlanStepRows(confirmation: 1, turn: 20)
		let newer = PlanStepRows(confirmation: 2, turn: 30)
		let first = try older.step(older.prepared(base, expiresAt: expiresAt), wall: 1)
		let second = try newer.step(newer.prepared(build, expiresAt: expiresAt + 300), wall: 2)

		let chain = PlanChain(head: .record(second.ulid), records: [first, second])

		#expect(chain.confirmations.map(\.id) == [older.id, newer.id])
		#expect(chain.newest?.id == newer.id)
		let replaced = try #require(chain.confirmations.first)
		#expect(chain.phase(of: replaced, at: expiresAt - 1) == .replaced)
		let newest = try #require(chain.newest)
		guard case .live(let live) = chain.phase(of: newest, at: expiresAt - 1) else {
			Issue.record("the newest confirmation is not live")
			return
		}
		#expect(live.confirmation.id == newer.id)
	}

	@Test func theNewestStepDecidesSavingSavedAndCanceledPastExpiryAndReplacement() throws {
		let claimedRows = PlanStepRows(confirmation: 1, turn: 20)
		let canceledRows = PlanStepRows(confirmation: 2, turn: 30)
		let savedRows = PlanStepRows(confirmation: 3, turn: 40)
		let waitingRows = PlanStepRows(confirmation: 4, turn: 50)
		let pendingClaim = try PlanClaimRow(savedPlan: 61, attempt: 62, for: base)
		let savedClaim = try PlanClaimRow(savedPlan: 71, attempt: 72, for: build)
		let records = [
			try claimedRows.step(claimedRows.prepared(base, expiresAt: expiresAt), wall: 1),
			try claimedRows.step(claimedRows.claimed(pendingClaim), wall: 2),
			try canceledRows.step(canceledRows.prepared(base, expiresAt: expiresAt), wall: 3),
			try canceledRows.step(canceledRows.canceled(), wall: 4),
			try savedRows.step(savedRows.prepared(build, expiresAt: expiresAt), wall: 5),
			try savedRows.step(savedRows.claimed(savedClaim), wall: 6),
			try savedRows.step(savedRows.saved(savedClaim.savedPlanID), wall: 7),
			try waitingRows.step(waitingRows.prepared(build, expiresAt: expiresAt), wall: 8),
		]
		let chain = PlanChain(head: .record(fixedUlid(8)), records: records)
		let confirmations = chain.confirmations

		#expect(
			confirmations.map(\.id) == [
				claimedRows.id, canceledRows.id, savedRows.id, waitingRows.id,
			])
		for now in [expiresAt - 1, expiresAt + 60] {
			#expect(chain.phase(of: confirmations[0], at: now) == .saving(pendingClaim.claim))
			#expect(chain.phase(of: confirmations[1], at: now) == .canceled)
			#expect(chain.phase(of: confirmations[2], at: now) == .saved(savedClaim.savedPlanID))
		}
		#expect(confirmations[2].created == records[4])
		#expect(confirmations[2].newest == records[6])
		#expect(chain.phase(of: confirmations[3], at: expiresAt + 60) == .expired)
	}

	@Test func committedFindsTheConfirmationTheAttemptPrepared() throws {
		let first = PlanStepRows(confirmation: 1, turn: 20, attempt: 21)
		let second = PlanStepRows(confirmation: 2, turn: 30, attempt: 31)
		let secondClaim = try PlanClaimRow(savedPlan: 61, attempt: 62, for: build)
		let chain = PlanChain(
			head: .record(fixedUlid(3)),
			records: [
				try first.step(first.prepared(base, expiresAt: expiresAt), wall: 1),
				try second.step(second.prepared(build, expiresAt: expiresAt), wall: 2),
				try second.step(second.claimed(secondClaim), wall: 3),
			])

		#expect(chain.committed(by: first.origin)?.id == first.id)
		#expect(chain.committed(by: second.origin)?.id == second.id)
		#expect(chain.committed(by: second.origin)?.latest == .claimed(secondClaim.claim))
		let retried = DraftKey(turn: first.origin.turn, attempt: AttemptID(ulid: fixedUlid(29)))
		#expect(chain.committed(by: retried) == nil)
	}

	@Test func unfinishedClaimsListEveryClaimWithNoSavedStepTwoAtOnceIncluded() throws {
		let first = PlanStepRows(confirmation: 1, turn: 20)
		let saved = PlanStepRows(confirmation: 2, turn: 30)
		let second = PlanStepRows(confirmation: 3, turn: 40)
		let waiting = PlanStepRows(confirmation: 4, turn: 50)
		let canceled = PlanStepRows(confirmation: 5, turn: 60)
		let firstClaim = try PlanClaimRow(savedPlan: 61, attempt: 62, for: base)
		let savedClaim = try PlanClaimRow(savedPlan: 71, attempt: 72, for: build)
		let secondClaim = try PlanClaimRow(savedPlan: 81, attempt: 82, for: build)
		let memory = storedRecord(
			device: PlanStepRows.phone, wall: 9,
			body: .synced(.memorySection(MemorySectionBody(name: .person, content: "Ada"))))
		let steps = [
			try first.step(first.prepared(base, expiresAt: expiresAt), wall: 1),
			try saved.step(saved.prepared(build, expiresAt: expiresAt), wall: 2),
			try first.step(first.claimed(firstClaim), wall: 3),
			try saved.step(saved.claimed(savedClaim), wall: 4),
			try second.step(second.prepared(build, expiresAt: expiresAt), wall: 5),
			try saved.step(saved.saved(savedClaim.savedPlanID), wall: 6),
			try second.step(second.claimed(secondClaim), wall: 7),
			try waiting.step(waiting.prepared(base, expiresAt: expiresAt), wall: 8),
			try canceled.step(canceled.prepared(base, expiresAt: expiresAt), wall: 10),
			try canceled.step(canceled.canceled(), wall: 11),
		]
		#expect(PlanStepRecord(memory) == nil)

		let chain = PlanChain(head: .record(fixedUlid(11)), records: steps)
		let unfinished = chain.unfinishedClaims

		#expect(unfinished.map(\.0.id) == [first.id, second.id])
		#expect(unfinished.map(\.1) == [steps[2], steps[6]])
		#expect(unfinished.map(\.2) == [firstClaim.claim, secondClaim.claim])
	}
}
