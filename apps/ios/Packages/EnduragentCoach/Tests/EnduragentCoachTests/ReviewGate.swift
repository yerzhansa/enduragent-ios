import EnduragentCoachFixtures
import Foundation
import Testing

@testable import EnduragentCoach

extension SingleProposalReviewsTests {
	func gatedCoach(log: any RecordLog, client: any TrainingClient) async -> Coach {
		await consentingCoach(
			Coach(
				sport: .cycling,
				ports: CoachPorts(
					records: RecordStore(log: log), secrets: secrets, models: .scripted(transport),
					training: TrainingService { _, _, _ in client },
					credits: .fake(FakeCreditsClient()), host: ImmediateExecutionHost(),
					clock: clock),
				builtInModel: testModel, displayLocale: testDisplayLocale, coalescing: quickWindow))
	}
}

actor ReviewGate {
	private let waitLimit: TestWaitLimit
	private var armed = false
	private var gate = Gate()

	init(within waitLimit: TestWaitLimit = .hangGuard) {
		self.waitLimit = waitLimit
	}

	func arm() {
		armed = true
		gate = Gate()
	}
	func pass() async throws {
		guard armed else { return }
		armed = false
		let gate = gate
		let released: Void? = try await beforeDeadline(within: waitLimit) {
			try await gate.waitUnlessCancelled()
		}
		guard released != nil else { throw TestWaitDeadlineExceeded() }
	}
	func release() { gate.release() }
	func waitUntilEntered() async throws -> Bool {
		let gate = gate
		return try await beforeDeadline(within: waitLimit) {
			await gate.waitUntilParked()
		} != nil
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
			try await readGate?.pass()
		}
		return page
	}
	func append(_ batch: [AthleteRecord], locality: RecordLocality) async throws {
		if batch.contains(where: {
			if case .synced(.reviewWrite(let body)) = $0.body {
				return body.evidence == .unknown(.dispatched)
			}
			return false
		}) {
			try await gate.pass()
		}
		try await inner.append(batch, locality: locality)
	}
}

struct GatedReviewIntervals: TrainingClient {
	let base: FakeIntervalsClient
	let gate: ReviewGate
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
	func fetchEvent(id: EventID) async throws -> CalendarEvent { try await base.fetchEvent(id: id) }
	func listEvents(oldest: CivilDate, newest: CivilDate) async throws -> [CalendarEvent] {
		try await base.listEvents(oldest: oldest, newest: newest)
	}
	func createChatEvent(_ draft: ChatCalendarCreate) async throws -> CalendarEvent {
		try await gate.pass()
		return try await base.createChatEvent(draft)
	}
	func updateEvent(id: EventID, name: String?, description: String?, date: CivilDate?)
		async throws -> CalendarEvent
	{ try await base.updateEvent(id: id, name: name, description: description, date: date) }
	func deleteEvent(id: EventID) async throws { try await base.deleteEvent(id: id) }
}
