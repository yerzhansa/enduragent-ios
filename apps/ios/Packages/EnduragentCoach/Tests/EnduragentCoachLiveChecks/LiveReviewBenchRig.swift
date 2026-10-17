import EnduragentCoachFixtures
import Foundation
import Testing

@testable import EnduragentCoach

struct ReviewBenchRig {
	enum Behavior {
		case faithful
		case stray
	}

	typealias Step = @Sendable (ScriptedRequest) -> [ScriptedEvent]
	typealias ItemFinder = @Sendable ([JSONValue]) -> String?

	let account = FakeIntervalsClient(athleteName: "Ada", ftp: 250)
	let behavior: Behavior
	let scenarios: [LiveScenario]
	let today: CivilDate
	let first: EventID
	let second: EventID
	let race: EventID
	let thursday: CivilDate

	var saturday: CivilDate { thursday.adding(days: 2) }
	var sunday: CivilDate { thursday.adding(days: 3) }
	var mixed: [LiveChangeShape] {
		[.edit(first), .delete(second), .add(thursday), .add(saturday)].sorted()
	}

	init(coach behavior: Behavior) throws {
		self.behavior = behavior
		today = IntervalsPolicy.today(now: Date(), timeZone: .current)
		let calendar = LiveReviewScenarioTests.seeded(on: today)
		account.events = calendar
		let event = { (key: String) in
			try #require(
				calendar.first { $0.externalId == LiveSeedCalendar.externalIDPrefix + key }
			)
			.id
		}
		first = try event("T1")
		second = try event("T2")
		race = try event("coach-race")
		scenarios = try LiveReviewScenarioTests.plan(calendar, today: today).scenarios.filter {
			$0.setting == .reviewing
		}
		let revised = scenarios.first?.turns.dropFirst().first?.expectations.compactMap {
			expectation -> CivilDate? in
			guard case .review(.revisesOnly(.add(let date))) = expectation else { return nil }
			return date
		}
		thursday = try #require(revised?.first)
	}

	func runAll() async throws -> [LiveScenarioRun] {
		let account = account
		var runs: [LiveScenarioRun] = []
		for (index, scenario) in scenarios.enumerated() {
			let model = FakeModelTransport(respond: Self.respond(to: steps(for: index)))
			let bench = LiveCoachBench(
				intervalsKey: "synthetic-intervals-key", openRouterKey: "synthetic-model-key",
				athlete: nil, model: try LiveCoachBench.builtInModel(),
				ledger: try LiveSpendLedger(
					file: try TestTemporaryFolders.make().appending(path: "spend.tsv"), limit: 100
				),
				today: today, modelTransport: { _ in model }, accountReads: { _, _ in account })
			runs.append(try await bench.run(scenario, attempt: 1))
		}
		return runs
	}

	func shown(_ shapes: [LiveChangeShape]) -> String {
		LiveReviewVerdict.shown(shapes.sorted())
	}

	private func steps(for index: Int) -> [String: [Step]] {
		let messages = scenarios.map { $0.turns.map(\.message) }
		guard messages.map(\.count) == [3, 2, 1] else { return [:] }
		let edit = Self.edit(first, #"{"durationSeconds":4500}"#)
		let all = [
			edit, Self.delete(second), Self.ride(on: thursday, minutes: 60),
			Self.strength(on: saturday, minutes: 30),
		]
		let (thursdayItem, saturdayItem) = (Self.item(on: thursday), Self.item(on: saturday))
		let turns: [[Step]] =
			switch (behavior, index) {
			case (.faithful, 0):
				[
					[Self.complete(all), Self.reply],
					[
						Self.read,
						Self.revise([(thursdayItem, Self.ride(on: thursday, minutes: 40))]),
						Self.reply,
					],
					[Self.reply],
				]
			case (.faithful, 1):
				[
					[Self.complete(all), Self.reply],
					[Self.read, Self.replace([Self.ride(on: sunday, minutes: 90)]), Self.reply],
				]
			case (.faithful, _):
				[
					[
						Self.complete([Self.edit(race, #"{"date":"\#(sunday.rawValue)"}"#)]),
						Self.reply,
					]
				]
			case (.stray, 0):
				[
					[Self.complete(all), Self.reply],
					[
						Self.complete(all), Self.read,
						Self.revise([
							(thursdayItem, Self.ride(on: thursday, minutes: 40)),
							(saturdayItem, Self.strength(on: saturday, minutes: 20)),
						]), Self.reply,
					],
					[
						Self.read,
						Self.revise([(saturdayItem, Self.strength(on: saturday, minutes: 25))]),
						Self.reply,
					],
				]
			case (.stray, 1):
				[
					[Self.complete([edit] + all.suffix(2)), Self.reply],
					[
						Self.read,
						Self.revise([(thursdayItem, Self.ride(on: thursday, minutes: 45))]),
						Self.reply,
					],
				]
			case (.stray, _):
				[[Self.complete([Self.ride(on: sunday, minutes: 90)]), Self.reply]]
			}
		return Dictionary(uniqueKeysWithValues: zip(messages[index], turns))
	}

	private static func respond(to steps: [String: [Step]]) -> FakeModelTransport.Response {
		{ request in
			guard request.purpose == .chat, let script = steps[request.text],
				request.step < script.count
			else { return ScriptedReply([.text("Noted."), .finish(reason: .stop)]) }
			return ScriptedReply(script[request.step](request))
		}
	}

	private static let reply: Step = { _ in [.text("Ready."), .finish(reason: .stop)] }

	private static let read: Step = { _ in
		[
			.toolCall(name: ToolName.getPendingWorkoutChanges.rawValue, arguments: "{}"),
			.finish(reason: .toolCalls),
		]
	}

	private static func call(_ arguments: String) -> Step {
		{ _ in
			[
				.toolCall(name: ToolName.prepareWorkoutChanges.rawValue, arguments: arguments),
				.finish(reason: .toolCalls),
			]
		}
	}

	private static func complete(_ changes: [String]) -> Step {
		call(
			#"{"preparation":{"kind":"complete","changes":[\#(changes.joined(separator: ","))]}}"#)
	}

	private static func replace(_ changes: [String]) -> Step {
		fromPending { reference, _ in
			#"{"preparation":{"kind":"replace","base":\#(reference),"changes":[\#(changes.joined(separator: ","))]}}"#
		}
	}

	private static func revise(_ replacements: [(ItemFinder, String)]) -> Step {
		fromPending { reference, items in
			let ids = replacements.compactMap { $0.0(items) }
			guard ids.count == replacements.count else { return nil }
			let listed = zip(ids, replacements).map { id, replacement in
				#"{"id":"\#(id)","change":\#(replacement.1)}"#
			}
			return
				#"{"preparation":{"kind":"revise","base":\#(reference),"replacements":[\#(listed.joined(separator: ","))]}}"#
		}
	}

	private static func fromPending(_ build: @escaping @Sendable (String, [JSONValue]) -> String?)
		-> Step
	{
		{ request in
			let pending: JSONValue
			do {
				pending = try JSONValue.parse(request.toolResults.last ?? "")
			} catch {
				return [
					.text("The pending review was unreadable: \(error)"), .finish(reason: .stop),
				]
			}
			let fields = pending.objectFields["data"]?.objectFields ?? [:]
			guard let reference = fields["reference"],
				let arguments = build(canonicalJSON(reference), fields["changes"]?.arrayValue ?? [])
			else { return [.text("No pending item matched."), .finish(reason: .stop)] }
			return call(arguments)(request)
		}
	}

	private static func item(on date: CivilDate) -> ItemFinder {
		{ items in
			items.first {
				$0.objectFields["change"]?.objectFields["date"]?.stringValue == date.rawValue
			}?.objectFields["id"]?.stringValue
		}
	}

	private static func edit(_ event: EventID, _ patch: String) -> String {
		#"{"kind":"edit","eventId":\#(event.rawValue),"patch":\#(patch)}"#
	}

	private static func delete(_ event: EventID) -> String {
		#"{"kind":"delete","eventId":\#(event.rawValue)}"#
	}

	private static func ride(on date: CivilDate, minutes: Int) -> String {
		#"{"kind":"add-cycling","date":"\#(date.rawValue)","workout":{"name":"Endurance","steps":[{"type":"warmup","duration":{"value":10,"unit":"minutes"},"power":{"kind":"percent_ftp","value":55}},{"type":"interval","duration":{"value":\#(minutes - 10),"unit":"minutes"},"power":{"kind":"percent_ftp","value":66}}]},"trainingLoad":\#(minutes / 2)}"#
	}

	private static func strength(on date: CivilDate, minutes: Int) -> String {
		#"{"kind":"add-strength","date":"\#(date.rawValue)","name":"Core","durationMinutes":\#(minutes),"effort":"Easy","description":"Plank 3x45s"}"#
	}
}
