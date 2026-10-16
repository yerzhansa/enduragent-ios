import Foundation
import Testing

@testable import EnduragentCoach

@Suite
struct CalendarPayloadTests {
	let today: CivilDate = "1998-06-13"
	let identity = CalendarWriteID(
		rawValue: UUID(uuid: (1, 2, 3, 4, 5, 6, 7, 8, 9, 10, 11, 12, 13, 14, 15, 16)))

	@Test func rideBodyCarriesNpmSerializerOutputForEveryCase() throws {
		let data = try fixtureData("serializer-cases")
		let root = try JSONValue.parse(try #require(String(data: data, encoding: .utf8)))
		let cases = try #require(root.arrayValue)
		#expect(cases.count > 50)
		var mismatches: [String] = []
		for item in cases {
			let fields = item.objectFields
			let id = try #require(fields["id"]?.stringValue)
			let change = JSONValue.object([
				"kind": .string("add-cycling"),
				"date": .string("1998-06-14"),
				"workout": try #require(fields["input"]),
			])
			guard fields["error"] == nil else {
				#expect(throws: ToolInputError.self, "\(id)") {
					_ = try CalendarPayload.ride(change, today: today)
				}
				continue
			}
			let body = try CalendarPayload.ride(change, today: today).requestBody(identity)
				.objectFields
			let expectedDescription = try #require(fields["description"]?.stringValue)
			let description = try #require(body["description"]?.stringValue)
			if !description.utf8.elementsEqual(expectedDescription.utf8) {
				mismatches.append("\(id): description")
			}
			if body["moving_time"] != fields["movingTime"] {
				mismatches.append("\(id): moving_time")
			}
			if body["type"] != .string("Ride") {
				mismatches.append("\(id): type")
			}
		}
		#expect(mismatches.isEmpty, "\(mismatches.joined(separator: "; "))")
	}

	@Test func loadIsRoundedRefusedBelowZeroAndOmittedWhenAbsent() throws {
		let rounded = try CalendarPayload.ride(try ride(load: "41.6"), today: today)
		#expect(rounded.requestBody(identity).objectFields["icu_training_load"] == .number(42))
		let roundedStrength = try CalendarPayload.strength(try strength(load: "41.6"), today: today)
		#expect(
			roundedStrength.requestBody(identity).objectFields["icu_training_load"] == .number(42))

		let negativeRide = try ride(load: "-1")
		#expect(throws: ToolInputError.self) {
			_ = try CalendarPayload.ride(negativeRide, today: today)
		}
		let negativeStrength = try strength(load: "-1")
		#expect(throws: ToolInputError.self) {
			_ = try CalendarPayload.strength(negativeStrength, today: today)
		}

		let unloaded = try CalendarPayload.ride(try ride(load: nil), today: today)
		#expect(
			unloaded.requestBody(identity).objectFields.keys.contains("icu_training_load") == false)
		let unloadedStrength = try CalendarPayload.strength(try strength(load: nil), today: today)
		#expect(
			unloadedStrength.requestBody(identity).objectFields.keys.contains("icu_training_load")
				== false)
	}

	@Test func strengthSendsRoundedSecondsJoinedTextAndItsOwnLoad() throws {
		let payload = try CalendarPayload.strength(
			try JSONValue.parse(
				#"{"kind":"add-strength","date":"1998-06-14","name":"  Leg day  ","durationMinutes":37.5,"effort":"  Moderate, RPE 6  ","description":"Squats 3x8\nLunges 3x10","trainingLoad":28}"#
			),
			today: today
		)
		let body = payload.requestBody(identity).objectFields
		#expect(body["moving_time"] == .number(2250))
		#expect(body["description"] == .string("Moderate, RPE 6\n\nSquats 3x8\nLunges 3x10"))
		#expect(body["icu_training_load"] == .number(28))
		#expect(body["name"] == .string("Leg day"))
		#expect(body["type"] == .string("WeightTraining"))
		#expect(body["start_date_local"] == .string("1998-06-14T00:00:00"))
	}

	@Test(arguments: [
		#""name":"   ","durationMinutes":30,"effort":"Easy","description":"Core""#,
		#""name":"Core","durationMinutes":30,"effort":" \n ","description":"Core""#,
		#""name":"Core","durationMinutes":0,"effort":"Easy","description":"Core""#,
		#""name":"Core","durationMinutes":-5,"effort":"Easy","description":"Core""#,
		#""name":"Core","durationMinutes":1e16,"effort":"Easy","description":"Core""#,
		#""name":"Core","durationMinutes":0.001,"effort":"Easy","description":"Core""#,
		#""name":"Core","effort":"Easy","description":"Core""#,
		#""name":"Core","durationMinutes":30,"effort":"Easy","description":"""#,
		#""name":"\#(String(repeating: "n", count: 121))","durationMinutes":30,"effort":"Easy","description":"Core""#,
		#""name":"Core","durationMinutes":30,"effort":"Easy","description":"\#(String(repeating: "d", count: 4001))""#,
	])
	func strengthRefusesUnusableFieldsBeforeAnyWrite(_ fields: String) throws {
		let change = try JSONValue.parse(#"{"kind":"add-strength","date":"1998-06-14",\#(fields)}"#)
		#expect(throws: ToolInputError.self) {
			_ = try CalendarPayload.strength(change, today: today)
		}
	}

	@Test func strengthRefusesPastDateAndInfiniteDurationAndAcceptsBlankDescription() throws {
		var past = try strength(load: nil).objectFields
		past["date"] = .string("1998-06-12")
		#expect(throws: ToolInputError(code: "past_date_refused", details: pastDetails)) {
			_ = try CalendarPayload.strength(.object(past), today: today)
		}
		var pastRide = try ride(load: nil).objectFields
		pastRide["date"] = .string("1998-06-12")
		#expect(throws: ToolInputError(code: "past_date_refused", details: pastDetails)) {
			_ = try CalendarPayload.ride(.object(pastRide), today: today)
		}

		var infinite = try strength(load: nil).objectFields
		infinite["durationMinutes"] = .number(.infinity)
		#expect(throws: ToolInputError.self) {
			_ = try CalendarPayload.strength(.object(infinite), today: today)
		}

		var blank = try strength(load: nil).objectFields
		blank["description"] = .string("   ")
		let accepted = try CalendarPayload.strength(.object(blank), today: today)
		#expect(
			accepted.requestBody(identity).objectFields["description"] == .string("Easy\n\n   "))
	}

	@Test func rideAndStrengthFromOneListKeepTheirOwnFields() throws {
		let changes = try #require(
			try JSONValue.parse(
				"[\(rideJSON(load: "55")),\(strengthJSON(load: "12.4"))]"
			).arrayValue)
		let ride = try CalendarPayload.ride(changes[0], today: today).requestBody(identity)
			.objectFields
		let strength = try CalendarPayload.strength(changes[1], today: today).requestBody(identity)
			.objectFields
		#expect(ride["type"] == .string("Ride"))
		#expect(ride["name"] == .string("Threshold 2x2"))
		#expect(ride["moving_time"] == .number(900))
		#expect(ride["icu_training_load"] == .number(55))
		#expect(ride["start_date_local"] == .string("1998-06-14T00:00:00"))
		#expect(strength["type"] == .string("WeightTraining"))
		#expect(strength["name"] == .string("Core"))
		#expect(strength["moving_time"] == .number(1800))
		#expect(strength["icu_training_load"] == .number(12))
		#expect(strength["description"] == .string("Easy\n\nPlank 3x45s"))
		#expect(strength["start_date_local"] == .string("1998-06-15T00:00:00"))
	}

	@Test func bodyCarriesTheWriteIdentityAndNothingElse() throws {
		let payload = try CalendarPayload.strength(try strength(load: "30"), today: today)
		let uid = "01020304-0506-0708-090A-0B0C0D0E0F10"
		#expect(identity.uid == uid)
		#expect(
			payload.requestBody(identity)
				== .object([
					"start_date_local": .string("1998-06-15T00:00:00"),
					"category": .string("WORKOUT"),
					"type": .string("WeightTraining"),
					"name": .string("Core"),
					"description": .string("Easy\n\nPlank 3x45s"),
					"moving_time": .number(1800),
					"icu_training_load": .number(30),
					"external_id": .string("cycling-coach:\(uid)"),
					"uid": .string(uid),
					"tags": .array([.string("cycling-coach")]),
				]))
	}

	private var pastDetails: String {
		"Cannot create a workout dated 1998-06-12 — it's before today (1998-06-13). Use today's date or later."
	}

	private func ride(load: String?) throws -> JSONValue {
		try JSONValue.parse(rideJSON(load: load))
	}

	private func strength(load: String?) throws -> JSONValue {
		try JSONValue.parse(strengthJSON(load: load))
	}

	private func rideJSON(load: String?) -> String {
		let steps = [
			#"{"type":"warmup","duration":{"value":5,"unit":"minutes"},"power":{"kind":"percent_ftp","value":55}}"#,
			#"{"type":"set","repeat":2,"interval":{"type":"interval","duration":{"value":2,"unit":"minutes"},"power":{"kind":"percent_ftp","value":100}},"recovery":{"type":"recovery","duration":{"value":1,"unit":"minutes"},"power":{"kind":"percent_ftp","value":50}}}"#,
			#"{"type":"cooldown","duration":{"value":4,"unit":"minutes"},"power":{"kind":"percent_ftp","value":50}}"#,
		]
		let workout = #"{"name":"Threshold 2x2","steps":[\#(steps.joined(separator: ","))]}"#
		return
			#"{"kind":"add-cycling","date":"1998-06-14","workout":\#(workout)\#(loadField(load))}"#
	}

	private func strengthJSON(load: String?) -> String {
		#"{"kind":"add-strength","date":"1998-06-15","name":"Core","durationMinutes":30,"effort":"Easy","description":"Plank 3x45s"\#(loadField(load))}"#
	}

	private func loadField(_ load: String?) -> String {
		load.map { #","trainingLoad":\#($0)"# } ?? ""
	}
}
