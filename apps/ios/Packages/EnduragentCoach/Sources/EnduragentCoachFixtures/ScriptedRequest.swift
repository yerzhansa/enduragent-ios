import EnduragentCoach
import Foundation

public struct ScriptedRequest: Sendable {
	public enum Purpose: Sendable, Hashable {
		case chat
		case summary
		case flush

		package init(_ charge: GenerateCharge) {
			switch charge {
			case .chatAttempt, .stepRecovery: self = .chat
			case .compaction, .droppedSummary: self = .summary
			case .memoryFlush: self = .flush
			}
		}
	}

	public let text: String
	public let userMessages: [String]
	public let retry: Bool
	public let purpose: Purpose
	public let step: Int
	public let toolResults: [String]

	package init(
		request: CompletionRequest, context: CompletionRequest, purpose: Purpose, step: Int
	) {
		self.toolResults = request.messages.filter { $0.role == .tool }.map(\.content)
		self.userMessages = context.messages.filter { $0.role == .user }.map(\.content)
		self.text =
			context.messages.last { $0.role == .user }?.content
			.components(separatedBy: "\nCurrent time:")[0] ?? ""
		self.retry = context.origin == .retry
		self.purpose = purpose
		self.step = step
	}
}
