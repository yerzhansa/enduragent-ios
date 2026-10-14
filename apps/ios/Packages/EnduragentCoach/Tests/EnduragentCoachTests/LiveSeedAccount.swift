import Foundation

@testable import EnduragentCoach

struct IntervalsSeedAccount: SeedAccount {
	let client: IntervalsRESTClient
	private let authorization: String
	private let session = ephemeralSession(requestTimeout: 120, resourceTimeout: 300)

	init(key: String) {
		self.client = IntervalsRESTClient(credential: .apiKey(key))
		self.authorization = "Basic \(Data("API_KEY:\(key)".utf8).base64EncodedString())"
	}

	func athleteID() async throws -> String {
		try await client.profile().id
	}

	func activities(oldest: CivilDate, newest: CivilDate) async throws -> [SeedListing] {
		let rows = try await rows(of: "activities", oldest: oldest, newest: newest)
		return rows.map { row in
			let fields = row.objectFields
			return SeedListing(
				id: Self.identifier(fields["id"]) ?? "no id", name: fields["name"]?.stringValue,
				externalID: fields["external_id"]?.stringValue,
				start: fields["start_date_local"]?.stringValue,
				load: fields["icu_training_load"]?.numberValue,
				feel: fields["feel"]?.numberValue.map { Int($0) },
				rpe: fields["icu_rpe"]?.numberValue.map { Int($0) })
		}
	}

	func wellness(oldest: CivilDate, newest: CivilDate) async throws -> [CivilDate: [String:
		Double]]
	{
		var days: [CivilDate: [String: Double]] = [:]
		for row in try await rows(of: "wellness", oldest: oldest, newest: newest) {
			let fields = row.objectFields
			guard let date = fields["id"]?.stringValue.flatMap(CivilDate.init(rawValue:)) else {
				continue
			}
			days[date] = SeedWellnessDay.fields.reduce(into: [:]) { values, field in
				values[field] = fields[field]?.numberValue
			}
		}
		return days
	}

	func upload(_ activity: SeedActivity, file: Data) async throws -> String {
		let boundary = "enduragent-seed-boundary-\(activity.key)"
		let head = [
			"--\(boundary)",
			#"Content-Disposition: form-data; name="file"; filename="\#(activity.key).tcx""#,
			"Content-Type: application/vnd.garmin.tcx+xml", "", "",
		].joined(separator: "\r\n")
		let answer = try await send(
			"POST", ["athlete", IntervalsPolicy.athletePath, "activities"],
			query: [
				URLQueryItem(name: "name", value: activity.name),
				URLQueryItem(
					name: "description",
					value:
						"Synthetic training written by make live-seed for the Enduragent live checks."
				),
				URLQueryItem(name: "external_id", value: activity.externalID),
			],
			body: Data(head.utf8) + file + Data("\r\n--\(boundary)--\r\n".utf8),
			contentType: "multipart/form-data; boundary=\(boundary)")
		let fields = try Self.json(answer.data).objectFields
		let created = (fields["activities"]?.arrayValue ?? []).compactMap {
			Self.identifier($0.objectFields["id"])
		}
		guard let id = created.count == 1 ? created[0] : Self.identifier(fields["id"]) else {
			throw LiveCheckStop(
				description: "Uploading \(activity.externalID) answered without an activity id.")
		}
		return id
	}

	func rate(_ id: String, feel: Int, rpe: Int) async throws {
		let body = JSONValue.object([
			"feel": .number(Double(feel)), "icu_rpe": .number(Double(rpe)),
		])
		_ = try await send(
			"PUT", ["activity", id], body: Data(body.canonicalDigestInput().utf8),
			contentType: "application/json")
	}

	func delete(_ id: String) async throws {
		_ = try await send("DELETE", ["activity", id], absentIsDone: true)
	}

	func writeWellness(_ days: [CivilDate: [String: Double?]]) async throws {
		let rows = days.sorted { $0.key < $1.key }.map { date, values in
			var fields: [String: JSONValue] = ["id": .string(date.rawValue)]
			for (field, value) in values {
				fields[field] = value.map(JSONValue.number) ?? .null
			}
			return JSONValue.object(fields)
		}
		_ = try await send(
			"PUT", ["athlete", IntervalsPolicy.athletePath, "wellness-bulk"],
			body: Data(JSONValue.array(rows).canonicalDigestInput().utf8),
			contentType: "application/json")
	}

	private func rows(of kind: String, oldest: CivilDate, newest: CivilDate) async throws
		-> [JSONValue]
	{
		let json = try await client.getJSON(
			path: ["athlete", IntervalsPolicy.athletePath, kind],
			query: [
				URLQueryItem(name: "oldest", value: oldest.rawValue),
				URLQueryItem(name: "newest", value: newest.rawValue),
			])
		guard let rows = json.arrayValue else {
			throw LiveCheckStop(description: "The \(kind) list was not an array.")
		}
		return rows
	}

	private func send(
		_ method: String, _ path: [String], query: [URLQueryItem] = [], body: Data? = nil,
		contentType: String? = nil, absentIsDone: Bool = false
	) async throws -> (status: Int, data: Data) {
		var url = IntervalsPolicy.baseURL
		for component in path {
			url.append(path: component)
		}
		if !query.isEmpty {
			url.append(queryItems: query)
		}
		var request = URLRequest(url: url)
		request.httpMethod = method
		request.setValue(authorization, forHTTPHeaderField: "Authorization")
		request.setValue("application/json", forHTTPHeaderField: "Accept")
		if let contentType {
			request.setValue(contentType, forHTTPHeaderField: "Content-Type")
		}
		request.httpBody = body
		let (data, response) = try await session.data(for: request)
		let status = (response as? HTTPURLResponse)?.statusCode ?? 0
		if (200..<300).contains(status) || (absentIsDone && status == 404) {
			return (status, data)
		}
		throw LiveCheckStop(
			description:
				"\(method) /\(path.joined(separator: "/")) answered \(status): \(String(decoding: data.prefix(300), as: UTF8.self))"
		)
	}

	private static func json(_ data: Data) throws -> JSONValue {
		try JSONValue.parse(String(decoding: data, as: UTF8.self))
	}

	private static func identifier(_ value: JSONValue?) -> String? {
		switch value {
		case .string(let text): text
		case .number(let number): String(Int(number))
		default: nil
		}
	}
}
