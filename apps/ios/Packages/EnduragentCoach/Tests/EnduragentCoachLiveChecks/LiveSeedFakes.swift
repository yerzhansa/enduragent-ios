import EnduragentCoachFixtures
import Foundation
import Synchronization

@testable import EnduragentCoach

actor FakeSeedAccount: SeedAccount {
	nonisolated let calendar: any IntervalsClient
	nonisolated let seedCalendar: FakeSeedCalendar
	private(set) var listed: [SeedListing]
	private(set) var days: [CivilDate: [String: Double]]
	private(set) var uploads: [String] = []
	private(set) var lookups: [String] = []
	private(set) var deleted: [String] = []
	private(set) var ratings: [String] = []
	private(set) var wellnessWrites: [[CivilDate: [String: Double?]]] = []
	private var listedFromSecondRead: [SeedListing]
	private let athlete: String
	private let processes: Bool
	private let nullClears: Bool

	init(
		athlete: String = "i1001", listed: [SeedListing] = [],
		listedFromSecondRead: [SeedListing] = [], days: [CivilDate: [String: Double]] = [:],
		processes: Bool = true, nullClears: Bool = true,
		calendar: FakeSeedCalendar = FakeSeedCalendar()
	) {
		self.calendar = calendar
		self.seedCalendar = calendar
		self.athlete = athlete
		self.listed = listed
		self.listedFromSecondRead = listedFromSecondRead
		self.days = days
		self.processes = processes
		self.nullClears = nullClears
	}

	func athleteID() -> String { athlete }

	func addCalendarEntries(_ bodies: [JSONValue]) -> [CalendarEvent] {
		seedCalendar.add(bodies)
	}

	func activities(oldest: CivilDate, newest: CivilDate) -> [SeedListing] {
		defer {
			listed += listedFromSecondRead
			listedFromSecondRead = []
		}
		return listed
	}

	func wellness(oldest: CivilDate, newest: CivilDate) -> [CivilDate: [String: Double]] { days }

	func upload(_ activity: SeedActivity, file: Data) -> String {
		let id = "i\(900 + uploads.count)"
		uploads.append(activity.externalID)
		listed.append(
			SeedListing(
				id: id, name: activity.name, externalID: activity.externalID,
				start: activity.start.date.rawValue, load: processes ? 50 : nil))
		return id
	}

	func activityExists(_ id: String) -> Bool {
		lookups.append(id)
		return (listed + listedFromSecondRead).contains { $0.id == id }
	}

	func rate(_ id: String, feel: Int, rpe: Int) {
		ratings.append(id)
		listed = listed.map { row in
			guard row.id == id else { return row }
			var rated = row
			rated.feel = feel
			rated.rpe = rpe
			return rated
		}
	}

	func delete(_ id: String) {
		deleted.append(id)
		listed.removeAll { $0.id == id }
	}

	func writeWellness(_ written: [CivilDate: [String: Double?]]) {
		wellnessWrites.append(written)
		for (date, values) in written {
			for (field, value) in values where value != nil || nullClears {
				days[date, default: [:]][field] = value
			}
		}
	}
}

final class TCXReading: NSObject, XMLParserDelegate {
	struct Point {
		var time = ""
		var distance = 0.0
		var heartRate: Double?
		var cadence: Double?
		var watts: Double?
	}

	struct Lap {
		var seconds = 0.0
		var distance = 0.0
		var averageWatts: Double?
		var points: [Point] = []
	}

	private(set) var sport = ""
	private(set) var id = ""
	private(set) var laps: [Lap] = []
	private var path: [String] = []
	private var text = ""

	static func read(_ document: String) throws -> TCXReading {
		let reading = TCXReading()
		let parser = XMLParser(data: Data(document.utf8))
		parser.delegate = reading
		guard parser.parse() else {
			throw LiveCheckStop(
				description: "The TCX did not parse: \(String(describing: parser.parserError))")
		}
		return reading
	}

	func parser(
		_ parser: XMLParser, didStartElement elementName: String, namespaceURI: String?,
		qualifiedName: String?, attributes: [String: String] = [:]
	) {
		path.append(elementName)
		text = ""
		switch elementName {
		case "Activity": sport = attributes["Sport"] ?? ""
		case "Lap": laps.append(Lap())
		case "Trackpoint": laps[laps.count - 1].points.append(Point())
		default: break
		}
	}

	func parser(_ parser: XMLParser, foundCharacters string: String) {
		text += string
	}

	func parser(
		_ parser: XMLParser, didEndElement elementName: String, namespaceURI: String?,
		qualifiedName: String?
	) {
		let parent = path.dropLast().last ?? ""
		let number = Double(text.trimmingCharacters(in: .whitespacesAndNewlines))
		let lap = laps.count - 1
		let point = lap >= 0 ? laps[lap].points.count - 1 : -1
		switch (parent, elementName) {
		case ("Activity", "Id"): id = text
		case ("Lap", "TotalTimeSeconds"): laps[lap].seconds = number ?? -1
		case ("Lap", "DistanceMeters"): laps[lap].distance = number ?? -1
		case ("ns3:LX", "ns3:AvgWatts"): laps[lap].averageWatts = number
		case ("Trackpoint", "Time"): laps[lap].points[point].time = text
		case ("Trackpoint", "DistanceMeters"): laps[lap].points[point].distance = number ?? -1
		case ("Trackpoint", "Cadence"): laps[lap].points[point].cadence = number
		case ("HeartRateBpm", "Value") where path.dropLast(2).last == "Trackpoint":
			laps[lap].points[point].heartRate = number
		case ("ns3:TPX", "ns3:Watts"): laps[lap].points[point].watts = number
		default: break
		}
		path.removeLast()
	}
}

func temporarySeedLedger() throws -> LiveSeedLedger {
	try LiveSeedLedger(file: TestTemporaryFolders.make().appending(path: "ledger.tsv"))
}

func instantPolling(attempts: Int = 3, slept: SleepCount = SleepCount()) -> SeedPolling {
	SeedPolling(attempts: attempts, interval: .seconds(5), sleep: { _ in await slept.add() })
}

actor SleepCount {
	private(set) var count = 0

	func add() {
		count += 1
	}
}

final class FakeSeedCalendar: IntervalsClient, @unchecked Sendable {
	enum Call: Equatable {
		case list(ReadRange)
		case fetch(EventID)
		case add([String])
		case write(CalendarWrite)
	}

	enum WriteKind: Sendable {
		case create, update, delete

		init(_ write: CalendarWrite) {
			switch write {
			case .create: self = .create
			case .update: self = .update
			case .delete: self = .delete
			}
		}
	}

	private let state = Mutex(State())
	private let stores: @Sendable (Set<String>, CalendarEvent) -> CalendarEvent

	private struct State {
		var events: [CalendarEvent] = []
		var calls: [Call] = []
		var drained = 0
		var nextID = 7_000
		var dropsNextAnswer = false
	}

	private let upsertsByExternalID: Bool
	private let ignoresNameEdits: Bool
	private let savesMissingEvents: Bool
	private let losesDroppedWrite: WriteKind?

	init(
		events: [CalendarEvent] = [], upsertsByExternalID: Bool = true,
		ignoresNameEdits: Bool = false, savesMissingEvents: Bool = false,
		losesDroppedWrite: WriteKind? = nil,
		stores: @escaping @Sendable (Set<String>, CalendarEvent) -> CalendarEvent = { $1 }
	) {
		self.upsertsByExternalID = upsertsByExternalID
		self.ignoresNameEdits = ignoresNameEdits
		self.savesMissingEvents = savesMissingEvents
		self.losesDroppedWrite = losesDroppedWrite
		self.stores = stores
		state.withLock { $0.events = events }
	}

	var events: [CalendarEvent] { state.withLock { $0.events } }
	var calls: [Call] { state.withLock { $0.calls } }
	var writes: [CalendarWrite] {
		calls.compactMap { call in
			guard case .write(let write) = call else { return nil }
			return write
		}
	}

	func fetchEvent(id: EventID) throws -> CalendarEvent {
		try state.withLock { state in
			state.calls.append(.fetch(id))
			guard let event = state.events.first(where: { $0.id == id }) else {
				throw IntervalsError(code: "http", details: "status 404", status: 404)
			}
			return event
		}
	}

	func listEvents(in range: ReadRange) -> [CalendarEvent] {
		state.withLock { state in
			state.calls.append(.list(range))
			return state.events.filter { event in
				CivilDate(rawValue: String(event.startDateLocal.prefix(10))).map(range.contains)
					?? false
			}
		}
	}

	func add(_ bodies: [JSONValue]) -> [CalendarEvent] {
		state.withLock { state in
			state.calls.append(
				.add(bodies.map { $0.objectFields["external_id"]?.stringValue ?? "" }))
			return bodies.map {
				Self.upsert($0.objectFields, into: &state, matching: true, stores: stores)
			}
		}
	}

	func dropNextAnswer() {
		state.withLock { $0.dropsNextAnswer = true }
	}

	func drainRequests() -> [TappedResponse] {
		state.withLock { state in
			defer { state.drained = state.calls.count }
			return state.calls.dropFirst(state.drained).map(Self.request)
		}
	}

	func write(_ write: CalendarWrite) -> IntervalsWriteAnswer {
		state.withLock { state in
			state.calls.append(.write(write))
			guard state.dropsNextAnswer else { return apply(write, to: &state) }
			state.dropsNextAnswer = false
			if losesDroppedWrite != WriteKind(write) {
				_ = apply(write, to: &state)
			}
			return .lost(.transport)
		}
	}

	private func apply(_ write: CalendarWrite, to state: inout State) -> IntervalsWriteAnswer {
		switch write {
		case .create(let payload, let identity):
			return .saved(
				Self.upsert(
					payload.requestBody(identity).objectFields, into: &state,
					matching: upsertsByExternalID, stores: stores))
		case .update(let id, let patch):
			guard let index = state.events.firstIndex(where: { $0.id == id }) else {
				return missing
			}
			var event = state.events[index]
			if let date = patch.date { event.startDateLocal = "\(date.rawValue)T00:00:00" }
			if let name = patch.name, !ignoresNameEdits { event.name = name }
			if let seconds = patch.durationSeconds { event.movingTime = seconds }
			if let description = patch.description { event.description = description }
			if let load = patch.trainingLoad { event.trainingLoad = load }
			if let document = patch.workoutDocument { event.workoutDocument = document }
			event = stores(Set(patch.requestBody.objectFields.keys), event)
			state.events[index] = event
			return .saved(event)
		case .delete(let id):
			guard state.events.contains(where: { $0.id == id }) else { return missing }
			state.events.removeAll { $0.id == id }
			return .saved(nil)
		}
	}

	private static func request(_ call: Call) -> TappedResponse {
		let events = "/api/v1/athlete/0/events"
		let bulk = "upsert=true&upsertOnUid=false&updatePlanApplied=false"
		let (method, path, query): (String, String, String?) =
			switch call {
			case .list(let range):
				("GET", events, "oldest=\(range.oldest.rawValue)&newest=\(range.newest.rawValue)")
			case .fetch(let id): ("GET", "\(events)/\(id.rawValue)", nil)
			case .add, .write(.create): ("POST", "\(events)/bulk", bulk)
			case .write(.update(let id, _)): ("PUT", "\(events)/\(id.rawValue)", nil)
			case .write(.delete(let id)): ("DELETE", "\(events)/\(id.rawValue)", nil)
			}
		return TappedResponse(method: method, path: path, query: query, status: 200, body: Data())
	}

	private var missing: IntervalsWriteAnswer {
		savesMissingEvents ? .saved(nil) : .httpStatus(404)
	}

	private static func upsert(
		_ fields: [String: JSONValue], into state: inout State, matching: Bool,
		stores: (Set<String>, CalendarEvent) -> CalendarEvent
	) -> CalendarEvent {
		let externalID = fields["external_id"]?.stringValue
		let tags = (fields["tags"]?.arrayValue ?? []).compactMap(\.stringValue)
		let previous =
			matching
			? state.events.firstIndex { $0.externalId != nil && $0.externalId == externalID } : nil
		let id = previous.map { state.events[$0].id } ?? EventID(rawValue: state.nextID)
		if previous == nil { state.nextID += 1 }
		let event = stores(
			Set(fields.keys),
			CalendarEvent(
				description: fields["description"]?.stringValue, type: fields["type"]?.stringValue,
				id: id, startDateLocal: fields["start_date_local"]?.stringValue ?? "",
				name: fields["name"]?.stringValue, category: fields["category"]?.stringValue ?? "",
				externalId: externalID, uid: "server-\(id.rawValue)", tags: tags,
				coachCreated: IntervalsPolicy.isCoachOwned(externalId: externalID, tags: tags),
				movingTime: fields["moving_time"]?.numberValue.map { Int($0) },
				trainingLoad: fields["icu_training_load"]?.numberValue.map { Int($0) }))
		if let previous {
			state.events[previous] = event
		} else {
			state.events.append(event)
		}
		return event
	}
}
