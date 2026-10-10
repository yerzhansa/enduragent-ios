import EnduragentCoachFixtures
import Foundation
import Testing

@testable import EnduragentCoach

@Suite struct RefusedStartSnapshotTests {
	@Test func aRefusedTurnShowsItsFailureWhileTheNextTurnStarts() async throws {
		let secondClaim = HeldAppendLog(
			inner: InMemoryRecordLog(), holding: "turnClaim", occurrence: 2)
		let firstClaim = HeldAppendLog(inner: secondClaim, holding: "turnClaim", occurrence: 1)
		defer {
			firstClaim.release()
			secondClaim.release()
		}
		let transport = FakeModelTransport()
		let coach = await makeCoach(
			transport: transport, store: firstClaim,
			coalescing: CoalescingPolicy(window: .seconds(60)),
			secrets: ICloudKeychainStore(backing: FixtureSecretStoreBacking()))
		var snapshots = await coach.observe(.main).makeAsyncIterator()
		let first = try #require(try await coach.send(draft("Thursday?"), to: .main).acceptedTurn)
		await coach.lifecycle(.enteredBackground)
		try await firstClaim.waitUntilReached()
		let second = try #require(try await coach.send(draft("Friday?"), to: .main).acceptedTurn)
		await coach.lifecycle(.enteredBackground)
		while let snapshot = await snapshots.next() {
			if snapshot.turns.last?.state == .accepted(.queued(position: 2)) { break }
		}
		firstClaim.release()
		try await secondClaim.waitUntilReached()
		let shown = try #require(await snapshots.next())
		let firstState = try #require(shown.turns.first(where: { $0.id == first })?.state)
		#expect(failure(firstState) == .model(.accessUnavailable(.notConfigured(.credits))))
		#expect(shown.turns.last?.id == second)
		#expect(shown.turns.last?.state == .accepted(.queued(position: 1)))
		#expect(shown.activity == .working(label: Catalog.chatNoticeWorking))
		secondClaim.release()
		_ = try #require(await coach.settledState(of: second, in: .main))
		#expect(transport.requests.isEmpty)
	}

	@Test(arguments: StartRefusal.allCases)
	func aRefusedStartPublishesItsFailureAsSoonAsItSettles(_ refusal: StartRefusal) async throws {
		let (coach, claim, transport) = try await heldStart(refusal)
		defer { claim.release() }
		var snapshots = await coach.observe(.main).makeAsyncIterator()
		let turn = try #require(try await coach.send(draft("Hello"), to: .main).acceptedTurn)
		await coach.lifecycle(.enteredBackground)
		try await claim.waitUntilReached()
		while let snapshot = await snapshots.next() {
			if snapshot.turns.first?.state == .accepted(.queued(position: 1)) { break }
		}
		claim.release()
		let shown = try #require(await snapshots.next())
		let state = try #require(shown.turns.first(where: { $0.id == turn })?.state)
		#expect(failure(state) == refusal.failure)
		#expect(shown.activity == .idle)
		_ = try #require(await coach.settledState(of: turn, in: .main))
		#expect(transport.requests.isEmpty)
	}

	@Test(arguments: StartRefusal.allCases)
	func stopDuringARefusedStartPublishesTheFailureWhileStopping(_ refusal: StartRefusal)
		async throws
	{
		let (coach, claim, transport) = try await heldStart(refusal)
		defer { claim.release() }
		var snapshots = await coach.observe(.main).makeAsyncIterator()
		let turn = try #require(try await coach.send(draft("Hello"), to: .main).acceptedTurn)
		await coach.lifecycle(.enteredBackground)
		try await claim.waitUntilReached()
		async let stopped: Void = coach.stop(.main)
		while let snapshot = await snapshots.next() {
			if snapshot.activity == .stopping { break }
		}
		claim.release()
		let shown = try #require(await snapshots.next())
		let state = try #require(shown.turns.first(where: { $0.id == turn })?.state)
		#expect(failure(state) == refusal.failure)
		#expect(shown.activity == .stopping)
		await stopped
		#expect(await coach.currentSnapshot(.main)?.activity == .idle)
		#expect(transport.requests.isEmpty)
	}

	private func heldStart(_ refusal: StartRefusal) async throws
		-> (Coach, HeldAppendLog, FakeModelTransport)
	{
		let log = FaultInjectingRecordLog(wrapping: InMemoryRecordLog())
		let backing = FixtureSecretStoreBacking()
		let secrets =
			refusal == .missingKey
			? ICloudKeychainStore(backing: backing) : keyedSecrets(backing: backing)
		if refusal == .lockedKeychain { backing.locked = true }
		if refusal == .claimStorage { try log.failAppends(ofKind: "turnClaim") }
		let claim = HeldAppendLog(inner: log, holding: "turnClaim", occurrence: 1)
		let transport = FakeModelTransport()
		let coach = await makeCoach(
			transport: transport, store: claim,
			coalescing: CoalescingPolicy(window: .seconds(60)), secrets: secrets)
		return (coach, claim, transport)
	}

	enum StartRefusal: CaseIterable, Sendable {
		case missingKey
		case lockedKeychain
		case claimStorage

		var failure: CoachFailure {
			switch self {
			case .missingKey: .model(.accessUnavailable(.notConfigured(.credits)))
			case .lockedKeychain: .model(.accessUnavailable(.secureStorageLocked))
			case .claimStorage: .local(.recordStorage)
			}
		}
	}
}
