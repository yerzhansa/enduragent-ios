import Foundation

public enum ScriptedEvent: Sendable, Equatable {
	case text(String)
	case toolCall(name: String, arguments: String)
	case finish(reason: FinishReason)
	case fail(ScriptedFailure)
	case hang
}

public struct ScriptedFailure: Sendable, Equatable {
	package let failure: ProviderFailure

	package init(_ failure: ProviderFailure) {
		self.failure = failure
	}

	public static func http(status: Int, headers: [String: String] = [:], body: String = "")
		-> ScriptedFailure
	{
		ScriptedFailure(ProviderFailure(status: status, headers: headers, body: body))
	}

	public static func connection(_ code: URLError.Code) -> ScriptedFailure {
		ScriptedFailure(ProviderFailure(URLError(code)))
	}

	public static let unknownFinish = ScriptedFailure(.unknownFinish)
}

public final class FakeModelTransport: ModelTransport, @unchecked Sendable {
	public var script: [ScriptedEvent]
	public var maintenanceScript: [ScriptedEvent]
	package private(set) var requests: [CompletionRequest]
	public var hangUntilCancelled = false
	package var finishUsage = Usage(inputTokens: 0, outputTokens: 0, cost: nil)
	public var requestDelay: Duration?
	public var deltaDelay: Duration?
	private let lock = NSLock()

	public init() {
		self.script = []
		self.maintenanceScript = []
		self.requests = []
	}

	public var requestCount: Int {
		requests.count
	}

	package func stream(_ request: CompletionRequest) -> AsyncThrowingStream<TransportEvent, Error>
	{
		if hangUntilCancelled {
			return AsyncThrowingStream { continuation in
				let task = Task {
					do {
						try await Self.hang()
						continuation.finish()
					} catch is CancellationError {
						continuation.finish()
					} catch {
						continuation.finish(throwing: error)
					}
				}
				continuation.onTermination = { _ in
					task.cancel()
				}
			}
		}
		let batch: ScriptedBatch
		do {
			batch = try nextBatch(for: request)
		} catch {
			return AsyncThrowingStream { continuation in
				continuation.finish(throwing: error)
			}
		}
		let delay = requestDelay
		let pause = deltaDelay
		return AsyncThrowingStream { continuation in
			let task = Task {
				do {
					if let delay {
						try await Task.sleep(for: delay)
					}
					for event in batch.events {
						if let pause {
							try await Task.sleep(for: pause)
						}
						continuation.yield(event)
					}
					switch batch.end {
					case .finished:
						continuation.finish()
					case .failed(let failure):
						continuation.finish(throwing: failure)
					case .hanging:
						try await Self.hang()
						continuation.finish()
					}
				} catch is CancellationError {
					continuation.finish()
				} catch {
					continuation.finish(throwing: error)
				}
			}
			continuation.onTermination = { _ in
				task.cancel()
			}
		}
	}

	private static func hang() async throws {
		while !Task.isCancelled {
			try await Task.sleep(for: .seconds(60))
		}
	}

	private func nextBatch(for request: CompletionRequest) throws -> ScriptedBatch {
		lock.lock()
		defer { lock.unlock() }
		requests.append(request)
		var events: [TransportEvent] = []
		while let event = takeEvent(for: request.charge) {
			switch event {
			case .text(let text):
				events.append(.textDelta(text))
			case .toolCall(let name, let arguments):
				guard let toolName = ToolName(rawValue: name) else {
					throw ProviderFailure.malformedStream
				}
				events.append(
					.toolCall(
						WireToolCall(
							id: UUID().uuidString,
							name: toolName,
							arguments: arguments
						)
					)
				)
			case .finish(let reason):
				events.append(.finished(reason: reason, usage: finishUsage))
				return ScriptedBatch(events: events, end: .finished)
			case .fail(let scripted):
				return ScriptedBatch(events: events, end: .failed(scripted.failure))
			case .hang:
				return ScriptedBatch(events: events, end: .hanging)
			}
		}
		return ScriptedBatch(events: events, end: .finished)
	}

	private func takeEvent(for charge: GenerateCharge) -> ScriptedEvent? {
		switch charge {
		case .chatAttempt, .stepRecovery:
			return script.isEmpty ? nil : script.removeFirst()
		case .compaction, .memoryFlush:
			return maintenanceScript.isEmpty ? nil : maintenanceScript.removeFirst()
		}
	}
}

private struct ScriptedBatch: Sendable {
	let events: [TransportEvent]
	let end: End

	enum End: Sendable {
		case finished
		case failed(ProviderFailure)
		case hanging
	}
}

public enum FakeIntervalsCall: Sendable, Equatable {
	case activities(days: Int)
	case wellness(oldest: CivilDate, newest: CivilDate)
	case activity(ActivityID)
	case streams(ActivityID)
	case events(oldest: CivilDate, newest: CivilDate)
	case createEvent(date: CivilDate, externalId: String)
	case updateEvent(EventID)
	case deleteEvent(EventID)
}

public final class FakeIntervalsClient: IntervalsClient, @unchecked Sendable {
	public var activities: [ActivitySummary]
	public var wellness: [WellnessDay]
	public var activity: JSONValue
	public var streams: JSONValue
	public var events: [CalendarEvent]
	public private(set) var calls: [FakeIntervalsCall]
	public var athleteName: String
	public var ftp: Int
	public var loadFailure: IntervalsError?

	public init(athleteName: String, ftp: Int) {
		self.athleteName = athleteName
		self.ftp = ftp
		self.activities = []
		self.wellness = []
		self.activity = .object([:])
		self.streams = .object([
			"sampleCount": .number(0),
			"channels": .object([:]),
		])
		self.events = []
		self.calls = []
		self.loadFailure = nil
	}

	public func fetchAthlete() async throws -> AthleteProfile {
		if let loadFailure {
			throw loadFailure
		}
		return AthleteProfile(id: "0", name: athleteName, ftp: ftp)
	}

	public func fetchWellness(oldest: CivilDate, newest: CivilDate) async throws -> [WellnessDay] {
		if let loadFailure {
			throw loadFailure
		}
		calls.append(.wellness(oldest: oldest, newest: newest))
		return wellness.filter { $0.date >= oldest && $0.date <= newest }
	}

	public func fetchActivities(oldest: CivilDate, newest: CivilDate) async throws
		-> [ActivitySummary]
	{
		let days = IntervalsPolicy.inclusiveDayCount(from: oldest, to: newest)
		calls.append(.activities(days: days))
		return activities.filter { $0.date >= oldest && $0.date <= newest }
	}

	public func fetchActivity(id: ActivityID) async throws -> JSONValue {
		calls.append(.activity(id))
		return activity
	}

	public func fetchStreams(id: ActivityID) async throws -> JSONValue {
		calls.append(.streams(id))
		return streams
	}

	public func listEvents(oldest: CivilDate, newest: CivilDate) async throws -> [CalendarEvent] {
		calls.append(.events(oldest: oldest, newest: newest))
		return events.filter { event in
			guard let date = CivilDate(rawValue: String(event.startDateLocal.prefix(10))) else {
				return false
			}
			return date >= oldest && date <= newest
		}
	}

	public func createChatEvent(_ draft: ChatCalendarCreate) async throws -> CalendarEvent {
		calls.append(.createEvent(date: draft.date, externalId: draft.externalId.rawValue))
		return CalendarEvent(
			id: EventID(rawValue: 1),
			startDateLocal: "\(draft.date.rawValue)T00:00:00",
			name: draft.name,
			category: "WORKOUT",
			externalId: draft.externalId.rawValue,
			uid: nil,
			tags: draft.tags,
			coachCreated: true
		)
	}

	public func createOrUpdatePlanEvent(_ draft: PlanMirrorCreate) async throws -> CalendarEvent {
		_ = draft
		throw IntervalsError(
			code: "not_implemented", details: "Plan mirror writes are not available.")
	}

	public func updateEvent(id: EventID, name: String?, description: String?, date: CivilDate?)
		async throws -> CalendarEvent
	{
		calls.append(.updateEvent(id))
		return CalendarEvent(
			id: id,
			startDateLocal: "\(date?.rawValue ?? "1998-06-14")T00:00:00",
			name: name ?? "",
			category: "WORKOUT",
			externalId: nil,
			uid: nil,
			tags: [IntervalsPolicy.coachTag],
			coachCreated: true
		)
	}

	public func deleteEvent(id: EventID) async throws {
		calls.append(.deleteEvent(id))
	}
}
