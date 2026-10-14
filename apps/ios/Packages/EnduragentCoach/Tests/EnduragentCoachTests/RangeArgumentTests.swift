import EnduragentCoachFixtures
import Foundation
import Testing

@testable import EnduragentCoach

@Suite struct RangeArgumentTests {
	let intervals = FakeIntervalsClient(athleteName: "Ada Kovač", ftp: 250)
	let clock = FixedClock(now: "1998-06-13T08:00:00+02:00", timeZone: "Europe/Amsterdam")

	@Test(arguments: [
		(
			ToolName.intervalsFetchActivities,
			FakeIntervalsCall.activities(oldest: "1998-06-12", newest: "1998-06-13")
		),
		(.intervalsFetchWellness, .wellness(oldest: "1998-06-12", newest: "1998-06-13")),
		(.intervalsListEvents, .events(oldest: "1998-06-12", newest: "1998-06-13")),
	])
	func nullNewestIsReadAsOmitted(tool: ToolName, call: FakeIntervalsCall) async throws {
		let shown = try await read(tool, #"{"oldest":"1998-06-12","newest":null}"#)
		#expect(shown.objectFields["error"] == nil, "\(canonicalJSON(shown))")
		#expect(intervals.calls == [call])
	}

	@Test(
		arguments: [ToolName.intervalsFetchActivities, .intervalsListEvents],
		[
			(
				#"{"oldest":"1998-06-13","newest":"1998-06-07"}"#,
				#"{"error":"invalid_range","details":"oldest (1998-06-13) is after newest (1998-06-07). Swap the bounds."}"#
			),
			(
				#"{"oldest":"1997-06-12"}"#,
				#"{"error":"range_too_wide","details":"Range is 367 days; the maximum is 366. Fetch the range in chunks of at most 366 days."}"#
			),
		])
	func rangeRefusalTellsTheCoachHowToAskAgain(tool: ToolName, refusal: (String, String))
		async throws
	{
		#expect(try await read(tool, refusal.0) == (try JSONValue.parse(refusal.1)))
		#expect(intervals.calls.isEmpty)
	}

	private func read(_ tool: ToolName, _ arguments: String) async throws -> JSONValue {
		let outcome = try await makeOfferedTools(
			intervals: intervals,
			ledger: Ledger(
				log: InMemoryRecordLog(), clock: clock, diagnostics: DiagnosticsLog(clock: clock)),
			clock: clock
		).execute(
			name: tool, arguments: try JSONValue.parse(arguments),
			scope: TurnScope(stamp: testStamp(), policy: .npm, ladder: .npm, uptime: .zero)
		).outcome
		guard case .result(let json) = outcome else {
			throw IntervalsError(code: "no_result", details: "\(outcome)")
		}
		return try #require(json.objectFields["data"])
	}
}
