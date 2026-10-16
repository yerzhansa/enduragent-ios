import Foundation

@testable import EnduragentCoach

struct LiveFieldDiff: Sendable, Equatable {
	let field: String
	let sent: JSONValue
	let stored: JSONValue

	var line: String {
		"\(field) sent \(sent.canonicalDigestInput()), stored \(stored.canonicalDigestInput())"
	}
}

struct LiveSave: Sendable, Equatable {
	let sentDescription: Bool
	let sentStructure: Bool
	let stored: CalendarEvent

	var storedSteps: Int {
		stored.workoutDocument?.objectFields["steps"]?.arrayValue?.count ?? 0
	}
}

struct IntervalsRewrite: Sendable, Equatable, Decodable {
	enum Rule: String, Sendable, Decodable {
		case estimatedFromSteps
		case derivedFromDescription
	}

	let field: String
	let rule: Rule
	let why: String

	func explains(_ diff: LiveFieldDiff, in save: LiveSave) -> Bool {
		guard diff.field == field else { return false }
		switch rule {
		case .estimatedFromSteps:
			return save.sentDescription && save.storedSteps > 0
		case .derivedFromDescription:
			return save.sentDescription && !save.sentStructure
		}
	}
}

struct IntervalsRewrites: Sendable, Equatable, Decodable {
	let rewrites: [IntervalsRewrite]

	static let file = (0..<2).reduce(URL(fileURLWithPath: #filePath)) { path, _ in
		path.deletingLastPathComponent()
	}.appending(path: "EnduragentCoachTests/Fixtures/intervals-rewrites.json")

	static func load() throws -> IntervalsRewrites {
		try JSONDecoder().decode(IntervalsRewrites.self, from: try Data(contentsOf: file))
	}

	func unlisted(_ diffs: [LiveFieldDiff], in save: LiveSave) -> [LiveFieldDiff] {
		diffs.filter { diff in !rewrites.contains { $0.explains(diff, in: save) } }
	}
}

extension LiveCalendarRun {
	mutating func checkParsedSteps(of add: LiveCalendarAdd, in save: LiveSave) {
		guard save.storedSteps > 0, let document = save.stored.workoutDocument?.objectFields
		else { return }
		let steps = document["steps"]?.arrayValue ?? []
		let blocks = steps.map { step in
			let fields = step.objectFields
			let seconds = Self.text(fields["duration"]?.numberValue.map { Int($0) })
			return fields["reps"]?.numberValue.map { "\(Int($0))x \(seconds)s" } ?? "\(seconds)s"
		}
		let total = document["duration"]?.numberValue.map { Int($0) }
		note(
			"intervals.icu parsed \(blocks.joined(separator: ", ")), \(Self.text(total)) seconds in all"
		)
		if total != add.payload.movingTime {
			fail(
				"intervals.icu parsed \(Self.text(total)) seconds of steps, not the reviewed \(Self.text(add.payload.movingTime))"
			)
		}
	}

	mutating func writeFindings(to folder: LiveRunFolder, checkingFor key: String) throws {
		collect()
		var index = ["file\tstep\tmethod\tpath\tquery\tstatus\tbytes"]
		for (position, tapped) in responses.enumerated() {
			let file =
				"raw/\(position + 1)-\(tapped.step.replacingOccurrences(of: " ", with: "-")).json"
			try folder.write(try tapped.response.redactedBody(), to: file)
			index.append(
				[
					file, tapped.step, tapped.response.method, tapped.response.path,
					tapped.response.query ?? "", String(tapped.response.status),
					String(tapped.response.body.count),
				].joined(separator: "\t"))
		}
		try folder.write(index.joined(separator: "\n") + "\n", to: "raw/index.tsv")
		failures += try folder.files(containing: key).map(Self.keyLeak)
		let lines =
			[
				"# Live calendar \(folder.run.lastPathComponent)", "",
				"Today on this Mac: \(plan.today.rawValue)", "", "## Failures", "",
			] + (failures.isEmpty ? ["None."] : failures.map { "- \($0)" }) + [
				"", "## Numbers intervals.icu returned", "",
			] + Self.numbers(in: responses.map(\.response)) + log + [""]
		try folder.write(lines.joined(separator: "\n"), to: "calendar.md")
		failures += try folder.files(containing: key).filter { $0 == "calendar.md" }.map(
			Self.keyLeak)
	}

	static func keyLeak(_ file: String) -> String {
		"\(file): the saved file holds the intervals.icu key"
	}

	static func numbers(in responses: [TappedResponse]) -> [String] {
		var values: [String: [Double]] = ["moving_time": [], "icu_training_load": []]
		func walk(_ value: JSONValue) {
			switch value {
			case .object(let fields):
				for (field, inner) in fields {
					if case .number(let number) = inner, values[field] != nil {
						values[field, default: []].append(number)
					}
					walk(inner)
				}
			case .array(let items):
				items.forEach(walk)
			case .null, .bool, .number, .string:
				break
			}
		}
		responses.compactMap(\.json).forEach(walk)
		return values.sorted { $0.key < $1.key }.map { field, numbers in
			let fractional = numbers.filter { $0.rounded() != $0 }
			let kind =
				numbers.isEmpty
				? "never present"
				: fractional.isEmpty
					? "always whole (\(numbers.count) values)"
					: "fractional in \(fractional.count) of \(numbers.count) values: \(fractional.map { String($0) }.joined(separator: ", "))"
			return "- \(field): \(kind)"
		}
	}

	static func diffs(sent add: LiveCalendarAdd, stored: CalendarEvent) -> [LiveFieldDiff] {
		let payload = add.payload
		return [
			diff(
				"start_date_local", .string("\(payload.date.rawValue)T00:00:00"),
				.string(stored.startDateLocal)),
			diff("category", .string("WORKOUT"), .string(stored.category)),
			diff("type", .string(payload.type.rawValue), json(stored.type)),
			diff("name", .string(payload.name), json(stored.name)),
			diff("description", .string(payload.description), json(stored.description)),
			diff("moving_time", json(payload.movingTime), json(stored.movingTime)),
			diff("icu_training_load", json(payload.trainingLoad), json(stored.trainingLoad)),
			diff("external_id", .string(add.externalID), json(stored.externalId)),
			diff(
				"tags", .array([.string(IntervalsPolicy.coachTag)]),
				.array(stored.tags.map(JSONValue.string))),
		].compactMap { $0 }
	}

	static func diffs(expected: WorkoutSnapshot, stored: WorkoutSnapshot) -> [LiveFieldDiff] {
		[
			diff(
				"start_date_local", .string(expected.date.rawValue), .string(stored.date.rawValue)),
			diff("name", json(expected.name), json(stored.name)),
			diff("moving_time", json(expected.durationSeconds), json(stored.durationSeconds)),
			diff("description", json(expected.description), json(stored.description)),
			diff("icu_training_load", json(expected.load), json(stored.load)),
			diff("workout_doc", json(expected.structure), json(stored.structure)),
		].compactMap { $0 }
	}

	static func diff(_ field: String, _ sent: JSONValue, _ stored: JSONValue)
		-> LiveFieldDiff?
	{
		sent == stored ? nil : LiveFieldDiff(field: field, sent: sent, stored: stored)
	}

	static func json(_ text: String?) -> JSONValue { text.map(JSONValue.string) ?? .null }
	static func json(_ number: Int?) -> JSONValue {
		number.map { .number(Double($0)) } ?? .null
	}

	static func text(_ number: Int?) -> String { number.map(String.init) ?? "none" }

	static func text(_ answer: IntervalsWriteAnswer) -> String {
		switch answer {
		case .saved(let event?):
			"saved event \(event.id.rawValue) on \(event.startDateLocal.prefix(10))"
		case .saved(nil): "saved"
		case .httpStatus(let status): "HTTP \(status)"
		case .lost(let loss): "lost (\(loss))"
		}
	}
}
