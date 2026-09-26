import Foundation

enum ToolFault: String {
	case saveFailed = "save_failed"
	case toolFailed = "tool_failed"

	init(_ error: any Error) {
		self = error is LedgerFailure ? .saveFailed : .toolFailed
	}

	var json: JSONValue {
		.object(["error": .string(rawValue), "details": .string(details)])
	}

	private var details: String {
		switch self {
		case .saveFailed: PromptStaticBlocks.toolSaveFailure
		case .toolFailed: PromptStaticBlocks.toolFailure
		}
	}
}
