import EnduragentCoachFixtures
import Foundation
import Testing

@testable import EnduragentCoach

@Suite struct PlanHeadlineParityTests {
	static let npmNoPlanContextOfSystemPromptLine25 = "## Current Plan\nNo plan saved yet."

	let clock = FixedClock(now: "1998-06-13T08:00:00+02:00", timeZone: "Europe/Amsterdam")

	@Test func everyPlanZodAcceptsShowsNpmsHeadlineAndPlanLoadAndEveryPlanZodRefusesIsRefused()
		async throws
	{
		var compared = 0
		var zodAccepted = 0
		var zodRefused = 0
		var phoneSaved = 0
		var phoneRefused = 0
		var none = 0
		var mismatched: [String] = []
		for item in try PlanFixtures.cases("headline") {
			compared += 1
			let npm = try #require(item.output?.objectFields)
			let npmContext = try #require(npm["context"]?.stringValue)
			let npmPlanLoad = try #require(npm["planLoad"])
			let store = InMemoryRecordLog()
			switch (item.input.objectFields["plan"], npm["accepted"]) {
			case (nil, nil):
				none += 1
				if !npmContext.isEmpty { mismatched.append("\(item.id): npm shows a plan") }
			case (let plan?, .bool(let accepted)?):
				if accepted { zodAccepted += 1 } else { zodRefused += 1 }
				switch Result(catching: { () throws(ToolInputError) in
					try PlanDocument.parse(arguments: item.input)
				}) {
				case .success where accepted:
					phoneSaved += 1
					try await seed(store, [savedPlanRow(plan, on: store.deviceId)])
				case .success:
					phoneSaved += 1
					mismatched.append("\(item.id): zod refuses the plan the phone saves")
					continue
				case .failure(let refusal):
					phoneRefused += 1
					if accepted {
						mismatched.append("\(item.id): zod accepts the plan the phone refuses")
					} else if refusal.code != "invalid_input" {
						mismatched.append("\(item.id): refused with \(refusal.code)")
					}
					continue
				}
			default:
				mismatched.append("\(item.id): the fixture records no verdict for this plan")
				continue
			}
			let phone = try await read(store)
			let expectedContext =
				npmContext.isEmpty ? Self.npmNoPlanContextOfSystemPromptLine25 : npmContext
			if phone.context != expectedContext || phone.planLoad != npmPlanLoad {
				mismatched.append("\(item.id): \(phone.context) \(canonicalJSON(phone.planLoad))")
			}
		}
		#expect(mismatched.isEmpty, "\(mismatched.prefix(3))")
		#expect(compared == (try PlanFixtures.manifestCount(["headline"])))
		#expect(compared == zodAccepted + zodRefused + none)
		#expect(phoneSaved == zodAccepted)
		#expect(phoneRefused == zodRefused)
		#expect(zodAccepted > 0)
		#expect(zodRefused > 0)
		#expect(none == 1)
	}

	private func read(_ store: InMemoryRecordLog) async throws -> (
		context: String, planLoad: JSONValue
	) {
		let ledger = Ledger(log: store, clock: clock, diagnostics: DiagnosticsLog(clock: clock))
		let context = try await Memory(ledger: ledger, clock: clock).prompt(for: .unconnected)
			.context
		let execution = try await makeOfferedTools(
			intervals: FakeIntervalsClient(athleteName: "Ada", ftp: 250), ledger: ledger,
			clock: clock
		).execute(
			name: .planLoad, arguments: .object([:]),
			scope: TurnScope(stamp: testStamp(), policy: .npm, ladder: .npm, uptime: .zero))
		guard case .result(let envelope) = execution.outcome else {
			throw PlanFixtureFailure(description: "plan_load answered \(execution.outcome)")
		}
		return (context, try #require(envelope.objectFields["data"]))
	}

	private func savedPlanRow(_ plan: JSONValue, on device: DeviceID) throws -> AthleteRecord {
		storedRecord(
			device: device, wall: 1, ulid: fixedUlid(9),
			body: try SavedPlanRows.body(plan))
	}
}
