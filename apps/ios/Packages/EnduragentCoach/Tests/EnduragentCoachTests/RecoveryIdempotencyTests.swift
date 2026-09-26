import Foundation
import Synchronization
import Testing

@testable import EnduragentCoach

@Suite struct RecoveryIdempotencyTests {
	let clock = FixedClock(now: "1998-06-13T08:00:00+02:00", timeZone: "Europe/Amsterdam")
	let device = DeviceID(rawValue: "phone-a")
	let earlier = ProcessID(ulid: fixedUlid(50))
	let current = ProcessID(ulid: fixedUlid(51))
	let turn = TurnID(ulid: fixedUlid(1))
	let first = AttemptID(ulid: fixedUlid(2))
	let second = AttemptID(ulid: fixedUlid(3))

	func facts(on origin: DeviceID? = nil) -> TurnFacts {
		var facts = TurnFacts(turn: turn, chat: .main, origin: origin ?? device)
		facts.fragments.append(
			Fragment(
				ulid: fixedUlid(1), hlc: clockAt(1), civilDate: "1998-06-13", index: 0,
				draft: DraftID(), text: "Thursday?", slash: nil))
		return facts
	}

	func clockAt(_ wall: Int64) -> HybridLogicalClock {
		HybridLogicalClock(wallMs: wall, logical: 0, deviceId: device)
	}

	func claim(_ attempt: AttemptID, at wall: Int64, by process: ProcessID?) -> ClaimedAttempt {
		ClaimedAttempt(
			hlc: clockAt(wall),
			body: TurnClaimBody(chatId: .main, turn: turn, attempt: attempt, process: process))
	}

	func settled(_ attempt: AttemptID, at wall: Int64, _ settlement: Settlement) -> SettledAttempt {
		SettledAttempt(
			ulid: fixedUlid(Int(wall) + 100), hlc: clockAt(wall), civilDate: "1998-06-13",
			attempt: attempt, settlement: settlement)
	}

	@Test func aLateSettlementOfAnOlderAttemptDoesNotOverrideTheLatestAttempt() {
		var facts = facts()
		facts.claims = [claim(first, at: 2, by: earlier), claim(second, at: 4, by: earlier)]
		facts.settlements = [
			settled(second, at: 5, .replied(.model("Thursday is on."), lineage: nil)),
			settled(first, at: 9, .interrupted(partial: "", cause: .processEnded, saved: .none)),
		]
		#expect(facts.latestSettlement?.attempt == second)
		#expect(facts.openClaim == nil)
		let state = TurnLifecycle.state(
			of: facts, live: nil, overlay: .notInThisProcess, device: device, process: current)
		#expect(state == .completed(TurnState.Completed(reply: .model("Thursday is on."))))
		#expect(
			TurnLifecycle.claimRefusal(of: facts, device: device) == .alreadyAnswered)
	}

	@Test func aSettlementWithoutAClaimAfterAClaimedAttemptIsTheOutcome() {
		var facts = facts()
		facts.claims = [claim(first, at: 2, by: current)]
		facts.settlements = [
			settled(first, at: 3, .failed(.model(.providerDown(.outage)), saved: .none)),
			settled(
				second, at: 6, .interrupted(partial: "", cause: .stoppedBeforeStart, saved: .none)),
		]
		#expect(facts.latestSettlement?.attempt == second)
	}

	@Test func onlyADeadClaimThatIsTheLatestAttemptIsPlanned() {
		var superseded = facts()
		superseded.claims = [claim(first, at: 2, by: earlier), claim(second, at: 4, by: earlier)]
		superseded.settlements = [
			settled(second, at: 5, .replied(.model("Thursday is on."), lineage: nil))
		]
		#expect(
			TurnRecovery.plan(turns: [superseded], writes: [:], device: device, process: current)
				== RecoveryPlan(interrupt: []))
		var dead = facts()
		dead.claims = [claim(first, at: 2, by: earlier), claim(second, at: 4, by: earlier)]
		dead.settlements = [
			settled(first, at: 3, .failed(.model(.providerDown(.outage)), saved: .none))
		]
		#expect(
			TurnRecovery.plan(turns: [dead], writes: [:], device: device, process: current)
				== RecoveryPlan(interrupt: [DeadClaim(turn: turn, attempt: second, saved: .none)]))
	}

	@Test func aClaimFromThisProcessIsNeverPlanned() {
		var live = facts()
		live.claims = [claim(first, at: 2, by: current)]
		#expect(
			TurnRecovery.plan(turns: [live], writes: [:], device: device, process: current)
				== RecoveryPlan(interrupt: []))
		var beforeProcessIDs = facts()
		beforeProcessIDs.claims = [claim(first, at: 2, by: nil)]
		#expect(
			TurnRecovery.plan(
				turns: [beforeProcessIDs], writes: [:], device: device, process: current)
				== RecoveryPlan(interrupt: [DeadClaim(turn: turn, attempt: first, saved: .none)]))
	}

	@Test func aClaimOnATurnFromAnotherDeviceIsNeverPlanned() {
		var elsewhere = facts(on: DeviceID(rawValue: "phone-b"))
		elsewhere.claims = [claim(first, at: 2, by: earlier)]
		#expect(
			TurnRecovery.plan(turns: [elsewhere], writes: [:], device: device, process: current)
				== RecoveryPlan(interrupt: []))
	}

	@Test func aDeadClaimShowsInterruptedBeforeRecoveryWrites() {
		var dead = facts()
		dead.claims = [claim(first, at: 2, by: earlier)]
		let state = TurnLifecycle.state(
			of: dead, live: nil, overlay: .notInThisProcess, device: device, process: current)
		#expect(
			state
				== .interrupted(
					TurnState.Interrupted(
						partial: "", cause: .processEnded, saved: .none,
						notice: AthleteNotice(
							key: Catalog.chatTurnInterruptedNothingChanged, action: .tryAgain(turn))
					)))
		#expect(state.retryable)
	}

	@Test func anUnsavedSettlementIsNewerThanEveryClaim() {
		var dead = facts()
		dead.claims = [claim(first, at: 9, by: earlier)]
		var segment = Segment(id: SegmentID(boundary: nil), openedBy: .chatStart)
		segment.turns = [dead]
		var conversation = Conversation(chat: .main, segments: [segment])
		conversation.settleInMemory(
			turn, attempt: second, .failed(.local(.recordStorage), saved: .none),
			ulid: fixedUlid(80), now: Date(timeIntervalSince1970: 0.001), zone: .gmt, device: device
		)
		let settled = conversation.turn(turn)
		#expect(settled?.latestAttempt == second)
		#expect(settled?.openClaim == nil)
	}

	@Test func aClaimKeepsItsProcessAndAnOlderClaimDecodesWithoutOne() throws {
		let claim = TurnClaimBody(chatId: .main, turn: turn, attempt: first, process: current)
		let encoded = try RecordCodec.encode(.deviceLocal(.turnClaim(claim)))
		#expect(
			RecordCodec.decode(
				kind: "turnClaim", version: encoded.version, data: encoded.data,
				civilDate: "1998-06-13", ulid: fixedUlid(70).rawValue)
				== .success(.deviceLocal(.turnClaim(claim))))
		let older = Data(
			#"{"attempt":"\#(first.ulid.rawValue)","chatId":"main","turn":"\#(turn.ulid.rawValue)"}"#
				.utf8)
		#expect(
			RecordCodec.decode(
				kind: "turnClaim", version: 2, data: older, civilDate: "1998-06-13",
				ulid: fixedUlid(71).rawValue)
				== .success(
					.deviceLocal(
						.turnClaim(
							TurnClaimBody(chatId: .main, turn: turn, attempt: first, process: nil)))
				))
	}

	@Test func recoveryDoesNotFlipATurnAnsweredAfterAnUnsavedStop() async throws {
		let transport = FakeModelTransport()
		transport.hangUntilCancelled = true
		let store = InMemoryRecordLog()
		let faulty = FaultInjectingRecordLog(wrapping: store)
		let coach = makeCoach(transport: transport, store: faulty, clock: clock)
		await coach.lifecycle(.becameActive)
		let turn = try #require(try await coach.send(draft("Thursday?"), to: .main).acceptedTurn)
		await coach.waitUntilProcessing(turn)
		faulty.failNextAppend = true
		await coach.stop(.main)
		#expect(await coach.state(of: turn)?.retryable == true)
		transport.hangUntilCancelled = false
		transport.script = [.text("Thursday is on."), .finish(reason: .stop)]
		try await coach.retry(turn, in: .main)
		let replied = try await state(of: turn, in: coach) { $0.flatMap(replyText) != nil }
		#expect(replied.flatMap(replyText) == "Thursday is on.")
		let recording = BatchRecordingLog(inner: store)
		let reopened = makeCoach(transport: transport, store: recording, clock: clock)
		await reopened.lifecycle(.becameActive)
		#expect(await reopened.state(of: turn).flatMap(replyText) == "Thursday is on.")
		#expect(recording.batches.isEmpty)
		#expect(await reopened.transcript(.main) == ["Thursday?", "Thursday is on."])
	}

	@Test func aRerunRecoveryLeavesThisProcessesRunningClaimAlone() async throws {
		let transport = FakeModelTransport()
		transport.hangUntilCancelled = true
		let log = ClaimReadFaultLog(inner: InMemoryRecordLog())
		let coach = makeCoach(transport: transport, store: log, clock: clock)
		await coach.lifecycle(.becameActive)
		let turn = try #require(try await coach.send(draft("Thursday?"), to: .main).acceptedTurn)
		await coach.waitUntilProcessing(turn)
		log.failing.withLock { $0 = false }
		await coach.lifecycle(.becameActive)
		let state = await coach.state(of: turn)
		guard case .processing? = state else {
			Issue.record("expected the live turn to keep running, got \(String(describing: state))")
			return
		}
		await coach.stop(.main)
	}

	@Test func aRerunRecoveryDoesNotLoseThisProcessesReply() async throws {
		let transport = FakeModelTransport()
		transport.script = [.text("Thursday is on."), .finish(reason: .stop)]
		transport.requestDelay = .milliseconds(500)
		let inner = InMemoryRecordLog()
		let log = ClaimReadFaultLog(inner: inner)
		let coach = makeCoach(transport: transport, store: log, clock: clock)
		await coach.lifecycle(.becameActive)
		let turn = try #require(try await coach.send(draft("Thursday?"), to: .main).acceptedTurn)
		await coach.waitUntilProcessing(turn)
		log.failing.withLock { $0 = false }
		await coach.lifecycle(.becameActive)
		let settled = try await state(of: turn, in: coach) { $0.flatMap(replyText) != nil }
		#expect(settled.flatMap(replyText) == "Thursday is on.")
		let settlements = try await inner.fetch(
			RecordQuery(scope: .synced([.turnSettled]), turn: turn)
		).records
		#expect(settlements.count == 1)
	}

	@Test func aDeadClaimShowsInterruptedWhileRecoveryCannotRead() async throws {
		let transport = FakeModelTransport()
		transport.hangUntilCancelled = true
		let store = InMemoryRecordLog()
		let dying = FaultInjectingRecordLog(wrapping: store)
		let before = makeCoach(transport: transport, store: dying, clock: clock)
		let turn = try #require(try await before.send(draft("Thursday?"), to: .main).acceptedTurn)
		await before.waitUntilProcessing(turn)
		await before.dieWithoutWriting(to: dying)
		let after = makeCoach(
			transport: transport, store: ClaimReadFaultLog(inner: store), clock: clock)
		await after.lifecycle(.becameActive)
		let state = try #require(await after.state(of: turn))
		#expect(state != .accepted(.awaitingRestart))
		guard case .interrupted(let interrupted) = state else {
			Issue.record("expected interrupted, got \(state)")
			return
		}
		#expect(interrupted.cause == .processEnded)
		#expect(
			try await store.fetch(RecordQuery(scope: .synced([.turnSettled]), turn: turn)).records
				.isEmpty)
	}

	@Test func aClaimOnAnotherDevicesTurnIsLeftAlone() async throws {
		let store = InMemoryRecordLog()
		let otherTransport = FakeModelTransport()
		otherTransport.hangUntilCancelled = true
		let other = makeCoach(
			transport: otherTransport,
			store: DeviceAliasLog(inner: store, deviceId: DeviceID(rawValue: "phone-b")),
			clock: clock)
		let turn = try #require(try await other.send(draft("Thursday?"), to: .main).acceptedTurn)
		await other.waitUntilProcessing(turn)
		let transport = FakeModelTransport()
		let recording = BatchRecordingLog(inner: store)
		let mine = makeCoach(transport: transport, store: recording, clock: clock)
		await mine.lifecycle(.becameActive)
		#expect(recording.batches.isEmpty)
		#expect(await mine.state(of: turn) == .accepted(.onOtherDevice))
		await #expect(throws: RetryRefusal.acceptedOnOtherDevice) {
			try await mine.retry(turn, in: .main)
		}
		#expect(transport.requests.isEmpty)
		await other.stop(.main)
	}

	private func state(
		of turn: TurnID, in coach: Coach, within limit: Duration = .seconds(5),
		until matches: (TurnState?) -> Bool
	) async throws -> TurnState? {
		let deadline = ContinuousClock.now + limit
		while ContinuousClock.now < deadline {
			let state = await coach.state(of: turn)
			if matches(state) { return state }
			try await Task.sleep(for: .milliseconds(10))
		}
		return await coach.state(of: turn)
	}
}

final class ClaimReadFaultLog: RecordLog, Sendable {
	let inner: any RecordLog
	let failing = Mutex(true)

	init(inner: any RecordLog) {
		self.inner = inner
	}

	var deviceId: DeviceID { inner.deviceId }

	func append(_ batch: [AthleteRecord], locality: RecordLocality) async throws {
		try await inner.append(batch, locality: locality)
	}

	func fetch(_ query: RecordQuery) async throws -> RecordPage {
		if failing.withLock({ $0 }), query.writtenBy != nil,
			query.scope.kindNames == ["turnClaim"]
		{
			throw RecordStorageFault(operation: .fetch)
		}
		return try await inner.fetch(query)
	}

	var imports: AsyncStream<Void> { inner.imports }
}

final class DeviceAliasLog: RecordLog, Sendable {
	let inner: any RecordLog
	let deviceId: DeviceID

	init(inner: any RecordLog, deviceId: DeviceID) {
		self.inner = inner
		self.deviceId = deviceId
	}

	func append(_ batch: [AthleteRecord], locality: RecordLocality) async throws {
		try await inner.append(batch, locality: locality)
	}

	func fetch(_ query: RecordQuery) async throws -> RecordPage {
		try await inner.fetch(query)
	}

	var imports: AsyncStream<Void> { inner.imports }
}
