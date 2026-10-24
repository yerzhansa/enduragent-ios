import EnduragentCoachFixtures
import Foundation
import Testing

@testable import EnduragentCoach

@Suite struct PlanHeadlineParityTests {
	static let npmNoPlanContextOfSystemPromptLine25 = "## Current Plan\nNo plan saved yet."

	let clock = FixedClock(now: "1998-06-13T08:00:00+02:00", timeZone: "Europe/Amsterdam")

	@Test func everyHeadlineAndPlanLoadResultIsNpmsForEveryPlanThePhoneCanSave() async throws {
		var compared = 0
		var saved = 0
		var refused = 0
		var none = 0
		var mismatched: [String] = []
		for item in try PlanFixtures.cases("headline") {
			compared += 1
			let npm = try #require(item.output?.objectFields)
			let npmContext = try #require(npm["context"]?.stringValue)
			let npmPlanLoad = try #require(npm["planLoad"])
			let store = InMemoryRecordLog()
			if let plan = item.input.objectFields["plan"] {
				switch Result(catching: { () throws(ToolInputError) in
					try PlanDocument.parse(arguments: item.input)
				}) {
				case .success:
					saved += 1
					try await seed(store, [savedPlanRow(plan, on: store.deviceId)])
				case .failure(let refusal):
					refused += 1
					if refusal.code != "invalid_plan" { mismatched.append(item.id) }
					continue
				}
			} else {
				none += 1
				if !npmContext.isEmpty { mismatched.append(item.id) }
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
		#expect(compared > 0)
		#expect(saved > 0)
		#expect(refused > 0)
		#expect(none > 0)
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
