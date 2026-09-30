import Foundation
import Testing

@testable import EnduragentCoach

@Suite struct OpenRouterLiveTests {
	@Test(.enabled(if: ProcessInfo.processInfo.environment["OPENROUTER_API_KEY"] != nil))
	func streamsOneTurn() async throws {
		let apiKey = try #require(ProcessInfo.processInfo.environment["OPENROUTER_API_KEY"])
		let request = CompletionRequest(
			access: ResolvedAccess(
				credential: ProviderCredential(secret: apiKey, method: .credits),
				model: ModelID(rawValue: "deepseek/deepseek-v4.1-flash-20260910")),
			attempt: AttemptID(ulid: fixedUlid(1)),
			charge: .chatAttempt,
			messages: [
				WireMessage(
					role: .user,
					content: "Reply with the single word pong.",
					toolCalls: [],
					toolCallId: nil
				)
			],
			tools: [
				ToolSchema(
					name: .intervalsFetchAthlete,
					description: "Fetch the athlete profile.",
					parameters: .object([
						"type": .string("object"),
						"properties": .object([:]),
					])
				)
			],
			deadline: .seconds(60)
		)
		let transport = OpenRouterTransport(
			baseURL: ModelService.openRouterAPI,
			diagnostics: DiagnosticsLog(clock: SystemClock()))
		let events = try await collect(transport.stream(request))
		#expect(!events.isEmpty)
		if case .finished(_, let usage) = events.last {
			#expect(usage.inputTokens > 0)
		} else {
			Issue.record("expected finished")
		}
		if let path = ProcessInfo.processInfo.environment["ENDURAGENT_LIVE_OUT"], !path.isEmpty {
			let payload: [String: Any] = ["events": events.map(json(event:))]
			let data = try JSONSerialization.data(
				withJSONObject: payload, options: [.prettyPrinted, .sortedKeys])
			try data.write(to: URL(fileURLWithPath: path))
		}
	}
}

private func json(event: TransportEvent) -> [String: Any] {
	switch event {
	case .textDelta(let text):
		return ["type": "textDelta", "text": text]
	case .toolCall(let call):
		return [
			"type": "toolCall",
			"id": call.id,
			"name": call.name,
			"arguments": call.arguments,
		]
	case .heartbeat:
		return ["type": "heartbeat"]
	case .finished(let reason, let usage):
		var payload: [String: Any] = [
			"type": "finished",
			"reason": reason.rawValue,
			"usage": [
				"inputTokens": usage.inputTokens,
				"outputTokens": usage.outputTokens,
			],
		]
		if let cost = usage.cost {
			var usageObject = payload["usage"] as? [String: Any] ?? [:]
			usageObject["cost"] = cost
			payload["usage"] = usageObject
		}
		return payload
	}
}
