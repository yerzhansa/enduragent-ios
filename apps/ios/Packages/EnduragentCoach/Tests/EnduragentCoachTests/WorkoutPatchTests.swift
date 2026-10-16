import Foundation
import Testing

@testable import EnduragentCoach

@Suite
struct WorkoutPatchTests {
	let today: CivilDate = "1998-06-13"
	static let document = #"{"steps":[{"duration":3600}]}"#
	static let reviewed = WorkoutSnapshot(
		date: "1998-06-16", name: "Threshold", durationSeconds: 3600,
		description: "Main set\n- 20m 95%", load: 70, structure: WorkoutPatchTests.document)

	static let nativeDocument =
		#"{"steps":[{"duration":600,"power":{"units":"%ftp","value":60},"warmup":true},{"reps":3,"steps":[{"duration":120,"power":{"units":"%ftp","value":105}},{"duration":60,"power":{"units":"%ftp","value":50}}]}],"description":"Opener\r\nkeep it smooth"}"#

	@Test(arguments: [
		(#"{"date":"1998-06-20"}"#, #"{"start_date_local":"1998-06-20T00:00:00"}"#),
		(#"{"name":"  Recovery spin  "}"#, #"{"name":"Recovery spin"}"#),
		(#"{"durationSeconds":2700}"#, #"{"moving_time":2700}"#),
		(#"{"description":"Easy spin"}"#, #"{"description":"Easy spin"}"#),
		(#"{"trainingLoad":41.6}"#, #"{"icu_training_load":42}"#),
		(
			#"{"structure":\#(WorkoutPatchTests.nativeDocument)}"#,
			#"{"workout_doc":\#(WorkoutPatchTests.nativeDocument)}"#
		),
	])
	func eachFieldAloneSendsOnlyThatField(patch: String, body: String) throws {
		let parsed = try WorkoutPatch.parse(try JSONValue.parse(patch), today: today)
		#expect(parsed.requestBody == (try JSONValue.parse(body)))
	}

	@Test func authoredStepsSendTheSerializersDescriptionAndDurationForEveryNpmCase() throws {
		let data = try fixtureData("serializer-cases")
		let root = try JSONValue.parse(try #require(String(data: data, encoding: .utf8)))
		let cases = try #require(root.arrayValue).map(\.objectFields).filter { $0["error"] == nil }
		#expect(cases.count > 40)
		var mismatches: [String] = []
		for item in cases {
			let id = try #require(item["id"]?.stringValue)
			let steps = try #require(item["input"]?.objectFields["steps"])
			let patch = JSONValue.object([
				"name": .string("Threshold"),
				"description": .string("replaced by the steps"),
				"structure": .object(["steps": steps]),
			])
			let body = try WorkoutPatch.parse(patch, today: today).requestBody
			let expected = JSONValue.object([
				"name": .string("Threshold"),
				"description": try #require(item["description"]),
				"moving_time": try #require(item["movingTime"]),
			])
			if body != expected {
				mismatches.append(id)
			}
		}
		#expect(mismatches.isEmpty, "\(mismatches.joined(separator: ", "))")
	}

	@Test func aNativeWorkoutDocumentIsSentUnchangedAndBecomesTheDesiredStructure() throws {
		let document = try JSONValue.parse(Self.nativeDocument)
		let patch = try WorkoutPatch.parse(.object(["structure": document]), today: today)
		#expect(patch.requestBody.objectFields["workout_doc"] == document)
		#expect(patch.requestBody.objectFields.keys.sorted() == ["workout_doc"])
		let desired = patch.applied(to: Self.reviewed)
		#expect(
			desired.structure
				== #"{"description":"Opener\nkeep it smooth","steps":[{"duration":600,"power":{"units":"%ftp","value":60},"warmup":true},{"reps":3,"steps":[{"duration":120,"power":{"units":"%ftp","value":105}},{"duration":60,"power":{"units":"%ftp","value":50}}]}]}"#
		)
		#expect(desired.description == Self.reviewed.description)
	}

	@Test func aDescriptionAloneDropsTheDesiredStructureUnlessItIsUnchanged() throws {
		let changed = try WorkoutPatch.parse(
			try JSONValue.parse(#"{"description":"Easy spin"}"#), today: today)
		#expect(changed.requestBody == .object(["description": .string("Easy spin")]))
		#expect(changed.applied(to: Self.reviewed).structure == nil)
		#expect(changed.applied(to: Self.reviewed).description == "Easy spin")

		let unchanged = try WorkoutPatch.parse(
			try JSONValue.parse(#"{"description":"Main set\r\n- 20m 95%"}"#), today: today)
		#expect(unchanged.applied(to: Self.reviewed) == Self.reviewed)
	}

	@Test(arguments: [
		(#"{}"#, "invalid_input"),
		(#"{"date":"1998-06-12"}"#, "past_workout_destination"),
		(#"{"name":"\#(String(repeating: "n", count: 121))"}"#, "invalid_input"),
		(#"{"name":"   "}"#, "invalid_input"),
		(#"{"date":"1998-02-30"}"#, "invalid_date"),
		(#"{"durationSeconds":0}"#, "invalid_input"),
		(#"{"durationSeconds":90.5}"#, "invalid_input"),
		(#"{"description":"\#(String(repeating: "d", count: 4001))"}"#, "invalid_input"),
		(#"{"trainingLoad":-1}"#, "invalid_input"),
		(#"{"structure":"steps"}"#, "invalid_input"),
		(#"{"duration":3600}"#, "invalid_input"),
		(
			#"{"structure":{"steps":[{"type":"ramp","duration":{"value":5,"unit":"minutes"}}]}}"#,
			"invalid_workout"
		),
		(#"{"structure":{"steps":[{"repeat":3}]}}"#, "invalid_workout"),
		(#"{"structure":{"steps":[{"interval":{}}]}}"#, "invalid_workout"),
		(#"{"structure":{"steps":[{"recovery":{}}]}}"#, "invalid_workout"),
		(#"{"structure":{"steps":[{"duration":{"value":5}}]}}"#, "invalid_workout"),
		(#"{"structure":{"steps":[{"duration":{"unit":"minutes"}}]}}"#, "invalid_workout"),
		(#"{"structure":{"steps":[{"power":{"kind":"zone"}}]}}"#, "invalid_workout"),
	])
	func anUnusablePatchIsRefused(patch: String, code: String) throws {
		let json = try JSONValue.parse(patch)
		let refusal = #expect(throws: ToolInputError.self) {
			_ = try WorkoutPatch.parse(json, today: today)
		}
		#expect(refusal?.code == code)
	}

	@Test func theLimitsThemselvesAreAccepted() throws {
		let patch = try WorkoutPatch.parse(
			.object([
				"date": .string(today.rawValue),
				"name": .string(String(repeating: "n", count: 120)),
				"description": .string(""),
				"durationSeconds": .number(1),
				"trainingLoad": .number(0),
			]),
			today: today)
		#expect(
			patch.requestBody
				== .object([
					"start_date_local": .string("1998-06-13T00:00:00"),
					"name": .string(String(repeating: "n", count: 120)),
					"description": .string(""),
					"moving_time": .number(1),
					"icu_training_load": .number(0),
				]))
	}

	@Test(arguments: [
		(
			#"{"date":"1998-06-20"}"#,
			WorkoutSnapshot(
				date: "1998-06-20", name: "Threshold", durationSeconds: 3600,
				description: "Main set\n- 20m 95%", load: 70, structure: WorkoutPatchTests.document)
		),
		(
			#"{"name":"Recovery spin"}"#,
			WorkoutSnapshot(
				date: "1998-06-16", name: "Recovery spin", durationSeconds: 3600,
				description: "Main set\n- 20m 95%", load: 70, structure: WorkoutPatchTests.document)
		),
		(
			#"{"durationSeconds":2700}"#,
			WorkoutSnapshot(
				date: "1998-06-16", name: "Threshold", durationSeconds: 2700,
				description: "Main set\n- 20m 95%", load: 70, structure: WorkoutPatchTests.document)
		),
		(
			#"{"trainingLoad":45}"#,
			WorkoutSnapshot(
				date: "1998-06-16", name: "Threshold", durationSeconds: 3600,
				description: "Main set\n- 20m 95%", load: 45, structure: WorkoutPatchTests.document)
		),
		(
			#"{"description":"Easy spin\r\nstay seated"}"#,
			WorkoutSnapshot(
				date: "1998-06-16", name: "Threshold", durationSeconds: 3600,
				description: "Easy spin\nstay seated", load: 70, structure: nil)
		),
		(
			#"{"date":"1998-06-20","name":"Recovery spin","durationSeconds":2700,"trainingLoad":45}"#,
			WorkoutSnapshot(
				date: "1998-06-20", name: "Recovery spin", durationSeconds: 2700,
				description: "Main set\n- 20m 95%", load: 45, structure: WorkoutPatchTests.document)
		),
	])
	func appliedChangesExactlyTheNamedFields(patch: String, desired: WorkoutSnapshot) throws {
		let parsed = try WorkoutPatch.parse(try JSONValue.parse(patch), today: today)
		#expect(parsed.applied(to: Self.reviewed) == desired)
	}
}
