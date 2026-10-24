import EnduragentCoachFixtures
import Testing

@testable import EnduragentCoach

@Suite struct PlanToolInputTests {
	let clock = FixedClock(now: "1998-06-13T08:00:00+02:00", timeZone: "Europe/Amsterdam")

	@Test func everyRecordedCallGetsZodsVerdictAndNpmsResult() async throws {
		let tools: [ToolName] = [.assessFeasibility, .buildPlanSkeleton, .getSampleWeek, .planLoad]
		let offered = makeOfferedTools(
			intervals: FakeIntervalsClient(athleteName: "Ada", ftp: 250),
			ledger: Ledger(
				log: InMemoryRecordLog(), clock: clock, diagnostics: DiagnosticsLog(clock: clock)),
			clock: clock)
		var compared: [ToolName: Int] = [:]
		var mismatched: [String] = []
		var notices: Set<String> = []
		for item in try PlanFixtures.cases("tool-inputs") {
			guard let tool = tools.first(where: { $0.rawValue == item.tool }) else { continue }
			compared[tool, default: 0] += 1
			let verdict = try #require(item.output?.objectFields)
			let answer = try await result(
				of: offered.execute(
					name: tool, arguments: item.input,
					scope: TurnScope(stamp: testStamp(), policy: .npm, ladder: .npm, uptime: .zero))
			)
			let matches =
				switch (verdict["accepted"], verdict["result"]) {
				case (.bool(false), nil):
					answer.objectFields["error"] == .string("invalid_input")
				case (.bool(true), let npm?):
					answer == npm
				case (.bool(true), nil):
					tool == .buildPlanSkeleton && answer.objectFields["error"] == nil
						&& answer.objectFields["status"] == .string("draft")
				default:
					false
				}
			if !matches {
				mismatched.append("\(item.id): \(canonicalJSON(answer))")
			}
			if let notice = answer.objectFields["error"] ?? answer.objectFields["message"],
				let text = notice.stringValue
			{
				notices.insert(text)
			}
		}
		#expect(
			mismatched.isEmpty,
			"\(mismatched.count) calls differ from zod and npm, first: \(mismatched.prefix(3))")
		#expect(
			notices == [
				"invalid_input", "invalid_date", "Goal appears achievable within one plan cycle.",
				"No plan saved yet.",
			])
		for tool in tools {
			let recorded = try PlanFixtures.manifestCount("tool-inputs", tool: tool.rawValue)
			#expect(compared[tool] == recorded, "\(tool)")
			#expect(recorded > 0, "\(tool)")
		}
	}

	private func result(of execution: ToolExecution) throws -> JSONValue {
		guard case .result(let envelope) = execution.outcome else {
			throw PlanFixtureFailure(description: "the tool answered \(execution.outcome)")
		}
		return try #require(envelope.objectFields["data"])
	}
}
