import EnduragentCoachFixtures
import Foundation
import Synchronization
import Testing

@testable import EnduragentCoach

final class InterleavingChainLog: ChainForwardingLog {
	typealias Step = @Sendable () async throws -> Void

	let inner: InMemoryRecordLog
	private let armed = Mutex<Interleaving?>(nil)

	private struct Interleaving {
		let query: RecordQuery
		var remaining: Int
		var ran = 0
		let step: Step
	}

	init(_ inner: InMemoryRecordLog) {
		self.inner = inner
	}

	var chainStore: any ReviewChainLog { inner }
	var deviceId: DeviceID { inner.deviceId }
	var imports: AsyncStream<Void> { inner.imports }
	var interleaved: Int { armed.withLock { $0?.ran ?? 0 } }

	func interleave(on query: RecordQuery, times: Int, _ step: @escaping Step) {
		armed.withLock { $0 = Interleaving(query: query, remaining: times, step: step) }
	}

	func latest(locality: RecordLocality, writtenBy: DeviceID) async throws -> RecordCursor? {
		try await inner.latest(locality: locality, writtenBy: writtenBy)
	}

	func fetch(_ query: RecordQuery) async throws -> RecordPage {
		try await inner.fetch(query)
	}

	func append(_ batch: [AthleteRecord], locality: RecordLocality) async throws {
		try await inner.append(batch, locality: locality)
	}

	func append(_ record: AthleteRecord, after head: RecordHead, in query: RecordQuery)
		async throws
	{
		let step = armed.withLock { current -> Step? in
			guard var interleaving = current, interleaving.query == query,
				interleaving.remaining > 0
			else { return nil }
			interleaving.remaining -= 1
			interleaving.ran += 1
			current = interleaving
			return interleaving.step
		}
		try await step?()
		try await inner.append(record, after: head, in: query)
	}
}

struct PlanTurns {
	static let notPrepared = AthleteNotice(key: Catalog.chatPlanSaveNotPrepared, actions: [])
	static let baseBuild: JSONValue = .object([
		"name": .string("Base Build"), "primaryGoal": .string("Gran fondo"),
		"totalWeeks": .number(12),
		"phases": .array([
			.object([
				"focus": .string("base_building"), "durationWeeks": .number(8),
				"volumeTargets": .object(["cycling": .object(["hoursPerCycle": .number(7.5)])]),
			]),
			.object(["focus": .string("taper"), "durationWeeks": .number(4)]),
		]),
	])
	static let threshold: JSONValue = .object([
		"name": .string("Threshold Block"), "totalWeeks": .number(6),
	])

	let clock: HeldClock
	let transport: FakeModelTransport
	let intervals = FakeIntervalsClient(athleteName: "Ada", ftp: 250)
	let store: InMemoryRecordLog

	init(clock: HeldClock = HeldClock(), store: InMemoryRecordLog = InMemoryRecordLog()) {
		self.clock = clock
		self.store = store
		transport = FakeModelTransport(clock: clock)
	}

	func coach(over log: (any ReviewChainLog)? = nil, secrets: any SecretStore = keyedSecrets())
		async -> Coach
	{
		await makeCoach(
			transport: transport, intervals: intervals, store: log ?? store, clock: clock,
			secrets: secrets)
	}

	func script(_ events: [ScriptedEvent]) {
		transport.respond = ScriptedReply.sequence(events, otherwise: transport.respond)
	}

	func save(_ plan: JSONValue) -> ScriptedEvent {
		.toolCall(name: "plan_save", arguments: canonicalJSON(.object(["plan": plan])))
	}

	func reply(
		after steps: [[ScriptedEvent]], on coach: Coach, asking text: String = "Save my plan"
	)
		async throws -> TurnID
	{
		script(
			steps.flatMap { $0 + [.finish(reason: .toolCalls)] } + [
				.text("Ready."), .finish(reason: .stop),
			])
		let turn = try #require(try await coach.send(draft(text), to: .main).acceptedTurn)
		#expect(replyText(try #require(await coach.settledState(of: turn, in: .main))) == "Ready.")
		return turn
	}

	func steps(in log: any RecordLog) async throws -> [PlanStepRecord] {
		try await log.fetch(.planChain(of: .main)).records.compactMap(PlanStepRecord.init)
	}

	func prepared(in log: any RecordLog) async throws -> [PreparedPlanSave] {
		try await steps(in: log).compactMap { step in
			guard case .prepared(let prepared) = step.body.step else { return nil }
			return prepared
		}
	}

	func savedPlanRows() async throws -> Int {
		try await store.fetch(RecordQuery(scope: .synced([SavedPlans.kind]))).records.count
	}

	func settled(_ turn: TurnID) async throws -> [TurnSettledBody] {
		try await store.fetch(RecordQuery(scope: .synced([.turnSettled]), turn: turn)).records
			.compactMap { record in
				guard case .synced(.turnSettled(let body)) = record.body else { return nil }
				return body
			}
	}

	func view(of turn: TurnID, on coach: Coach) async throws -> TurnView {
		try #require(await coach.currentSnapshot(.main)?.turns.first { $0.id == turn })
	}

	func toolData() throws -> [JSONValue] {
		let request = try #require(
			transport.requests.last(where: { request in
				request.messages.contains { $0.role == .tool }
			}))
		let turnStart = request.messages.lastIndex { $0.role == .user } ?? 0
		return try request.messages[turnStart...].filter { $0.role == .tool }.map {
			try #require(try JSONValue.parse($0.content).objectFields["data"])
		}
	}

	func calendarWrites() -> [FakeIntervalsCall] {
		intervals.calls.filter { call in
			switch call {
			case .createEvent, .updateEvent, .deleteEvent: true
			case .profile, .activities, .wellness, .activity, .streams, .events: false
			}
		}
	}

	static func moveHead(of log: InMemoryRecordLog, foreign confirmation: Int) async throws {
		let query = RecordQuery.planChain(of: .main)
		let wall = try await log.fetch(query).records.map(\.hlc.wallMs).max() ?? 0
		let rows = PlanStepRows(confirmation: confirmation, turn: confirmation + 1)
		try await log.append(
			[
				storedRecord(
					device: PlanStepRows.phone, wall: wall + 1, ulid: fixedUlid(confirmation),
					body: try rows.canceled())
			], locality: .deviceLocal)
	}
}
