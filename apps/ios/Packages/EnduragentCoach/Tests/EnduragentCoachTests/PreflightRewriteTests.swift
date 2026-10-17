import EnduragentCoachFixtures
import Foundation
import Testing

@testable import EnduragentCoach

extension PreflightJudgeTests {
	struct ListedRewrites: Decodable {
		struct Rewrite: Decodable {
			let field: String
			let rule: String
		}

		let rewrites: [Rewrite]
	}

	struct RewriteCase: Sendable, CustomTestStringConvertible {
		let label: String
		let reviewed: CalendarEvent
		let rewritten: CalendarEvent
		let patch: WorkoutPatch
		let saved: CalendarEvent
		let unexplained: CalendarEvent
		let unexplainedPatch: WorkoutPatch
		let unexplainedField: SnapshotField

		var testDescription: String { label }
	}

	static let feelDescription = "Steady endurance by feel, no structure."

	static let rewriteCases: [String: [RewriteCase]] = [
		"icu_training_load estimatedFromSteps": [
			RewriteCase(
				label: "Load beside parsed steps after the description is sent",
				reviewed: Fixture.stepped(201, on: "1998-09-10", load: 33),
				rewritten: Fixture.stepped(201, on: "1998-09-10", load: 22),
				patch: Fixture.patch(
					date: "1998-09-12", description: Fixture.stepsDescription, load: 33),
				saved: Fixture.stepped(201, on: "1998-09-12", load: 22),
				unexplained: Fixture.stepped(201, on: "1998-09-10", load: 22),
				unexplainedPatch: Fixture.patch(load: 33), unexplainedField: .load)
		],
		"workout_doc derivedFromDescription": [
			RewriteCase(
				label: "a document derived again from the same steps",
				reviewed: Fixture.stepped(201, on: "1998-09-10"),
				rewritten: Fixture.workout(
					201, on: "1998-09-10", name: "Sweet spot", minutes: 55, load: 61,
					description: Fixture.stepsDescription,
					document: Fixture.derivedDocument(steps: Fixture.parsedSteps, averageWatts: 195)
				),
				patch: Fixture.patch(description: Fixture.stepsDescription),
				saved: Fixture.workout(
					201, on: "1998-09-10", name: "Sweet spot", minutes: 55, load: 61,
					description: Fixture.stepsDescription,
					document: Fixture.derivedDocument(steps: Fixture.parsedSteps, averageWatts: 195)
				),
				unexplained: Fixture.workout(
					201, on: "1998-09-10", name: "Sweet spot", minutes: 55, load: 61,
					description: Fixture.stepsDescription,
					document: Fixture.derivedDocument(
						steps: .array([.object(["duration": .number(3300)])]), averageWatts: 180)),
				unexplainedPatch: Fixture.patch(minutes: 75), unexplainedField: .structure),
			RewriteCase(
				label: "a document with no steps where there was none",
				reviewed: Fixture.workout(201, on: "1998-09-10", description: feelDescription),
				rewritten: Fixture.workout(
					201, on: "1998-09-10", description: feelDescription,
					document: .object([
						"average_watts": .null, "description": .string(feelDescription),
						"distance": .number(0), "duration": .number(0), "locales": .array([]),
						"options": .object([:]), "steps": .array([]),
					])),
				patch: Fixture.patch(description: feelDescription),
				saved: Fixture.workout(
					201, on: "1998-09-10", description: feelDescription,
					document: .object(["duration": .number(0), "steps": .array([])])),
				unexplained: Fixture.workout(
					201, on: "1998-09-10", description: feelDescription,
					document: .object(["steps": .array([.object(["duration": .number(3600)])])])),
				unexplainedPatch: Fixture.patch(minutes: 75), unexplainedField: .structure),
		],
	]

	@Test func eachListedRewriteNeedsNoNewApprovalAndReadsAsAppliedAfterASave() throws {
		let listed = try JSONDecoder().decode(
			ListedRewrites.self, from: try fixtureData("intervals-rewrites"))
		let names = listed.rewrites.map { "\($0.field) \($0.rule)" }
		#expect(Set(names) == Set(Self.rewriteCases.keys))
		#expect(names.count == Set(names).count)

		for example in names.flatMap({ Self.rewriteCases[$0] ?? [] }) {
			let review = try Fixture.review([try Fixture.edit(example.reviewed, example.patch)])
			let saved = try example.saved.snapshot
			let rewritten = Self.judged(review, Calendar([example.rewritten]))
			#expect(rewritten.kind == .clear, "\(example.label): \(rewritten)")
			#expect(example.patch.isApplied(on: saved), "\(example.label)")

			let unexplained = Self.judged(
				try Fixture.review([try Fixture.edit(example.reviewed, example.unexplainedPatch)]),
				Calendar([example.unexplained]))
			#expect(
				unexplained.differences
					== [
						TargetDifference(
							change: Fixture.change(0), fields: [example.unexplainedField])
					],
				"\(example.label): \(unexplained)")
		}
	}
}
