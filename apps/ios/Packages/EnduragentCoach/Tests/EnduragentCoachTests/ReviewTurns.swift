import EnduragentCoachFixtures
import Foundation
import Testing

@testable import EnduragentCoach

struct ReviewTurns {
	let transport = FakeModelTransport()
	let intervals = FakeIntervalsClient(athleteName: "Ada", ftp: 250)
	let store = InMemoryRecordLog()
	let clock: FixedClock

	static let authoredSteps =
		#"{"steps":[{"type":"warmup","duration":{"value":10,"unit":"minutes"},"power":{"kind":"percent_ftp","value":55}},{"type":"interval","duration":{"value":30,"unit":"minutes"},"power":{"kind":"percent_ftp","value":88}}]}"#

	static let fourChanges =
		#"{"kind":"complete","changes":[\#(PreparationFixture.ride(on: "1998-09-09")),\#(PreparationFixture.strength(on: "1998-09-10")),{"kind":"edit","eventId":201,"patch":{"structure":\#(authoredSteps)}},{"kind":"delete","eventId":202}]}"#

	static let oneRide =
		#"{"kind":"complete","changes":[\#(PreparationFixture.ride(on: "1998-09-09"))]}"#

	init(
		clock: FixedClock = FixedClock(
			now: "1998-09-08T00:30:00+12:00", timeZone: "Pacific/Auckland")
	) {
		self.clock = clock
		intervals.events = [
			PreparationFixture.workout(201, on: "1998-09-10"),
			PreparationFixture.workout(202, on: "1998-09-11"),
		]
	}

	func coach(over log: (any ReviewChainLog)? = nil) async -> Coach {
		await makeCoach(
			transport: transport, intervals: intervals, store: log ?? store, clock: clock,
			tools: .workoutReview)
	}

	func dyingCoach() async -> (Coach, FaultInjectingRecordLog) {
		let dying = FaultInjectingRecordLog(wrapping: store)
		return (await coach(over: dying), dying)
	}

	func relaunched() async -> Coach {
		let coach = await coach()
		await coach.lifecycle(.becameActive)
		return coach
	}

	func script(_ events: [ScriptedEvent]) {
		transport.respond = ScriptedReply.sequence(events, otherwise: transport.respond)
	}

	func reply(after calls: [ScriptedEvent], on coach: Coach, asking text: String = "Plan my week")
		async throws -> TurnID
	{
		script(calls + [.finish(reason: .toolCalls), .text("Ready."), .finish(reason: .stop)])
		let turn = try #require(try await coach.send(draft(text), to: .main).acceptedTurn)
		#expect(replyText(try #require(await coach.settledState(of: turn, in: .main))) == "Ready.")
		return turn
	}

	func committed(_ preparation: String, on coach: Coach) async throws -> WorkoutReview {
		_ = try await reply(after: [prepare(preparation)], on: coach)
		return try #require(try await head(of: coach).1)
	}

	func head(of coach: Coach) async throws -> (RecordHead, WorkoutReview?) {
		try await coach.ledger.reviewHead(chat: .main)
	}

	func store(_ fixture: String) async throws -> WorkoutReview {
		let review = try reviewFixture(fixture)
		_ = try await Ledger(log: store, clock: clock, diagnostics: DiagnosticsLog(clock: clock))
			.commit(
				review: review,
				stamp: testStamp(operation: .workoutReview(review.id, review.revision)),
				after: .empty)
		return review
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

	func settled(_ turn: TurnID) async throws -> [TurnSettledBody] {
		try await store.fetch(RecordQuery(scope: .synced([.turnSettled]), turn: turn)).records
			.compactMap { record in
				guard case .synced(.turnSettled(let body)) = record.body else { return nil }
				return body
			}
	}

	func markers(of turn: TurnID) async throws -> Int {
		try await store.fetch(RecordQuery(scope: .deviceLocal([.reviewPreparing]), turn: turn))
			.records.count
	}

	func view(of turn: TurnID, on coach: Coach) async throws -> TurnView {
		try #require(await coach.currentSnapshot(.main)?.turns.first { $0.id == turn })
	}

	func prepare(_ preparation: String) -> ScriptedEvent {
		.toolCall(name: "prepare_workout_changes", arguments: #"{"preparation":\#(preparation)}"#)
	}

	func revise(_ review: WorkoutReview, _ replacements: [(String, String)]) -> String {
		let items = replacements.map { #"{"id":"\#($0.0)","change":\#($0.1)}"# }
		return
			#"{"kind":"revise","base":\#(base(of: review)),"replacements":[\#(items.joined(separator: ","))]}"#
	}

	func base(of review: WorkoutReview) -> String {
		#"{"setId":"\#(review.id.ulid.rawValue)","revision":\#(review.revision.rawValue)}"#
	}

	static let notPrepared = AthleteNotice(key: Catalog.workoutsNotPrepared, actions: [])
}

extension ReviewChange {
	var reference: String { id.ulid.rawValue }
}
