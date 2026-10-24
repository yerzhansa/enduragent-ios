import EnduragentCoachFixtures
import Foundation
import Testing

@testable import EnduragentCoach

extension TurnRunnerTests {
	@Test(arguments: [
		"build_plan_skeleton", "assess_feasibility", "get_sample_week", "plan_load",
		"invented_tool", "memory_read", "plan_save", "intervals_create_workout",
		"intervals_create_strength_workout", "intervals_delete_workout", "intervals_update_workout",
	])
	func unofferedToolCallsReturnUnknownTool(name: String) async throws {
		transport.respond = ScriptedReply.sequence(
			[
				.toolCall(name: name, arguments: "{}"), .finish(reason: .toolCalls),
				.text("That tool is unavailable."), .finish(reason: .stop),
			], otherwise: transport.respond)
		let coach = await makeCoach()
		let settled = try await coach.sendAndSettle("Help me plan")
		#expect(replyText(settled) == "That tool is unavailable.")
		#expect(transport.requests.count == 2)
		let first = try #require(transport.requests.first)
		#expect(!first.tools.contains { $0.name.rawValue == name })
		let next = try #require(transport.requests.last)
		let call = try #require(next.messages.flatMap(\.toolCalls).first)
		let result = try #require(next.messages.last { $0.role == .tool })
		#expect(call.name == name)
		#expect(result.toolCallId == call.id)
		#expect(
			try JSONValue.parse(result.content).objectFields["error"] == .string("unknown_tool"))
		#expect(
			try await store.fetch(
				RecordQuery(scope: .synced([.memorySection, .ledgerEvent]))
			).records.isEmpty)
		#expect(
			try await store.fetch(RecordQuery(scope: .deviceLocal([.workoutReview]))).records
				.isEmpty)
	}

	@Test(arguments: ["1500-02-28", "1582-10-10", "0001-01-01"] as [CivilDate])
	func historicalDateKeysPassTheDateCheck(day: CivilDate) async throws {
		let result = try await toolResult(
			name: "intervals_fetch_activities",
			arguments: "{\"oldest\":\"\(day)\",\"newest\":\"\(day)\"}")
		#expect(result.objectFields["error"] == nil, "\(canonicalJSON(result))")
		#expect(activityLists() == [.activities(oldest: day, newest: day)])
	}

	@Test func aRangeAcrossYearZeroCountsEveryProlepticDay() async throws {
		let refused = try await toolResult(
			name: "intervals_fetch_activities",
			arguments: #"{"oldest":"0000-01-01","newest":"0001-01-01"}"#)
		#expect(
			refused
				== (try JSONValue.parse(
					#"{"error":"range_too_wide","details":"Range is 367 days; the maximum is 366. Fetch the range in chunks of at most 366 days."}"#
				)))
		#expect(activityLists().isEmpty)
		let read = try await toolResult(
			name: "intervals_fetch_activities",
			arguments: #"{"oldest":"0000-01-02","newest":"0001-01-01"}"#)
		#expect(read.objectFields["error"] == nil, "\(canonicalJSON(read))")
		#expect(activityLists() == [.activities(oldest: "0000-01-02", newest: "0001-01-01")])
	}

	@Test func promptOmitsUnavailableToolsAndKeepsNumberedChoiceSafetyRules() async throws {
		transport.respond = ScriptedReply.sequence(
			[.text("Ready."), .finish(reason: .stop)], otherwise: transport.respond)
		let settled = try await makeCoach().sendAndSettle("Help me plan")
		#expect(replyText(settled) == "Ready.")
		let request = try #require(transport.requests.first)
		let everyMessage = request.messages.map(\.content).joined(separator: "\n")
		#expect(!everyMessage.contains("plan_save"))
		#expect(!everyMessage.contains("request_user_decision"))
		let prompt = try #require(request.messages.first { $0.role == .system }?.content)
		#expect(
			prompt.contains(
				"Ask material choices between coaching or Plan directions as numbered text."))
		#expect(prompt.contains("Ask ordinary questions in text."))
		#expect(prompt.contains("Give 2–5 options"))
		#expect(prompt.contains("Never offer numbered choices for medical red flags"))
		#expect(
			prompt.contains(
				"never treat a chosen option as permission to mutate Plan, Calendar, or Training"))
		#expect(
			prompt.contains(
				"short label, one-sentence description, consequence, and recommendation flag"))
		#expect(prompt.contains("Recommend at most one."))
	}

	func activityLists() -> [FakeIntervalsCall] {
		intervals.calls.filter {
			guard case .activities = $0 else { return false }
			return true
		}
	}

	func toolResult(name: String, arguments: String) async throws -> JSONValue {
		transport.respond = ScriptedReply.sequence(
			[
				.toolCall(name: name, arguments: arguments), .finish(reason: .toolCalls),
				.text("Please correct the input."), .finish(reason: .stop),
			], otherwise: transport.respond)
		let settled = try await makeCoach().sendAndSettle("Check this input")
		#expect(replyText(settled) == "Please correct the input.")
		let next = try #require(transport.requests.last)
		let result = try #require(next.messages.last { $0.role == .tool })
		let json = try JSONValue.parse(result.content)
		return json.objectFields["data"] ?? json
	}
}
