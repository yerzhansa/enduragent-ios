import Foundation
import Testing

@testable import EnduragentCoach

@Suite
struct SerializerTests {
	@Test func matchesDesktopCases() throws {
		let data = try fixtureData("serializer-cases")
		let root = try JSONValue.parse(try #require(String(data: data, encoding: .utf8)))
		guard let cases = root.arrayValue else {
			Issue.record("serializer-cases.json must be an array")
			return
		}
		var mismatches: [String] = []
		for item in cases {
			let fields = item.objectFields
			guard let id = fields["id"]?.stringValue, let input = fields["input"] else {
				mismatches.append("missing id or input")
				continue
			}
			let expectedError = fields["error"]?.stringValue
			do {
				let workout = try IntervalsSerializer.parseWorkout(input)
				let serialized = try IntervalsSerializer.serialize(workout)
				if expectedError != nil {
					mismatches.append("\(id): expected error, got description")
					continue
				}
				let expectedDescription = fields["description"]?.stringValue ?? ""
				if serialized.description != expectedDescription {
					mismatches.append("\(id): description mismatch")
				}
				if serialized.description.utf8.elementsEqual(expectedDescription.utf8) == false {
					mismatches.append("\(id): description bytes mismatch")
				}
				let expectedTime = fields["movingTime"]?.intValue()
				if serialized.movingTime != expectedTime {
					mismatches.append(
						"\(id): movingTime \(serialized.movingTime) != \(expectedTime as Any)")
				}
			} catch is InvalidWorkout {
				if expectedError == nil {
					mismatches.append("\(id): unexpected InvalidWorkout")
				}
			} catch {
				mismatches.append("\(id): \(error)")
			}
		}
		#expect(mismatches.isEmpty, "\(mismatches.joined(separator: "; "))")
	}

	@Test func slugifyMatchesDesktop() {
		#expect(ChatExternalID.slugify(name: "Z2 Endurance 90min") == "z2-endurance-90min")
		#expect(ChatExternalID.slugify(name: "Endurance") == "endurance")
		#expect(ChatExternalID.slugify(name: "---") == "workout")
		#expect(ChatExternalID.slugify(name: "") == "workout")
		let long = String(repeating: "a", count: 50)
		#expect(ChatExternalID.slugify(name: long).count == 40)
		#expect(IntervalsSerializer.slug(date: "1998-06-14", name: "Endurance") == "endurance")
	}

	@Test func emptyNameThrows() {
		#expect(throws: InvalidWorkout.self) {
			_ = try IntervalsSerializer.serialize(
				IntervalsWorkoutInput(
					name: "",
					steps: [
						.simple(
							SimpleStep(
								type: .steady, duration: DurationInput(value: 1, unit: .minutes),
								power: PowerTarget(
									kind: .percentFtp, value: 50, low: nil, high: nil),
								cadence: nil, label: nil))
					])
			)
		}
	}

	@Test func formatDurationMatchesGrammar() {
		#expect(
			IntervalsSerializer.formatDuration(DurationInput(value: 30, unit: .seconds)) == "30s")
		#expect(
			IntervalsSerializer.formatDuration(DurationInput(value: 60, unit: .seconds)) == "1m")
		#expect(
			IntervalsSerializer.formatDuration(DurationInput(value: 90, unit: .seconds)) == "1m30")
		#expect(
			IntervalsSerializer.formatDuration(DurationInput(value: 61, unit: .seconds)) == "1m1")
		#expect(
			IntervalsSerializer.formatDuration(DurationInput(value: 10, unit: .minutes)) == "10m")
	}
}
