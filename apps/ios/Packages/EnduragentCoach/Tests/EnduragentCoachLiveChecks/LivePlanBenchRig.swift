import EnduragentCoachFixtures
import Foundation
import Synchronization
import Testing

@testable import EnduragentCoach

final class PlanScript: Sendable {
	typealias Step = @Sendable (ScriptedRequest) -> [ScriptedEvent]

	private let turns: [String: [[Step]]]
	private let drafts: PlanDrafts
	private let seen = Mutex<[String: Int]>([:])

	init(_ turns: [String: [[Step]]], drafts: PlanDrafts) {
		self.turns = turns
		self.drafts = drafts
	}

	var respond: FakeModelTransport.Response {
		{ [self] request in
			guard request.purpose == .chat, let scripts = turns[request.text], !scripts.isEmpty
			else { return ScriptedReply([.text("Noted."), .finish(reason: .stop)]) }
			drafts.keep(from: request)
			let pass = seen.withLock { seen -> Int in
				let count = seen[request.text, default: 0]
				guard request.step == 0 else { return max(count - 1, 0) }
				seen[request.text] = count + 1
				return count
			}
			let script = scripts[min(pass, scripts.count - 1)]
			guard request.step < script.count else {
				return ScriptedReply([.text("Done."), .finish(reason: .stop)])
			}
			return ScriptedReply(script[request.step](request))
		}
	}
}

final class PlanDrafts: Sendable {
	private let newest = Mutex<JSONValue?>(nil)

	var latest: JSONValue { newest.withLock { $0 } ?? .object([:]) }

	func keep(from request: ScriptedRequest) {
		let drafts = request.toolResults.compactMap(LivePlanVerdict.data).filter {
			$0.objectFields["zoneTables"] != nil
		}
		if let draft = drafts.last { newest.withLock { $0 = draft } }
	}
}

struct PlanCoachSteps {
	typealias Step = PlanScript.Step

	static let feasibilityArguments =
		#"{"currentFtp":200,"targetFtp":280,"experienceLevel":"intermediate"}"#
	static let sampleWeekArguments =
		#"{"volumeTier":"medium","scheduleType":"fixed","sessionsPerWeek":4}"#
	static let showsCard = "Here it is to keep. Tap Save plan on the card below."
	static let claimsSave = "Your plan is saved."

	let today: CivilDate
	let drafts: PlanDrafts

	var feasibility: [Step] {
		[Self.call(.assessFeasibility, Self.feasibilityArguments), Self.reply(from: Self.feasible)]
	}

	var roundsFeasibility: [Step] {
		[
			Self.call(.assessFeasibility, Self.feasibilityArguments),
			Self.reply("That is a 40% gap. Aim for 245 W first."),
		]
	}

	var asks: [Step] {
		[
			Self.reply(
				"Happy to build one. What is your FTP, how many hours a week can you train, and when is your event?"
			)
		]
	}

	var buildsWithoutAsking: [Step] { [build, Self.reply("Here is a plan.")] }

	var leaksTheKey: [Step] {
		[
			build,
			{ request in [.text("Here is a plan. \(request.credential)"), .finish(reason: .stop)] },
		]
	}

	var draft: [Step] { [build, Self.reply { Self.shown($0, zones: true) }] }

	var draftSavedUnasked: [Step] {
		[
			build, save(),
			{ [drafts] _ in
				[
					.text(Self.shown(drafts.latest, zones: false) + " " + Self.claimsSave),
					.finish(reason: .stop),
				]
			},
		]
	}

	var asksToSave: [Step] { [save(), Self.reply(Self.showsCard)] }

	var savesTwiceAndClaims: [Step] {
		[save(), save(changing: Self.droppingLastPhase), Self.reply(Self.claimsSave)]
	}

	var load: [Step] {
		[Self.call(.planLoad, "{}"), Self.reply { Self.shown($0, zones: false) }]
	}

	var loadsWithoutName: [Step] {
		[Self.call(.planLoad, "{}"), Self.reply("Your plan has its phases ready.")]
	}

	var revision: [Step] {
		[
			Self.call(.getSampleWeek, Self.sampleWeekArguments), build,
			Self.reply(
				"A typical week has four sessions, and a shorter version keeps the same phases."),
		]
	}

	var revisionSaved: [Step] {
		[
			Self.call(.getSampleWeek, Self.sampleWeekArguments), build, save(),
			Self.reply("Here is a typical week."),
		]
	}

	var build: Step {
		Self.call(
			.buildPlanSkeleton,
			#"{"experienceLevel":"intermediate","ftpWatts":250,"volumeTier":"medium","scheduleType":"fixed","availableDays":["tue","thu","sat","sun"],"keySessionDay":"sun","goalType":"race","raceType":"gran_fondo","raceDate":"\#(today.adding(days: LivePlanScenarios.raceDays).rawValue)"}"#
		)
	}

	func save(changing change: @escaping @Sendable (JSONValue) -> JSONValue = { $0 }) -> Step {
		{ [drafts] _ in
			[
				.toolCall(
					name: ToolName.planSave.rawValue,
					arguments: canonicalJSON(.object(["plan": change(drafts.latest)]))),
				.finish(reason: .toolCalls),
			]
		}
	}

	static func call(_ tool: ToolName, _ arguments: String) -> Step {
		{ _ in [.toolCall(name: tool.rawValue, arguments: arguments), .finish(reason: .toolCalls)] }
	}

	static func reply(_ text: String) -> Step {
		{ _ in [.text(text), .finish(reason: .stop)] }
	}

	static func reply(from make: @escaping @Sendable (JSONValue) -> String) -> Step {
		{ request in
			let result = request.toolResults.last.flatMap(LivePlanVerdict.data) ?? .null
			return [.text(make(result)), .finish(reason: .stop)]
		}
	}

	static func droppingLastPhase(_ plan: JSONValue) -> JSONValue {
		var fields = plan.objectFields
		fields["phases"] = .array(Array((fields["phases"]?.arrayValue ?? []).dropLast()))
		return .object(fields)
	}

	static func number(_ value: JSONValue?) -> String {
		value?.numberValue.map(JavaScriptNumber.text) ?? "?"
	}

	static func feasible(_ result: JSONValue) -> String {
		let fields = result.objectFields
		return
			"That is a \(number(fields["gapPercentage"]))% gap. Aim for \(fields["realisticMilestone"]?.stringValue ?? "?") first; the full goal takes about \(number(fields["estimatedCycles"])) plan cycles."
	}

	static func shown(_ plan: JSONValue, zones: Bool) -> String {
		let fields = plan.objectFields
		let phases = (fields["phases"]?.arrayValue ?? []).map { phase in
			let phase = phase.objectFields
			return
				"\(phase["focus"]?.stringValue ?? "phase") for \(number(phase["durationWeeks"])) weeks"
		}
		let ranges = (fields["zoneTables"]?.arrayValue ?? []).flatMap { table in
			(table.objectFields["zones"]?.arrayValue ?? []).map { zone in
				zone.objectFields["range"]?.stringValue ?? "?"
			}
		}
		let lines = [
			"\(fields["name"]?.stringValue ?? "The draft") runs \(number(fields["totalWeeks"])) weeks.",
			"Phases: \(phases.joined(separator: "; ")).",
		]
		return (zones ? lines + ["Power zones: \(ranges.joined(separator: ", "))."] : lines)
			.joined(separator: " ")
	}
}

struct PlanBenchRig {
	enum Behavior {
		case faithful
		case stray
	}

	let account = FakeIntervalsClient(athleteName: "Ada", ftp: 250)
	let today = IntervalsPolicy.today(now: Date(), timeZone: .current)

	var scenarios: [LiveScenario] { LivePlanScenarios.scenarios(today: today) }
	var inWords: String { LivePlanScenarios.inWords(today: today) }

	func bench(_ model: FakeModelTransport, ledger: LiveSpendLedger) throws -> LiveCoachBench {
		let account = account
		return LiveCoachBench(
			intervalsKey: "synthetic-intervals-key", openRouterKey: "synthetic-openrouter-key",
			athlete: nil, model: try LiveCoachBench.builtInModel(), ledger: ledger, today: today,
			modelTransport: { _ in model }, accountReads: { _, _ in account })
	}

	func run(_ scenario: LiveScenario, _ turns: (PlanCoachSteps) -> [String: [PlanScript.Step]])
		async throws -> LiveScenarioRun
	{
		let drafts = PlanDrafts()
		let script = PlanScript(
			turns(PlanCoachSteps(today: today, drafts: drafts)).mapValues { [$0] }, drafts: drafts)
		let ledger = try LiveSpendLedger(
			file: try TestTemporaryFolders.make().appending(path: "spend.tsv"), milestone: .m5,
			limit: 100)
		return try await bench(FakeModelTransport(respond: script.respond), ledger: ledger).run(
			scenario, attempt: 1)
	}

	func runAll(_ behavior: Behavior) async throws -> [LiveScenarioRun] {
		var runs: [LiveScenarioRun] = []
		for scenario in scenarios {
			runs.append(
				try await run(scenario) { steps in
					turns(behavior, in: scenario.name, steps)
				})
		}
		return runs
	}

	func turns(_ behavior: Behavior, in scenario: String, _ steps: PlanCoachSteps) -> [String:
		[PlanScript.Step]]
	{
		switch behavior {
		case .faithful:
			return [
				LivePlanScenarios.feasibility: steps.feasibility, "/plan": steps.asks,
				inWords: steps.draft, LivePlanScenarios.save: steps.asksToSave,
				LivePlanScenarios.load: steps.load, LivePlanScenarios.revision: steps.revision,
			]
		case .stray:
			return [
				LivePlanScenarios.feasibility: steps.roundsFeasibility,
				"/plan": steps.buildsWithoutAsking,
				inWords: scenario == "plan-in-words" ? steps.draftSavedUnasked : steps.draft,
				LivePlanScenarios.save: steps.savesTwiceAndClaims,
				LivePlanScenarios.load: steps.loadsWithoutName,
				LivePlanScenarios.revision: steps.revisionSaved,
			]
		}
	}
}
