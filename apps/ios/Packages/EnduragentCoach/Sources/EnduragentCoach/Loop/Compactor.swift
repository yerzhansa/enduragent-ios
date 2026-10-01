struct Compactor: Sendable {
	enum Purpose: Sendable {
		case droppedHistory
		case inTurn
	}

	let modelCall: ModelCall

	func summarize(
		_ messages: [WireMessage], previous: String?, purpose: Purpose, attempt: TurnAttempt
	) async throws -> String {
		let transcript = PromptAssembly.transcript(messages)
		let request: String
		let charge: GenerateCharge
		switch purpose {
		case .droppedHistory:
			request = PromptAssembly.droppedSummaryRequest(
				previous: previous, transcript: transcript)
			charge = .droppedSummary
		case .inTurn:
			request = PromptAssembly.compactionRequest(previous: previous, transcript: transcript)
			charge = .compaction
		}
		return try await modelCall.run(
			request: CompletionRequest(
				access: attempt.access.using(model: attempt.models.compaction),
				attempt: attempt.attempt,
				charge: charge,
				messages: [
					WireMessage(
						role: .system, content: PromptAssembly.compactionSystem, toolCalls: [],
						toolCallId: nil),
					WireMessage(role: .user, content: request, toolCalls: [], toolCallId: nil),
				],
				tools: [],
				deadline: TurnPolicy.compactionTimeout
			)
		).text
	}
}
