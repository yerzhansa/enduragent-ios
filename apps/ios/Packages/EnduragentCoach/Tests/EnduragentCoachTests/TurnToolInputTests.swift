import EnduragentCoachFixtures
import Foundation
import Testing

@testable import EnduragentCoach

extension TurnRunnerTests {
	@Test(arguments: [
		"build_plan_skeleton", "assess_feasibility", "get_sample_week", "plan_load",
		"invented_tool", "memory_read", "plan_save",
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
			try await store.fetch(RecordQuery(scope: .deviceLocal([.pendingProposal]))).records
				.isEmpty)
	}

	@Test(arguments: [
		#"[{"type":"steady","duration":{"value":1.5e17,"unit":"minutes"}}]"#,
		#"[{"type":"steady","duration":{"value":86401,"unit":"seconds"}}]"#,
		#"[{"type":"steady","duration":{"value":1441,"unit":"minutes"}}]"#,
		#"[{"type":"steady","duration":{"value":1e20,"unit":"seconds"}}]"#,
		#"[{"type":"steady","duration":{"value":1e18,"unit":"minutes"}}]"#,
		#"[{"type":"steady","duration":{"value":1e308,"unit":"minutes"}}]"#,
		#"[{"type":"steady","duration":{"value":5e18,"unit":"seconds"}},{"type":"steady","duration":{"value":5e18,"unit":"seconds"}}]"#,
		#"[{"type":"set","repeat":20,"interval":{"type":"steady","duration":{"value":5e17,"unit":"seconds"}},"recovery":{"type":"rest","duration":{"value":30,"unit":"seconds"}}}]"#,
	])
	func oversizedWorkoutDurationsReturnErrors(steps: String) async throws {
		let result = try await toolResult(
			name: "intervals_create_workout",
			arguments:
				"{\"date\":\"1998-06-14\",\"workout\":{\"name\":\"Ride\",\"steps\":\(steps)}}")
		#expect(result.objectFields["error"] == .string("invalid_workout"))
		#expect(
			try await store.fetch(RecordQuery(scope: .deviceLocal([.pendingProposal]))).records
				.isEmpty)
	}

	@Test(arguments: [
		#"{"value":86400,"unit":"seconds"}"#,
		#"{"value":1440,"unit":"minutes"}"#,
	])
	func workoutDurationLimitRemainsProposable(duration: String) async throws {
		let result = try await toolResult(
			name: "intervals_create_workout",
			arguments:
				#"{"date":"1998-06-14","workout":{"name":"Ride","steps":[{"type":"steady","duration":\#(duration)}]}}"#
		)
		#expect(result.objectFields["pendingConfirmation"] == .bool(true))
		#expect(
			try await store.fetch(RecordQuery(scope: .deviceLocal([.pendingProposal]))).records
				.count == 1)
	}

	@Test(arguments: ["9e18", "4000000"])
	func excessiveDayCountsReturnRangeTooWide(days: String) async throws {
		let result = try await toolResult(
			name: "intervals_fetch_activities", arguments: "{\"days\":\(days)}")
		#expect(result.objectFields["error"] == .string("range_too_wide"))
	}

	@Test(arguments: ["1e20", "-1e20", "-5", "0", "1.5"])
	func invalidDayCountsIdentifyTheDaysValue(days: String) async throws {
		let result = try await toolResult(
			name: "intervals_fetch_activities", arguments: "{\"days\":\(days)}")
		#expect(result.objectFields["error"] == .string("invalid_input"))
		#expect(result.objectFields["details"] == .string("days must be a positive integer."))
	}

	@Test(arguments: ["1500-02-28", "1582-10-10", "0001-01-01"])
	func historicalDateKeysReturnInvalidDate(oldest: String) async throws {
		let result = try await toolResult(
			name: "intervals_fetch_activities",
			arguments: "{\"oldest\":\"\(oldest)\",\"newest\":\"\(oldest)\"}")
		#expect(result.objectFields["error"] == .string("invalid_date"))
	}

	@Test func promptDoesNotRequestUnavailableTools() async throws {
		transport.respond = ScriptedReply.sequence(
			[.text("Ready."), .finish(reason: .stop)], otherwise: transport.respond)
		let settled = try await makeCoach().sendAndSettle("Help me plan")
		#expect(replyText(settled) == "Ready.")
		let request = try #require(transport.requests.first)
		let prompt = request.messages.map(\.content).joined(separator: "\n")
		#expect(!prompt.contains("plan_save"))
		#expect(!prompt.contains("request_user_decision"))
	}

	@Test func promptPreservesNumberedChoiceSafetyRules() async throws {
		transport.respond = ScriptedReply.sequence(
			[.text("Ready."), .finish(reason: .stop)], otherwise: transport.respond)
		let settled = try await makeCoach().sendAndSettle("Help me plan")
		#expect(replyText(settled) == "Ready.")
		let request = try #require(transport.requests.first)
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

	private func toolResult(name: String, arguments: String) async throws -> JSONValue {
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
