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
	public let retry: Bool
	public let purpose: Purpose
	public let step: Int

	package init(request: CompletionRequest, purpose: Purpose, step: Int) {
		self.text =
			request.messages.last { $0.role == .user }?.content
			.components(separatedBy: "\nCurrent time:")[0] ?? ""
		self.retry = request.origin == .retry
		self.purpose = purpose
		self.step = step
	}
}
