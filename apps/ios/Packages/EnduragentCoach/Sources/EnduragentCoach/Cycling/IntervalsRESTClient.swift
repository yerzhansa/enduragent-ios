import Foundation

package struct IntervalsRESTClient: IntervalsClient, Sendable {
	private let credential: IntervalsCredential
	private let session: URLSession
	private let baseURL: URL
	let athletePath: String

	package init(
		credential: IntervalsCredential, athlete: AthleteSelection = .keyOwner,
		session: URLSession? = nil,
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
		self.session =
			session
			?? ephemeralSession(
				requestTimeout: IntervalsPolicy.requestTimeout,
				resourceTimeout: IntervalsPolicy.requestTimeout)
	}

	package func listEvents(in range: ReadRange) async throws -> [CalendarEvent] {
		let query = [
			URLQueryItem(name: "oldest", value: range.oldest.rawValue),
			URLQueryItem(name: "newest", value: range.newest.rawValue),
		]
		let json = try await getJSON(path: ["athlete", athletePath, "events"], query: query)
		guard let rows = json.arrayValue else {
			throw IntervalsError(
				code: "invalid_json", details: "calendar response was not an array")
		}
		return try rows.map(Self.calendarEvent(from:))
	}

	package func write(_ write: CalendarWrite) async -> IntervalsWriteAnswer {
		let eventsPath = ["athlete", athletePath, "events"]
		let answer: IntervalsAnswer
		do {
			switch write {
			case .create(let payload, let identity):
				answer = try await exchange(
					method: "POST", path: eventsPath + ["bulk"],
					query: [
						URLQueryItem(name: "upsert", value: "true"),
						URLQueryItem(name: "upsertOnUid", value: "false"),
						URLQueryItem(name: "updatePlanApplied", value: "false"),
					],
					body: .json(.array([payload.requestBody(identity)])))
			case .update(let id, let patch):
				answer = try await exchange(
					method: "PUT", path: eventsPath + [String(id.rawValue)],
					body: .json(patch.requestBody))
			case .delete(let id):
				answer = try await exchange(
					method: "DELETE", path: eventsPath + [String(id.rawValue)])
			}
		} catch let error as URLError where error.code == .cancelled {
			return .lost(.canceled)
		} catch {
			return .lost(.transport)
		}
		guard (200..<300).contains(answer.status) else { return .httpStatus(answer.status) }
		do {
			switch write {
			case .create:
				guard let rows = try parseJSON(answer.body).arrayValue, rows.count == 1,
					let row = rows.first
				else { return .lost(.unreadableBody) }
				return .saved(try Self.calendarEvent(from: row))
			case .update:
				return .saved(try Self.calendarEvent(from: try parseJSON(answer.body)))
			case .delete:
				return .saved(nil)
			}
		} catch {
			return .lost(.unreadableBody)
		}
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
		try parseJSON(
			try Self.accepted(try await exchange(method: "GET", path: path, query: query)))
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
		body: IntervalsBody? = nil,
		timeout: TimeInterval = IntervalsPolicy.requestTimeout
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
		request.timeoutInterval = timeout
		if let body {
			request.setValue(body.contentType, forHTTPHeaderField: "Content-Type")
			request.httpBody = body.data
		}
		let (data, response): (Data, URLResponse)
		do {
			(data, response) = try await session.data(for: request)
		} catch let error as URLError where error.code != .cancelled {
			throw IntervalsError.unreachable(error)
		}
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
				externalId: payload.externalID, tags: payload.tags ?? []),
			movingTime: payload.movingTime, trainingLoad: payload.trainingLoad,
			workoutDocument: payload.workoutDocument?.value)
	}

}

struct IntervalsAnswer: Sendable {
	let status: Int
	let body: Data
}

struct IntervalsBody: Sendable {
	let data: Data
	let contentType: String

	static func json(_ value: JSONValue) -> IntervalsBody {
		IntervalsBody(
			data: Data(value.canonicalDigestInput().utf8), contentType: "application/json")
	}
}
