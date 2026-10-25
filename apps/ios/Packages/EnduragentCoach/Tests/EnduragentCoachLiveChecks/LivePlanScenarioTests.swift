import EnduragentCoachFixtures
import Foundation
import Synchronization
import Testing

@testable import EnduragentCoach

@Suite struct LivePlanScenarioTests {
	@Test func aCoachThatFollowsThePlanningSetPassesAndSavesTheDraftItShowed() async throws {
		let rig = PlanBenchRig()

		let runs = try await rig.runAll(.faithful)

		#expect(
			runs.map(\.violations) == [[], [], [], []],
			"\(runs.map(\.transcript).joined(separator: "\n"))")
		let saveAndLoad = try #require(runs.last)
		#expect(saveAndLoad.turns.map { $0.tap?.saved } == [nil, true, nil, nil])
		let saved = try #require(saveAndLoad.turns.dropFirst().first?.savedAfter)
		#expect(saveAndLoad.turns.first?.savedAfter == nil)
		#expect(
			saveAndLoad.turns.dropFirst(2).map(\.savedAfter?.digest) == [
				saved.digest, saved.digest,
			])
	}

	@Test func aCoachThatStraysFromThePlanningSetFailsEachExpectationItBreaks() async throws {
		let rig = PlanBenchRig()

		let runs = try await rig.runAll(.stray)

		#expect(
			runs.first?.violations == [
				"turn 1: the reply drops realisticMilestone 240; the reply drops estimatedCycles 2"
			])
		#expect(
			runs.dropFirst().first?.violations == [
				"turn 1: build_plan_skeleton was called", "turn 1: the reply does not mention ?",
			])
		let inWords = try #require(runs.dropFirst(2).first?.violations)
		#expect(inWords.count == 4)
		#expect(inWords.first?.hasPrefix("turn 1: the reply drops zoneTables.zones.range ") == true)
		#expect(
			Array(inWords.dropFirst()) == [
				"turn 1: plan_save was called", #"turn 1: the reply claims a save: "is saved""#,
				"turn 1: plan_save was called",
			])
		let name = try #require(
			runs.last?.turns.dropFirst(2).first?.savedAfter?.value.objectFields["name"]?.stringValue
		)
		#expect(
			runs.last?.violations == [
				"turn 2: plan_save was called 2 times, not once",
				"turn 2: the plan sent to plan_save differs from the draft in phases",
				#"turn 2: the reply claims a save: "is saved""#,
				"turn 2: the reply does not mention Save plan",
				#"turn 3: the reply does not hold the saved plan's name "\#(name)""#,
				"turn 4: plan_save was called; a plan card waits",
			])
	}

	@Test func aTurnThatChangesTheSavedPlanOrLeavesACardWithoutPlanSaveFailsItsCheck()
		async throws
	{
		let rig = PlanBenchRig()
		let base = "Save the base plan."
		let other = "Save the threshold plan instead."
		let waiting = "Draft one more without saving."
		let thanks = "Thanks."
		let scenario = LiveScenario(
			name: "saved-plan-guards", setting: .connected,
			turns: [
				LiveTurnPlan(message: base, expectations: [], tapsSavePlan: true),
				LiveTurnPlan(
					message: other, expectations: [.plan(.keepsSavedPlan)], tapsSavePlan: true),
				LiveTurnPlan(message: waiting, expectations: []),
				LiveTurnPlan(message: thanks, expectations: [.plan(.leavesNoCard)]),
			])

		let run = try await rig.run(scenario) { steps in
			[
				base: [steps.build, steps.save(), PlanCoachSteps.reply(PlanCoachSteps.showsCard)],
				other: [
					steps.save(changing: PlanCoachSteps.droppingLastPhase),
					PlanCoachSteps.reply(PlanCoachSteps.showsCard),
				],
				waiting: [steps.save(), PlanCoachSteps.reply(PlanCoachSteps.showsCard)],
				thanks: [PlanCoachSteps.reply("Glad to help.")],
			]
		}

		#expect(
			run.violations == [
				"turn 2: plan_save was called; a plan card waits; the saved plan changed",
				"turn 4: a plan card is shown",
			])
		#expect(run.turns.map { $0.tap?.saved } == [true, true, nil, nil])
	}

	@Test func thePlanSuiteRerunsAFailedScenarioAndReportsItsM5SpendBeforeAndAfter()
		async throws
	{
		let suite = try PlanSuiteRig(price: 0.01)
		let earlier = [
			"1998-06-12T08:00:00Z\tstatus#1\tmodel-a\t900\t80\t2.500000\treported\t2.500000",
			"1998-06-13T08:00:00Z\tzones#2\tmodel-a\t0\t0\t7.100000\tbound\t9.600000",
		]
		try suite.seed([LiveSpendLedger.earlierHeader] + earlier)

		let run = try await suite.run { steps in
			[
				LivePlanScenarios.feasibility: [steps.roundsFeasibility, steps.feasibility],
				"/plan": [steps.leaksTheKey],
				suite.rig.inWords: [steps.draft], LivePlanScenarios.save: [steps.asksToSave],
				LivePlanScenarios.load: [steps.load], LivePlanScenarios.revision: [steps.revision],
			]
		}

		let sent = suite.model.requestCount
		let rows = try suite.rows()
		#expect(Array(rows.prefix(2)) == earlier.map { $0 + "\tm4" })
		#expect(rows.count == 2 + sent)
		#expect(rows.dropFirst(2).allSatisfy { $0.hasSuffix("\tm5") })
		#expect(
			suite.said == [
				"Model spend total for m5: $0.000000 of $5.00.",
				"Model spend total for m5: "
					+ String(format: "$%.6f of $5.00.", Double(sent) * suite.price),
			])
		let summary = try String(
			contentsOf: run.folder.run.appending(path: "summary.md"), encoding: .utf8)
		#expect(summary.hasPrefix("# Live planning suite\n\nSpend for m5: $"))
		#expect(
			summary.contains(
				"""
				| feasibility | fail | pass | flaky: failed once, passed on the rerun |
				| plan-without-details | fail | fail | fail: failed twice |
				| plan-in-words | pass | not run | pass |
				| save-and-load | pass | not run | pass |
				"""))
		#expect(run.folder.run.deletingLastPathComponent().lastPathComponent == "plan")
		#expect(
			try FileManager.default.contentsOfDirectory(atPath: run.folder.run.path).sorted() == [
				"feasibility-run1.md", "feasibility-run2.md", "plan-in-words-run1.md",
				"plan-without-details-run1.md", "plan-without-details-run2.md",
				"save-and-load-run1.md", "summary.md",
			])
		let refused =
			"run 1: turn 1: build_plan_skeleton was called; run 1: turn 1: the reply does not mention ?; run 2: turn 1: build_plan_skeleton was called; run 2: turn 1: the reply does not mention ?"
		#expect(
			run.failures == [
				"plan-without-details: \(refused)",
				"plan-without-details-run1.md: the saved file holds the key of enduragent-m3-openrouter-key",
				"plan-without-details-run2.md: the saved file holds the key of enduragent-m3-openrouter-key",
			])
	}

	@Test func thePlanSuiteRefusesTheCallThatWouldTakeM5PastFiveDollarsBeforeSendingIt()
		async throws
	{
		let suite = try PlanSuiteRig(price: 0.3)
		try suite.seed([
			LiveSpendLedger.header,
			"1998-06-12T08:00:00Z\tstatus#1\tmodel-a\t900\t80\t9.600000\treported\t9.600000\tm4",
			"1998-06-13T08:00:00Z\tfeasibility#1\tmodel-a\t900\t80\t4.000000\treported\t4.000000\tm5",
		])

		let run = try await suite.run { steps in
			[
				LivePlanScenarios.feasibility: [steps.feasibility], "/plan": [steps.asks],
				suite.rig.inWords: [steps.draft], LivePlanScenarios.save: [steps.asksToSave],
				LivePlanScenarios.load: [steps.load], LivePlanScenarios.revision: [steps.revision],
			]
		}

		let sent = suite.model.requestCount
		let added = try suite.rows().dropFirst(2)
		#expect(sent >= 1)
		#expect(added.count == sent)
		#expect(added.allSatisfy { $0.hasSuffix("\tm5") })
		let total = try LiveSpendLedger(file: suite.spend, milestone: .m5, limit: 5).total
		#expect(abs(total - (4 + Double(sent) * suite.price)) < 1e-9)
		#expect(total <= 5)
		#expect(
			suite.said.first == "Model spend total for m5: $4.000000 of $5.00.")
		#expect(suite.said.last?.hasSuffix("; the cap stopped the suite.") == true)
		#expect(run.failures.last?.hasPrefix("The spend cap stopped the suite") == true)
		#expect(LiveCheck.plan.spend?.milestone == .m5)
		#expect(LiveCheck.plan.spend?.limit == 5)
		#expect(LiveCheck.coach.spend?.milestone == .m4)
		#expect(LiveCheck.coach.spend?.limit == 10)
	}
}

final class PlanSuiteRig: Sendable {
	let rig = PlanBenchRig()
	let price: Double
	let logs: URL
	let model = FakeModelTransport()
	private let lines = Mutex<[String]>([])

	init(price: Double) throws {
		self.price = price
		logs = try TestTemporaryFolders.make()
		model.finishUsage = Usage(inputTokens: 900, outputTokens: 80, cost: price)
	}

	var spend: URL { logs.appending(path: "spend.tsv") }
	var said: [String] { lines.withLock { $0 } }

	func seed(_ rows: [String]) throws {
		try FileManager.default.createDirectory(at: logs, withIntermediateDirectories: true)
		try Data(rows.map { $0 + "\n" }.joined().utf8).write(to: spend)
	}

	func rows() throws -> [String] {
		try String(contentsOf: spend, encoding: .utf8).split(separator: "\n").dropFirst().map(
			String.init)
	}

	func run(_ turns: (PlanCoachSteps) -> [String: [[PlanScript.Step]]]) async throws
		-> LiveSuiteRun
	{
		let drafts = PlanDrafts()
		model.respond =
			PlanScript(turns(PlanCoachSteps(today: rig.today, drafts: drafts)), drafts: drafts)
			.respond
		let (logs, model, account) = (logs, model, rig.account)
		let suite = LiveCoachSuite(
			lookUp: { key in
				KeychainLookup(
					status: 0,
					output: Data(
						(key == .intervals ? "synthetic-intervals-key" : "synthetic-openrouter-key")
							.utf8))
			},
			folder: { check, started in
				try LiveRunFolder(logs: logs, kind: check, startedAt: started)
			},
			modelTransport: { _ in model }, accountReads: { _, _ in account },
			say: { [self] line in lines.withLock { $0.append(line) } })
		return try await suite.run(
			LivePlanScenarios.planned, check: .plan, title: LivePlanScenarios.title)
	}
}
