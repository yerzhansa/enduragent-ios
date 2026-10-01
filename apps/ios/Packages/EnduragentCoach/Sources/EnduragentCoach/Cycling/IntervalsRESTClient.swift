import Foundation

package struct IntervalsRESTClient: IntervalsClient, Sendable {
	private let credential: IntervalsCredential
	private let session: URLSession
	private let baseURL: URL
	private let athletePath: String
	private let clock: any Clock

	package init(
		credential: IntervalsCredential, athlete: AthleteSelection = .keyOwner,
		session: URLSession? = nil, clock: any Clock = SystemClock(),
		baseURL: URL = IntervalsPolicy.baseURL
	) {
		self.credential = credential
		self.baseURL = baseURL
		switch athlete {
		case .keyOwner:
			self.athletePath = IntervalsPolicy.athletePath
		case .athlete(let id):
			self.athletePath = id.rawValue
		}
		self.clock = clock
		self.session =
			session
			?? ephemeralSession(
				requestTimeout: IntervalsPolicy.requestTimeout,
				resourceTimeout: IntervalsPolicy.requestTimeout)
	}

	package func fetchAthlete() async throws -> AthleteProfile {
		let json = try await getJSON(path: ["athlete", athletePath])
		let fields = json.objectFields
		return AthleteProfile(
			id: fields["id"]?.stringValue ?? athletePath,
			name: fields["name"]?.stringValue ?? "",
			ftp: fields["icu_ftp"]?.intValue() ?? fields["icuFtp"]?.intValue()
		)
	}

	package func fetchWellness(oldest: CivilDate, newest: CivilDate) async throws -> [WellnessDay] {
		try IntervalsPolicy.rejectListRange(oldest: oldest, newest: newest)
		let data = try await get(
			path: ["athlete", athletePath, "wellness"],
			query: [
				URLQueryItem(name: "oldest", value: oldest.rawValue),
				URLQueryItem(name: "newest", value: newest.rawValue),
			]
		)
		let rows = try JSONDecoder().decode([IntervalsWellnessJSON].self, from: data)
		return rows.map(WellnessDay.init(json:))
	}

	package func fetchActivities(oldest: CivilDate, newest: CivilDate) async throws
		-> [ActivitySummary]
	{
		try IntervalsPolicy.rejectListRange(oldest: oldest, newest: newest)
		let json = try await getJSON(
			path: ["athlete", athletePath, "activities"],
			query: [
				URLQueryItem(name: "oldest", value: oldest.rawValue),
				URLQueryItem(name: "newest", value: newest.rawValue),
			]
		)
		return (json.arrayValue ?? []).compactMap(Self.activitySummary(from:))
	}

	package func fetchActivity(id: ActivityID) async throws -> JSONValue {
		try await getJSON(path: ["activity", id.rawValue])
	}

	package func fetchStreams(id: ActivityID) async throws -> JSONValue {
		let json = try await getJSON(
			path: ["activity", id.rawValue, "streams.json"],
			query: [
				URLQueryItem(
					name: "types", value: IntervalsPolicy.defaultStreamTypes.joined(separator: ","))
			]
		)
		return IntervalsStreamSummary.summarize(json)
	}

	package func listEvents(oldest: CivilDate, newest: CivilDate) async throws -> [CalendarEvent] {
		try IntervalsPolicy.rejectListRange(oldest: oldest, newest: newest)
		let query = [
			URLQueryItem(name: "oldest", value: oldest.rawValue),
			URLQueryItem(name: "newest", value: newest.rawValue),
		]
		let json = try await getJSON(path: ["athlete", athletePath, "events"], query: query)
		guard let rows = json.arrayValue else {
			throw IntervalsError(
				code: "invalid_json", details: "calendar response was not an array")
		}
		return try rows.map(Self.calendarEvent(from:))
	}

	package func createChatEvent(_ draft: ChatCalendarCreate) async throws -> CalendarEvent {
		guard draft.writeID != nil else {
			throw IntervalsError(
				code: "missing_write_identity",
				details: "Calendar approval needs a durable identity")
		}
		let json = try await sendJSON(
			method: "POST",
			path: ["athlete", athletePath, "events"],
			query: [URLQueryItem(name: "upsertOnUid", value: "true")],
			body: IntervalsPolicy.chatCreateBody(draft)
		)
		let event = try Self.calendarEvent(from: json)
		guard event.uid == draft.writeID?.uid, draft.matches(event) else {
			throw IntervalsError(
				code: "invalid_json", details: "Created event does not match the approval")
		}
		return event
	}

	package func updateEvent(id: EventID, name: String?, description: String?, date: CivilDate?)
		async throws -> CalendarEvent
	{
		let existing = try await fetchEvent(id: id)
		let today = IntervalsPolicy.today(now: clock.now, timeZone: clock.timeZone)
		try IntervalsPolicy.refuseMutableEvent(
			existing,
			today: today,
			eventId: id,
			action: "update",
			nextDate: date
		)
		var fields: [String: JSONValue] = [:]
		if let name {
			fields["name"] = .string(name)
		}
		if let description {
			fields["description"] = .string(description)
		}
		if let date {
			fields["start_date_local"] = .string("\(date.rawValue)T00:00:00")
		}
		let json = try await sendJSON(
			method: "PUT",
			path: ["athlete", athletePath, "events", String(id.rawValue)],
			body: .object(fields)
		)
		let event = try Self.calendarEvent(from: json)
		guard event.id == id, name.map({ $0 == event.name }) ?? true,
			description.map({ $0 == event.description }) ?? true,
			date.map({ "\($0.rawValue)T00:00:00" == event.startDateLocal }) ?? true
		else {
			throw IntervalsError(
				code: "invalid_json", details: "Updated event does not match the approval")
		}
		return event
	}

	package func deleteEvent(id: EventID) async throws {
		let existing = try await fetchEvent(id: id)
		let today = IntervalsPolicy.today(now: clock.now, timeZone: clock.timeZone)
		try IntervalsPolicy.refuseMutableEvent(
			existing,
			today: today,
			eventId: id,
			action: "delete",
			nextDate: nil
		)
		_ = try await send(
			method: "DELETE",
			path: ["athlete", athletePath, "events", String(id.rawValue)]
		)
	}

	private var authorization: String {
		switch credential {
		case .apiKey(let key):
			let encoded = Data("API_KEY:\(key)".utf8).base64EncodedString()
			return "Basic \(encoded)"
		case .oauth(let access, _):
			return "Bearer \(access)"
		}
	}

	package func fetchEvent(id: EventID) async throws -> CalendarEvent {
		let json = try await getJSON(path: ["athlete", athletePath, "events", String(id.rawValue)])
		return try Self.calendarEvent(from: json)
	}

	private func getJSON(path: [String], query: [URLQueryItem] = []) async throws -> JSONValue {
		try parseJSON(try await send(method: "GET", path: path, query: query))
	}

	private func sendJSON(
		method: String,
		path: [String],
		query: [URLQueryItem] = [],
		body: JSONValue
	) async throws -> JSONValue {
		try parseJSON(try await send(method: method, path: path, query: query, body: body))
	}

	private func get(path: [String], query: [URLQueryItem] = []) async throws -> Data {
		try await send(method: "GET", path: path, query: query)
	}

	private func send(
		method: String,
		path: [String],
		query: [URLQueryItem] = [],
		body: JSONValue? = nil
	) async throws -> Data {
		var url = baseURL
		for component in path {
			url.append(path: component)
		}
		guard var components = URLComponents(url: url, resolvingAgainstBaseURL: false) else {
			throw IntervalsError(code: "invalid_url", details: path.joined(separator: "/"))
		}
		if !query.isEmpty {
			components.queryItems = query
		}
		guard let finalURL = components.url else {
			throw IntervalsError(code: "invalid_url", details: path.joined(separator: "/"))
		}
		var request = URLRequest(url: finalURL)
		request.httpMethod = method
		request.setValue(authorization, forHTTPHeaderField: "Authorization")
		request.setValue("application/json", forHTTPHeaderField: "Accept")
		request.timeoutInterval = IntervalsPolicy.requestTimeout
		if let body {
			request.setValue("application/json", forHTTPHeaderField: "Content-Type")
			request.httpBody = Data(body.canonicalDigestInput().utf8)
		}
		let (data, response) = try await session.data(for: request)
		guard let http = response as? HTTPURLResponse else {
			throw IntervalsError(code: "network", details: "missing http response")
		}
		guard (200..<300).contains(http.statusCode) else {
			throw IntervalsError(
				code: "http", details: "status \(http.statusCode)", status: http.statusCode)
		}
		return data
	}

	private func parseJSON(_ data: Data) throws -> JSONValue {
		guard let text = String(data: data, encoding: .utf8) else {
			throw IntervalsError(code: "invalid_json", details: "response was not UTF-8")
		}
		do {
			return try JSONValue.parse(text)
		} catch {
			throw IntervalsError(code: "invalid_json", details: "response was not JSON")
		}
	}

	private static func activitySummary(from json: JSONValue) -> ActivitySummary? {
		let fields = json.objectFields
		guard let name = fields["name"]?.stringValue else { return nil }
		let local = fields["start_date_local"]?.stringValue ?? fields["startDateLocal"]?.stringValue
		guard let local, let date = CivilDate(rawValue: String(local.prefix(10))) else {
			return nil
		}
		let duration = fields["moving_time"]?.intValue() ?? fields["movingTime"]?.intValue() ?? 0
		let load = fields["icu_training_load"]?.intValue() ?? fields["icuTrainingLoad"]?.intValue()
		return ActivitySummary(name: name, date: date, durationS: duration, trainingLoad: load)
	}

	private static func calendarEvent(from json: JSONValue) throws -> CalendarEvent {
		let data = Data(json.canonicalDigestInput().utf8)
		let payload = try JSONDecoder().decode(CalendarEventPayload.self, from: data)
		guard CivilDate(rawValue: String(payload.start.prefix(10))) != nil else {
			throw IntervalsError(
				code: "invalid_json", details: "calendar event has an invalid date")
		}
		return CalendarEvent(
			description: payload.description, type: payload.type,
			id: EventID(rawValue: payload.id), startDateLocal: payload.start,
			name: payload.name, category: payload.category,
			externalId: payload.externalID, uid: payload.uid, tags: payload.tags ?? [],
			coachCreated: IntervalsPolicy.isCoachOwned(
				externalId: payload.externalID, tags: payload.tags ?? []))
	}

}

package enum IntervalsStreamSummary {
	package static func summarize(_ raw: JSONValue) -> JSONValue {
		var channels: [String: JSONValue] = [:]
		var sampleCount = 0
		for (name, values) in channelArrays(raw) {
			guard let summary = summarizeChannel(values) else { continue }
			channels[name] = summary
			if values.count > sampleCount {
				sampleCount = values.count
			}
		}
		return .object([
			"sampleCount": .number(Double(sampleCount)),
			"channels": .object(channels),
		])
	}

	private static func channelArrays(_ raw: JSONValue) -> [(String, [JSONValue])] {
		if let items = raw.arrayValue {
			var out: [(String, [JSONValue])] = []
			for element in items {
				let fields = element.objectFields
				guard let type = fields["type"]?.stringValue, let data = fields["data"]?.arrayValue
				else {
					continue
				}
				out.append((type, data))
			}
			return out
		}
		if case .object(let object) = raw {
			return object.compactMap { key, value in
				guard let data = value.arrayValue else { return nil }
				return (key, data)
			}
		}
		return []
	}

	private static func summarizeChannel(_ values: [JSONValue]) -> JSONValue? {
		var min = Double.infinity
		var max = -Double.infinity
		var sum = 0.0
		var count = 0
		for value in values {
			guard let number = value.numberValue, number.isFinite else { continue }
			if number < min { min = number }
			if number > max { max = number }
			sum += number
			count += 1
		}
		guard count > 0 else { return nil }
		let mean = (sum / Double(count) * 10).rounded() / 10
		return .object([
			"min": .number(min),
			"max": .number(max),
			"mean": .number(mean),
		])
	}
}
