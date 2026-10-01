import Foundation
import Testing

@testable import EnduragentCoach

@Suite
struct ProposalPolicyTests {
	let store = InMemoryRecordLog()
	let clock = FixedClock(now: "1998-06-13T08:00:00+02:00", timeZone: "Europe/Amsterdam")
	let ledger: Ledger

	init() {
		ledger = Ledger(log: store, clock: clock, diagnostics: DiagnosticsLog(clock: clock))
	}

	@Test func expiredProposalAfterElevenMinutes() async throws {
		_ = try await propose()
		clock.advance(by: 11 * 60)
		#expect(try await live() == nil)
	}

	@Test func replacementClearsPreviousNonce() async throws {
		let first = try await propose(name: "One")
		let second = try await propose(name: "Two")
		let current = try #require(try await live())
		#expect(current.body.nonce == second.nonce)
		#expect(current.body.summary.contains("Two"))
		let cleared = try await store.fetch(RecordQuery(scope: .deviceLocal([.proposalCleared])))
			.records
		#expect(
			cleared.map(\.body) == [
				.deviceLocal(
					.proposalCleared(
						ProposalClearedBody(chatId: .main, nonce: first.nonce, reason: .replaced)))
			])
	}

	@Test func canceledClearHidesTheProposal() async throws {
		_ = try await propose()
		let current = try #require(try await live())
		try await ProposalPolicy.clear(
			current, reason: .canceled, ledger: ledger, stamp: testStamp())
		#expect(try await live() == nil)
	}

	@Test func proposalRowsCarryTheTurnStampAndTheClearCarriesItsOwn() async throws {
		let stamp = testStamp()
		_ = try await propose(stamp: stamp)
		let proposed = try await store.fetch(RecordQuery(scope: .deviceLocal([.pendingProposal])))
			.records
		#expect(proposed.map(\.cause) == [.operation(stamp.operation, stamp.attempt)])
		let current = try #require(try await live())
		#expect(current.ulid == proposed.first?.ulid)
		let clear = OperationStamp(
			operation: .workoutChangeSet(
				ChangeSetID(ulid: current.ulid), ChangeSetRevision(rawValue: 1)),
			attempt: AttemptID(ulid: fixedUlid(77)),
			binding: ActionBinding(account: .unconnected, zone: amsterdamZone))
		try await ProposalPolicy.clear(current, reason: .executed, ledger: ledger, stamp: clear)
		let cleared = try await store.fetch(RecordQuery(scope: .deviceLocal([.proposalCleared])))
			.records
		#expect(cleared.map(\.cause) == [.operation(clear.operation, clear.attempt)])
	}

	private func live() async throws -> LiveProposal? {
		try await ProposalPolicy.live(chatId: .main, ledger: ledger, now: clock.now)
	}

	private func propose(name: String = "Endurance", stamp: OperationStamp = testStamp())
		async throws -> PendingProposal
	{
		let workout = IntervalsWorkoutInput(
			name: name,
			steps: [
				.simple(
					SimpleStep(
						type: .warmup,
						duration: DurationInput(value: 10, unit: .minutes),
						power: PowerTarget(kind: .percentFtp, value: nil, low: 55, high: 65),
						cadence: nil,
						label: nil
					)
				)
			]
		)
		let input = GatedToolInput.createWorkout(date: "1998-06-14", workout: workout)
		return try await makeReviews(ledger: ledger, clock: clock).propose(
			chatId: .main,
			tool: .intervalsCreateWorkout,
			input: input,
			summary: ProposalPolicy.summary(for: input),
			description: "Warmup\n- 10m 55-65%",
			scope: TurnScope(stamp: stamp, policy: .npm, ladder: .npm, uptime: clock.uptime)
		)
	}
}
