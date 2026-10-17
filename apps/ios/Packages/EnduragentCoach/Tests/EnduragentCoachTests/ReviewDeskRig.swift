import EnduragentCoachFixtures
import Foundation
import Synchronization
import Testing

@testable import EnduragentCoach

enum CalendarTouch: Equatable, Sendable {
	case read
	case write(CalendarWrite)
}

final class ScriptedCalendar: TrainingClient {
	typealias Answer = @Sendable (Int, CalendarWrite) async -> IntervalsWriteAnswer?
	typealias Observer = @Sendable (CalendarTouch) async -> Void

	let base: FakeIntervalsClient
	private let script = Mutex(Script())

	private struct Script {
		var calls: [CalendarTouch] = []
		var writes = 0
		var readsFail = false
		var answer: Answer?
		var observe: Observer?
	}

	init(_ base: FakeIntervalsClient) {
		self.base = base
	}

	var calls: [CalendarTouch] { script.withLock { $0.calls } }

	var writes: [CalendarWrite] {
		calls.compactMap { call in
			if case .write(let write) = call { write } else { nil }
		}
	}

	func answer(with hook: @escaping Answer) {
		script.withLock { $0.answer = hook }
	}

	func observe(with hook: @escaping Observer) {
		script.withLock { $0.observe = hook }
	}

	func failReads() {
		script.withLock { $0.readsFail = true }
	}

	func profile() async throws -> AthleteProfile { try await base.profile() }
	func wellness(in range: ReadRange) async throws -> [WellnessDay] {
		try await base.wellness(in: range)
	}
	func activities(in range: ReadRange) async throws -> ActivityListing {
		try await base.activities(in: range)
	}
	func activity(_ id: ActivityID) async throws -> ActivityDetailRead {
		try await base.activity(id)
	}
	func streams(of id: ActivityID, channels: StreamChannels) async throws -> StreamSummary {
		try await base.streams(of: id, channels: channels)
	}

	func fetchEvent(id: EventID) async throws -> CalendarEvent {
		try await reading()
		return try await base.fetchEvent(id: id)
	}

	func listEvents(in range: ReadRange) async throws -> [CalendarEvent] {
		try await reading()
		return try await base.listEvents(in: range)
	}

	func write(_ write: CalendarWrite) async -> IntervalsWriteAnswer {
		let (index, observe, answer) = script.withLock { current in
			current.calls.append(.write(write))
			current.writes += 1
			return (current.writes - 1, current.observe, current.answer)
		}
		await observe?(.write(write))
		if let answered = await answer?(index, write) {
			return answered
		}
		return await base.write(write)
	}

	private func reading() async throws {
		let (fails, observe) = script.withLock { current in
			current.calls.append(.read)
			return (current.readsFail, current.observe)
		}
		await observe?(.read)
		if fails {
			throw IntervalsError.unreachable(URLError(.timedOut))
		}
	}
}

final class BarrierChainLog: ChainForwardingLog {
	let inner: InMemoryRecordLog
	private let barrier = Mutex(Barrier())

	private struct Barrier {
		var waiting = 0
		var arrived = 0
	}

	init(_ inner: InMemoryRecordLog) {
		self.inner = inner
	}

	var chainStore: any ReviewChainLog { inner }
	var deviceId: DeviceID { inner.deviceId }
	var imports: AsyncStream<Void> { inner.imports }

	func arm(readers: Int) {
		barrier.withLock { $0 = Barrier(waiting: readers, arrived: 0) }
	}

	var heldReads: Int { barrier.withLock { $0.arrived } }

	func latest(locality: RecordLocality, writtenBy: DeviceID) async throws -> RecordCursor? {
		try await inner.latest(locality: locality, writtenBy: writtenBy)
	}

	func fetch(_ query: RecordQuery) async throws -> RecordPage {
		try await inner.fetch(query)
	}

	func append(_ batch: [AthleteRecord], locality: RecordLocality) async throws {
		try await inner.append(batch, locality: locality)
	}

	func newest(_ query: RecordQuery) async throws -> AthleteRecord? {
		let newest = try await inner.newest(query)
		let held = barrier.withLock { current -> Int? in
			guard current.waiting > current.arrived else { return nil }
			current.arrived += 1
			return current.waiting
		}
		if let held {
			try await waitUntil { barrier.withLock { $0.arrived >= held } }
		}
		return newest
	}
}

struct DeskRig {
	static let today: CivilDate = "1998-09-08"
	static let kept = EventID(rawValue: 203)

	let clock = FixedClock(now: "1998-09-08T00:30:00+12:00", timeZone: "Pacific/Auckland")
	let base = FakeIntervalsClient(athleteName: "Ada", ftp: 250)
	let calendar: ScriptedCalendar
	let host = ImmediateExecutionHost()
	let store: any ReviewChainLog

	init(store: any ReviewChainLog = InMemoryRecordLog()) {
		self.store = store
		calendar = ScriptedCalendar(base)
		var keptWorkout = PreflightFixture.workout(
			203, on: "1998-09-11", name: "Easy spin", minutes: 45, load: 30)
		keptWorkout.tags = []
		keptWorkout.coachCreated = false
		base.events = [
			PreflightFixture.workout(201, on: "1998-09-10"),
			PreflightFixture.workout(202, on: "1998-09-11", name: "Recovery"),
			keptWorkout,
		]
	}

	func ledger(over log: (any ReviewChainLog)? = nil) -> Ledger {
		Ledger(log: log ?? store, clock: clock, diagnostics: DiagnosticsLog(clock: clock))
	}

	func desk(over log: (any ReviewChainLog)? = nil, athlete: String = "i1001") throws
		-> WorkoutReviewDesk
	{
		let calendar = calendar
		let athlete = try #require(IntervalsAthleteID(rawValue: athlete))
		return WorkoutReviewDesk(
			ledger: ledger(over: log), clock: clock, diagnostics: DiagnosticsLog(clock: clock),
			training: { _ in
				.connected(
					ConnectedTraining(
						connection: PreflightFixture.connection, athlete: athlete, client: calendar)
				)
			}, host: host)
	}

	func event(_ id: Int) throws -> CalendarEvent {
		try #require(base.events.first { $0.id == EventID(rawValue: id) })
	}

	func strength(on date: CivilDate = "1998-09-10") -> ChangeAction {
		.add(
			AddedWorkout(
				payload: CalendarPayload(
					date: date, type: .weightTraining, name: "Strength",
					description: "Squats and core", movingTime: 2700, trainingLoad: 30,
					authoredSteps: nil),
				identity: CalendarWriteID()))
	}

	func mixed() throws -> WorkoutReview {
		try PreflightFixture.review([
			PreflightFixture.ride(on: "1998-09-09", identity: CalendarWriteID()),
			strength(),
			try PreflightFixture.edit(try event(201), PreflightFixture.patch(minutes: 75)),
			try PreflightFixture.delete(try event(202)),
		])
	}

	@discardableResult
	func save(_ review: WorkoutReview) async throws -> RecordHead {
		.record(
			try await ledger().commit(
				review: review,
				stamp: testStamp(operation: .workoutReview(review.id, review.revision)),
				after: .empty
			).ulid)
	}

	func token(on desk: WorkoutReviewDesk) async throws -> ReviewControlToken {
		let shown = try #require(try await desk.snapshot(chat: .main))
		#expect(await desk.decide(.presented(shown.ref)) == .presentationRecorded)
		guard
			case .armed(_, let token) = try #require(try await desk.snapshot(chat: .main))
				.controls
		else {
			throw UnexpectedReview(detail: "the review never armed its controls")
		}
		return token
	}

	func head() async throws -> (RecordHead, WorkoutReview?) {
		try await ledger().reviewHead(chat: .main)
	}

	func chain() async throws -> [WorkoutReview] {
		try await store.fetch(RecordQuery(scope: .deviceLocal([.workoutReview]), chatId: .main))
			.records.compactMap { record in
				guard case .deviceLocal(.workoutReview(let body)) = record.body else { return nil }
				return body.review
			}
	}

	func outcomes() async throws -> [ReviewOutcomeBody] {
		try await store.fetch(RecordQuery(scope: .synced([.reviewOutcome]), chatId: .main))
			.records.compactMap { record in
				guard case .synced(.reviewOutcome(let body)) = record.body else { return nil }
				return body
			}
	}

	static func request(for change: ReviewChange) -> CalendarWrite {
		switch change.action {
		case .add(let add): .create(add.payload, identity: add.identity)
		case .edit(let edit): .update(edit.target.event, edit.patch)
		case .delete(let delete): .delete(delete.target.event)
		}
	}
}

extension WorkoutReview {
	var sendingChange: ChangeID? {
		guard case .running(let run) = stage else { return nil }
		return run.sending?.change.id
	}

	var isClaimOnly: Bool {
		guard case .running(let run) = stage else { return false }
		return run.sending == nil
	}
}

final class SeenHeads: Sendable {
	private let seen = Mutex<[WorkoutReview]>([])

	var all: [WorkoutReview] { seen.withLock { $0 } }

	func record(_ review: WorkoutReview) {
		seen.withLock { $0.append(review) }
	}
}

extension DeskRig {
	func watchHeads(when matches: @escaping @Sendable (CalendarTouch) -> Bool) -> SeenHeads {
		let seen = SeenHeads()
		let reader = ledger()
		calendar.observe { call in
			guard matches(call) else { return }
			do throws(LedgerFailure) {
				guard let review = try await reader.reviewHead(chat: .main).1 else {
					Issue.record("a calendar call ran with no review saved")
					return
				}
				seen.record(review)
			} catch {
				Issue.record(error, "the review head could not be read during a calendar call")
			}
		}
		return seen
	}
}
