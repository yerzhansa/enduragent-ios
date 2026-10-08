import EnduragentCoach
import Foundation

public enum ScriptedEvent: Sendable, Equatable {
	case text(String)
	case toolCall(name: String, arguments: String)
	case finish(reason: FinishReason)
	case fail(ScriptedFailure)
	case hang
	case keepWorking
}

public struct ScriptedFailure: Sendable, Equatable {
	package let failure: ProviderFailure

	package init(_ failure: ProviderFailure) {
		self.failure = failure
	}

	public static func http(status: Int, headers: [String: String] = [:], body: String = "")
		-> ScriptedFailure
	{
		ScriptedFailure(ProviderFailure(status: status, headers: headers, body: body))
	}

	public static func connection(_ code: URLError.Code) -> ScriptedFailure {
		ScriptedFailure(ProviderFailure(URLError(code)))
	}

	public static let unknownFinish = ScriptedFailure(.unknownFinish)
}
