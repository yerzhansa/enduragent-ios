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
	}
}
