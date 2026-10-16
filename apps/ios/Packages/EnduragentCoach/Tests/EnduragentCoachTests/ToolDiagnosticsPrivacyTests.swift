import EnduragentCoachFixtures
import Foundation
import Testing

@testable import EnduragentCoach

extension TurnRunnerTests {
	@Test func toolDiagnosticsExcludePrivateURL() async throws {
		let url = try #require(
			URL(
				string:
					"https://intervals.icu/api/v1/athlete/i1001/wellness?oldest=1998-06-07&newest=1998-06-13"
			))
		intervals.fail(
			.wellness, with: URLError(.timedOut, userInfo: [NSURLErrorFailingURLErrorKey: url]))
		transport.respond = ScriptedReply.sequence(
			[
				.toolCall(name: "intervals_fetch_wellness", arguments: #"{"oldest":"1998-06-07"}"#),
				.finish(reason: .toolCalls),
				.text("I could not read your wellness data."),
				.finish(reason: .stop),
			], otherwise: transport.respond)
		let coach = await EnduragentCoachTests.makeCoach(
			transport: transport, intervals: intervals, store: store, clock: clock)
		let settled = try await coach.sendAndSettle("How am I recovering?")
		#expect(replyText(settled) == "I could not read your wellness data.")
		try #require(
			coach.diagnostics.entries.contains {
				if case .toolFailed(_, .intervalsFetchWellness, _) = $0.event { return true }
				return false
			})
		let text = coach.diagnostics.entries.map { String(describing: $0.event) }
			.joined(separator: "\n")
		#expect(!text.contains("i1001"), "\(text)")
		#expect(!text.contains("intervals.icu/api"), "\(text)")
		#expect(!text.contains("1998-06-07"))
		#expect(!text.contains("1998-06-13"))
	}
}
