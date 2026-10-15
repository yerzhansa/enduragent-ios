import Foundation

@testable import EnduragentCoach

struct IntervalsSeedAccount: SeedAccount {
	static let writeTimeout: TimeInterval = 120
	static let clearedWellnessField = JSONValue.number(-1)

	let client: IntervalsRESTClient

	init(client: IntervalsRESTClient) {
		self.client = client
	}

	init(key: String) {
		self.init(
			client: IntervalsRESTClient(
				credential: .apiKey(key),
				session: ephemeralSession(requestTimeout: Self.writeTimeout, resourceTimeout: 300)))
	}

	func athleteID() async throws -> String {
		try await client.profile().id
	}

	func activities(oldest: CivilDate, newest: CivilDate) async throws -> [SeedListing] {
		let rows = try await rows(of: "activities", oldest: oldest, newest: newest)
		return rows.map { row in
			let fields = row.objectFields
			return SeedListing(
				id: Self.identifier(fields) ?? "no id", name: fields["name"]?.stringValue,
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
		let answer = try await write(
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
			body: IntervalsBody(
				data: Data(head.utf8) + file + Data("\r\n--\(boundary)--\r\n".utf8),
				contentType: "multipart/form-data; boundary=\(boundary)"))
		let fields = try client.parseJSON(answer).objectFields
		let created = (fields["activities"]?.arrayValue ?? []).compactMap {
			Self.identifier($0.objectFields)
		}
		guard let id = created.count == 1 ? created[0] : Self.identifier(fields) else {
			throw LiveCheckStop(
				description: "Uploading \(activity.externalID) answered without an activity id.")
		}
		return id
	}

	func rate(_ id: String, feel: Int, rpe: Int) async throws {
		let body = JSONValue.object([
			"feel": .number(Double(feel)), "icu_rpe": .number(Double(rpe)),
		])
		_ = try await write("PUT", ["activity", id], body: .json(body))
	}

	func delete(_ id: String) async throws {
		_ = try await write("DELETE", ["activity", id], absentIsDone: true)
	}

	func writeWellness(_ days: [CivilDate: [String: Double?]]) async throws {
		let rows = days.sorted { $0.key < $1.key }.map { date, values in
			var fields: [String: JSONValue] = ["id": .string(date.rawValue)]
			for (field, value) in values {
				fields[field] = value.map(JSONValue.number) ?? Self.clearedWellnessField
			}
			return JSONValue.object(fields)
		}
		_ = try await write(
			"PUT", ["athlete", IntervalsPolicy.athletePath, "wellness-bulk"],
			body: .json(.array(rows)))
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

	private func write(
		_ method: String, _ path: [String], query: [URLQueryItem] = [],
		body: IntervalsBody? = nil, absentIsDone: Bool = false
	) async throws -> Data {
		let answer = try await client.exchange(
			method: method, path: path, query: query, body: body, timeout: Self.writeTimeout)
		if (200..<300).contains(answer.status) || (absentIsDone && answer.status == 404) {
			return answer.body
		}
		throw LiveCheckStop(
			description:
				"\(method) /\(path.joined(separator: "/")) answered \(answer.status): \(String(decoding: answer.body.prefix(300), as: UTF8.self))"
		)
	}

	private static func identifier(_ fields: [String: JSONValue]) -> String? {
		IntervalsRESTClient.activityID(in: fields)?.rawValue
	}
}
