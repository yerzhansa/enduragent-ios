import Foundation

package struct IntervalsRESTClient: IntervalsClient, Sendable {
	private let credential: IntervalsCredential
	private let session: URLSession
	private let baseURL: URL
	let athletePath: String
	let clock: any Clock

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

	package func listEvents(oldest: CivilDate, newest: CivilDate) async throws -> [CalendarEvent] {
		_ = try ReadRange(oldest: oldest, newest: newest, today: newest)
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

	func getJSON(path: [String], query: [URLQueryItem] = []) async throws -> JSONValue {
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

	private func send(
		method: String,
		path: [String],
		query: [URLQueryItem] = [],
		body: JSONValue? = nil
	) async throws -> Data {
		try Self.accepted(try await exchange(method: method, path: path, query: query, body: body))
	}

	static func accepted(_ answer: IntervalsAnswer) throws(IntervalsError) -> Data {
		guard (200..<300).contains(answer.status) else {
			throw IntervalsError(
				code: "http", details: "status \(answer.status)", status: answer.status)
		}
		return answer.body
	}

	func exchange(
		method: String,
		path: [String],
		query: [URLQueryItem] = [],
		body: JSONValue? = nil
	) async throws -> IntervalsAnswer {
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
		return IntervalsAnswer(status: http.statusCode, body: data)
	}

	func parseJSON(_ data: Data) throws -> JSONValue {
		guard let text = String(data: data, encoding: .utf8) else {
			throw IntervalsError(code: "invalid_json", details: "response was not UTF-8")
		}
		do {
			return try JSONValue.parse(text)
		} catch {
			throw IntervalsError(code: "invalid_json", details: "response was not JSON")
		}
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

struct IntervalsAnswer: Sendable {
	let status: Int
	let body: Data
}
