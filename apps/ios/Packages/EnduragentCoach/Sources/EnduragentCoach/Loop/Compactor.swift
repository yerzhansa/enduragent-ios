import Foundation

struct Compactor: Sendable {
	enum Purpose: Sendable {
		case droppedHistory
		case inTurn
	}

	struct Summary: Sendable {
		let markdown: String

		fileprivate init(_ step: GenerateStep) throws(Failure) {
			guard step.reason != .error, step.reason != .contentFilter,
				!step.text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
			else {
				throw Failure(reason: step.reason)
			}
			markdown = step.text
		}
	}

	struct Failure: Error, Sendable {
		let reason: FinishReason
	}

	let modelCall: ModelCall

	func summarize(
		_ messages: [WireMessage], previous: String?, purpose: Purpose, attempt: TurnAttempt
	) async throws -> Summary {
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
		let step = try await modelCall.run(
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
		)
		return try Summary(step)
	}
}
