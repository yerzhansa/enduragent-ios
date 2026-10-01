import EnduragentCoachFixtures
import Foundation
import Testing

@testable import EnduragentCoach

extension SingleProposalReviewsTests {
	func gatedCoach(log: any RecordLog, client: any IntervalsClient) async -> Coach {
		await consentingCoach(
			Coach(
				sport: .cycling,
				ports: CoachPorts(
					records: RecordStore(log: log), secrets: secrets, models: .scripted(transport),
					training: TrainingService { _, _, _ in client },
					credits: .fake(FakeCreditsClient()), host: ImmediateExecutionHost(),
					clock: clock),
				builtInModel: testModel, deviceLanguage: .en, coalescing: quickWindow))
	}
}

actor ReviewGate {
	private var armed = false
	private var entered = false
	private var waiters: [CheckedContinuation<Void, Never>] = []

	func arm() { armed = true }
	func pass() async {
		guard armed else { return }
		armed = false
		entered = true
		await withCheckedContinuation { waiters.append($0) }
	}
	func release() {
		for waiter in waiters { waiter.resume() }
		waiters = []
	}
	func waitUntilEntered() async -> Bool {
		let deadline = ContinuousClock.now + .seconds(5)
		while !entered, ContinuousClock.now < deadline {
			do { try await Task.sleep(for: .milliseconds(5)) } catch {
				Issue.record(error)
				return false
			}
		}
		return entered
	}
}

struct GatedReviewLog: RecordLog {
	let inner: InMemoryRecordLog
	let gate: ReviewGate
	var readGate: ReviewGate?
	var deviceId: DeviceID { inner.deviceId }
	var imports: AsyncStream<Void> { inner.imports }
	func latest(locality: RecordLocality, writtenBy: DeviceID) async throws -> RecordCursor? {
		try await inner.latest(locality: locality, writtenBy: writtenBy)
	}

	func fetch(_ query: RecordQuery) async throws -> RecordPage {
		let page = try await inner.fetch(query)
		if query.scope == .deviceLocal([.pendingProposal, .proposalCleared]) {
			await readGate?.pass()
		}
		return page
	}
	func append(_ batch: [AthleteRecord], locality: RecordLocality) async throws {
		if batch.contains(where: {
			if case .deviceLocal(.proposalCleared(let body)) = $0.body {
				return body.reason == .executed
			}
			return false
		}) {
			await gate.pass()
		}
		try await inner.append(batch, locality: locality)
	}
}

struct GatedReviewIntervals: IntervalsClient {
	let base: FakeIntervalsClient
	let gate: ReviewGate
	func fetchAthlete() async throws -> AthleteProfile { try await base.fetchAthlete() }
	func fetchWellness(oldest: CivilDate, newest: CivilDate) async throws -> [WellnessDay] {
		try await base.fetchWellness(oldest: oldest, newest: newest)
	}
	func fetchActivities(oldest: CivilDate, newest: CivilDate) async throws -> [ActivitySummary] {
		try await base.fetchActivities(oldest: oldest, newest: newest)
	}
	func fetchActivity(id: ActivityID) async throws -> JSONValue {
		try await base.fetchActivity(id: id)
	}
	func fetchStreams(id: ActivityID) async throws -> JSONValue {
		try await base.fetchStreams(id: id)
	}
	func listEvents(oldest: CivilDate, newest: CivilDate) async throws -> [CalendarEvent] {
		try await base.listEvents(oldest: oldest, newest: newest)
	}
	func createChatEvent(_ draft: ChatCalendarCreate) async throws -> CalendarEvent {
		await gate.pass()
		return try await base.createChatEvent(draft)
	}
	func updateEvent(id: EventID, name: String?, description: String?, date: CivilDate?)
		async throws -> CalendarEvent
	{ try await base.updateEvent(id: id, name: name, description: description, date: date) }
	func deleteEvent(id: EventID) async throws { try await base.deleteEvent(id: id) }
}
