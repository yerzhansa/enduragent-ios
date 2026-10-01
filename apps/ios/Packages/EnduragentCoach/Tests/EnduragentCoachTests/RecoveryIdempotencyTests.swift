import Foundation
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
				ulid: fixedUlid(1), hlc: clockAt(1), civilDate: "1998-06-13",
				timeZone: amsterdamZone, index: 0,
				draft: DraftID(), text: "Thursday?", slash: nil))
		return facts
	}

	func clockAt(_ wall: Int64) -> HybridLogicalClock {
		HybridLogicalClock(wallMs: wall, logical: 0, deviceId: device)
	}

	func claim(_ attempt: AttemptID, at wall: Int64, by process: ProcessID?) -> ClaimedAttempt {
		ClaimedAttempt(
			hlc: clockAt(wall),
			body: TurnClaimBody(
				chatId: .main, turn: turn, attempt: attempt, process: process,
				lease: .continuedProcessing))
	}

	func settled(_ attempt: AttemptID, at wall: Int64, _ settlement: Settlement) -> SettledAttempt {
		SettledAttempt(
			ulid: fixedUlid(Int(wall) + 100), hlc: clockAt(wall), attempt: attempt,
			settlement: settlement)
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
			TurnLifecycle.claimRefusal(of: facts, device: device, process: current)
				== .alreadyAnswered)
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

	@Test func aDeadClaimShowsHistoryUnavailableUntilRecoveryWrites() {
		var dead = facts()
		dead.claims = [claim(first, at: 2, by: earlier)]
		let state = TurnLifecycle.state(
			of: dead, live: nil, overlay: .notInThisProcess, device: device, process: current)
		#expect(
			state
				== .unrecovered(
					TurnState.Unrecovered(
						notice: AthleteNotice(key: Catalog.chatHistoryFailure, action: nil))))
		#expect(!state.retryable)
		#expect(
			TurnLifecycle.claimRefusal(of: dead, device: device, process: current) == .unrecovered)
		#expect(
			TurnLifecycle.writes(
				for: .claim(second, process: current, lease: .continuedProcessing), on: dead,
				chat: .main, device: device,
				mint: { turn }) == .failure(.unrecovered))
	}

	@Test func aDeadClaimShowsInterruptedOnceRecoveryWrites() {
		var recovered = facts()
		recovered.claims = [claim(first, at: 2, by: earlier)]
		recovered.settlements = [
			settled(first, at: 5, .interrupted(partial: "", cause: .processEnded, saved: .none))
		]
		let state = TurnLifecycle.state(
			of: recovered, live: nil, overlay: .notInThisProcess, device: device, process: current)
		#expect(
			state
				== .interrupted(
					TurnState.Interrupted(
						partial: "", cause: .processEnded, saved: .none,
						notice: AthleteNotice(
							key: Catalog.chatTurnInterruptedNothingChanged, action: .tryAgain(turn))
					)))
		#expect(state.retryable)
		#expect(TurnLifecycle.claimRefusal(of: recovered, device: device, process: current) == nil)
	}

	@Test func thisProcessesOpenClaimFoldsAsRunningNotDead() {
		var running = facts()
		running.claims = [claim(first, at: 2, by: current)]
		let state = TurnLifecycle.state(
			of: running, live: nil, overlay: .notInThisProcess, device: device, process: current)
		#expect(
			state
				== .processing(
					TurnState.Processing(
						attempt: first, liveText: "", activity: .generating(step: 1))))
		#expect(!state.retryable)
		#expect(
			TurnLifecycle.claimRefusal(of: running, device: device, process: current)
				== .attemptInFlight)
	}

	@Test func anUnsavedSettlementIsNewerThanEveryClaim() {
		var dead = facts()
		dead.claims = [claim(first, at: 9, by: earlier)]
		var segment = Segment(id: SegmentID(boundary: nil), openedBy: .chatStart)
		segment.turns = [dead]
		var conversation = Conversation(chat: .main, segments: [segment])
		conversation.settleInMemory(
			turn, attempt: second, .failed(.local(.recordStorage), saved: .none),
			ulid: fixedUlid(80), now: Date(timeIntervalSince1970: 0.001), device: device
		)
		let settled = conversation.turn(turn)
		#expect(settled?.latestAttempt == second)
		#expect(settled?.openClaim == nil)
	}

	@Test func aClaimKeepsItsProcessAndAnOlderClaimDecodesWithoutOne() throws {
		let claim = TurnClaimBody(
			chatId: .main, turn: turn, attempt: first, process: current, lease: .continuedProcessing
		)
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
							TurnClaimBody(
								chatId: .main, turn: turn, attempt: first, process: nil,
								lease: .gracePeriodOnly)))
				))
	}

	@Test func recoveryDoesNotFlipATurnAnsweredAfterAnUnsavedStop() async throws {
		let transport = FakeModelTransport()
		transport.hangUntilCancelled = true
		let store = InMemoryRecordLog()
		let faulty = FaultInjectingRecordLog(wrapping: store)
		let coach = await makeCoach(transport: transport, store: faulty, clock: clock)
		await coach.lifecycle(.becameActive)
		let turn = try #require(try await coach.send(draft("Thursday?"), to: .main).acceptedTurn)
		await coach.waitUntilProcessing(turn)
		faulty.failNextAppend = true
		await coach.stop(.main)
		#expect(await coach.state(of: turn)?.retryable == true)
		transport.hangUntilCancelled = false
		transport.script = [.text("Thursday is on."), .finish(reason: .stop)]
		try await coach.retry(turn, in: .main)
		let replied = try await coach.waitForState(of: turn) { $0.flatMap(replyText) != nil }
		#expect(replied.flatMap(replyText) == "Thursday is on.")
		let recording = BatchRecordingLog(inner: store)
		let reopened = await makeCoach(transport: transport, store: recording, clock: clock)
		await reopened.lifecycle(.becameActive)
		#expect(await reopened.state(of: turn).flatMap(replyText) == "Thursday is on.")
		#expect(recording.batches.isEmpty)
		#expect(await reopened.transcript(.main) == ["Thursday?", "Thursday is on."])
	}

	@Test func aRerunRecoveryLeavesThisProcessesRunningClaimAlone() async throws {
		let transport = FakeModelTransport()
		transport.hangUntilCancelled = true
		let log = FaultInjectingRecordLog(wrapping: InMemoryRecordLog())
		log.failRecoveryReads = true
		let coach = await makeCoach(transport: transport, store: log, clock: clock)
		await coach.lifecycle(.becameActive)
		let turn = try #require(try await coach.send(draft("Thursday?"), to: .main).acceptedTurn)
		await coach.waitUntilProcessing(turn)
		log.failRecoveryReads = false
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
		let log = FaultInjectingRecordLog(wrapping: inner)
		log.failRecoveryReads = true
		let coach = await makeCoach(transport: transport, store: log, clock: clock)
		await coach.lifecycle(.becameActive)
		let turn = try #require(try await coach.send(draft("Thursday?"), to: .main).acceptedTurn)
		await coach.waitUntilProcessing(turn)
		log.failRecoveryReads = false
		await coach.lifecycle(.becameActive)
		let settled = try await coach.waitForState(of: turn) { $0.flatMap(replyText) != nil }
		#expect(settled.flatMap(replyText) == "Thursday is on.")
		let settlements = try await inner.fetch(
			RecordQuery(scope: .synced([.turnSettled]), turn: turn)
		).records
		#expect(settlements.count == 1)
	}

	@Test func aClaimOnAnotherDevicesTurnIsLeftAlone() async throws {
		let store = InMemoryRecordLog()
		let otherTransport = FakeModelTransport()
		otherTransport.hangUntilCancelled = true
		let other = await makeCoach(
			transport: otherTransport,
			store: DeviceAliasLog(inner: store, deviceId: DeviceID(rawValue: "phone-b")),
			clock: clock)
		let turn = try #require(try await other.send(draft("Thursday?"), to: .main).acceptedTurn)
		await other.waitUntilProcessing(turn)
		let transport = FakeModelTransport()
		let recording = BatchRecordingLog(inner: store)
		let mine = await makeCoach(transport: transport, store: recording, clock: clock)
		await mine.lifecycle(.becameActive)
		#expect(recording.batches == [["providerConsent"]])
		#expect(await mine.state(of: turn) == .accepted(.onOtherDevice))
		await #expect(throws: RetryRefusal.acceptedOnOtherDevice) {
			try await mine.retry(turn, in: .main)
		}
		#expect(transport.requests.isEmpty)
		await other.stop(.main)
	}
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

	func latest(locality: RecordLocality, writtenBy: DeviceID) async throws -> RecordCursor? {
		try await inner.latest(locality: locality, writtenBy: writtenBy)
	}

	func fetch(_ query: RecordQuery) async throws -> RecordPage {
		try await inner.fetch(query)
	}

	var imports: AsyncStream<Void> { inner.imports }
}
