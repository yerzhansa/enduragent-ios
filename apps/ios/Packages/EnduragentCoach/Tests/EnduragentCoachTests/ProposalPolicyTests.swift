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
		let proposal = try await propose()
		clock.advance(by: 11 * 60)
		let lookup = try await take(proposal.nonce)
		#expect(lookup == .expired)
	}

	@Test func wrongNonceIsMismatch() async throws {
		_ = try await propose()
		let lookup = try await take(Nonce())
		#expect(lookup == .mismatch)
	}

	@Test func replacementClearsPreviousNonce() async throws {
		let first = try await propose(name: "One")
		let second = try await propose(name: "Two")
		let firstLookup = try await take(first.nonce)
		#expect(firstLookup == .mismatch)
		let secondLookup = try await take(second.nonce)
		guard case .found(let body) = secondLookup else {
			Issue.record("expected found")
			return
		}
		#expect(body.summary.contains("Two"))
	}

	@Test func secondTakeIsNone() async throws {
		let proposal = try await propose()
		_ = try await take(proposal.nonce)
		let again = try await take(proposal.nonce)
		#expect(again == .none)
	}

	@Test func proposalRowsCarryTheTurnStampAndTheTakeCarriesAChangeSet() async throws {
		let stamp = testStamp()
		_ = try await propose(stamp: stamp)
		let proposed = try await store.fetch(RecordQuery(scope: .deviceLocal([.pendingProposal])))
			.records
		#expect(proposed.map(\.cause) == [.operation(stamp.operation, stamp.attempt)])
		let proposal = try #require(
			proposed.first.flatMap { record -> ProposalBody? in
				if case .deviceLocal(.pendingProposal(let body)) = record.body { return body }
				return nil
			})
		_ = try await take(proposal.nonce)
		let cleared = try await store.fetch(RecordQuery(scope: .deviceLocal([.proposalCleared])))
			.records
		guard case .operation(.workoutChangeSet, _)? = cleared.first?.cause else {
			Issue.record(
				"expected a change-set stamp on the clear, got \(String(describing: cleared.first?.cause))"
			)
			return
		}
	}

	private func take(_ nonce: Nonce) async throws -> ProposalLookup {
		try await ProposalPolicy.take(
			chatId: .main,
			nonce: nonce,
			ledger: ledger,
			binding: ActionBinding(account: .unconnected, zone: amsterdamZone),
			now: clock.now,
			run: { _ in .object([:]) }
		)
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
		return try await ProposalPolicy.propose(
			chatId: .main,
			tool: .intervalsCreateWorkout,
			input: input,
			summary: ProposalPolicy.summary(for: input),
			description: "Warmup\n- 10m 55-65%",
			now: clock.now,
			ledger: ledger,
			stamp: stamp
		)
	}
}
