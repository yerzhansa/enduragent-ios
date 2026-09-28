import Foundation
import Testing

@testable import EnduragentCoach

extension TurnEvidenceTests {
	@Test func evidenceDiagnosticsExcludePrivateURL() async throws {
		let url = try #require(
			URL(
				string:
					"https://intervals.icu/api/v1/athlete/i424242/wellness?oldest=1998-06-07&newest=1998-06-13"
			))
		intervals.loadFailure = URLError(.timedOut, userInfo: [NSURLErrorFailingURLErrorKey: url])
		transport.script = [.text("Easy spin today."), .finish(reason: .stop)]
		let coach = makeCoach(
			transport: transport, intervals: intervals, store: InMemoryRecordLog(), clock: clock)
		_ = try await coach.sendAndSettle("How is my form?")
		let entry = try #require(coach.diagnostics.entries.first)
		let detail = String(describing: entry.event)
		#expect(detail.contains("temporarilyUnavailable"))
		#expect(!detail.contains("i424242"))
		#expect(!detail.contains("1998-06-07"))
		#expect(!detail.contains("1998-06-13"))
		#expect(!detail.contains("intervals.icu"))
		let system = try #require(transport.requests.first?.messages.first?.content)
		#expect(!system.contains("i424242"))
	}

}
