import Foundation

struct FailurePayload: Codable {
	var domain: String
	var code: String
	var detail: String?

	init(_ failure: CoachFailure) {
		switch failure {
		case .model(let model):
			domain = "model"
			(code, detail) = Self.stored(model)
		case .local(let local):
			domain = "local"
			code = local.rawValue
		}
	}

	private static func stored(_ failure: ModelFailure) -> (code: String, detail: String?) {
		switch failure {
		case .credentialRejected(let method):
			return ("credentialRejected", method.rawValue)
		case .accessExhausted(let method):
			return ("accessExhausted", method.rawValue)
		case .rateLimited(let wait):
			return ("rateLimited", wait.map { String(milliseconds($0)) })
		case .providerDown(let trouble):
			return ("providerDown", trouble.rawValue)
		case .contextOverflow:
			return ("contextOverflow", nil)
		case .invalidRequest:
			return ("invalidRequest", nil)
		case .generationFailed(let fault):
			return ("generationFailed", fault.rawValue)
		case .budgetExhausted(let kind):
			return ("budgetExhausted", kind.rawValue)
		case .accessUnavailable(.notConfigured(let method)):
			return ("accessUnavailable", Self.notConfiguredPrefix + method.rawValue)
		case .accessUnavailable(.secureStorageLocked):
			return ("accessUnavailable", "secureStorageLocked")
		case .accessUnavailable(.secureStorageUnavailable):
			return ("accessUnavailable", "secureStorageUnavailable")
		}
	}

	private static let notConfiguredPrefix = "notConfigured."

	func failure() throws -> CoachFailure {
		switch (domain, code) {
		case ("model", "credentialRejected"):
			return .model(.credentialRejected(try method()))
		case ("model", "accessExhausted"):
			return .model(.accessExhausted(try method()))
		case ("model", "rateLimited"):
			guard let detail else {
				return .model(.rateLimited(retryAfter: nil))
			}
			guard let milliseconds = Int64(detail) else {
				throw RecordDecodeFailure(reason: "failure")
			}
			return .model(.rateLimited(retryAfter: .milliseconds(milliseconds)))
		case ("model", "providerDown"):
			guard let trouble = detail.flatMap(ProviderTrouble.init(rawValue:)) else {
				throw RecordDecodeFailure(reason: "failure")
			}
			return .model(.providerDown(trouble))
		case ("model", "contextOverflow"):
			return .model(.contextOverflow)
		case ("model", "invalidRequest"):
			return .model(.invalidRequest)
		case ("model", "accessUnavailable"):
			return .model(.accessUnavailable(try accessUnavailable()))
		case ("model", "generationFailed"):
			guard let fault = detail.flatMap(GenerationFault.init(rawValue:)) else {
				throw RecordDecodeFailure(reason: "failure")
			}
			return .model(.generationFailed(fault))
		case ("model", "budgetExhausted"):
			guard let kind = detail.flatMap(TurnBudgetExceeded.Kind.init(rawValue:)) else {
				throw RecordDecodeFailure(reason: "failure")
			}
			return .model(.budgetExhausted(kind))
		case ("local", _):
			guard let local = LocalFailure(rawValue: code) else {
				throw RecordDecodeFailure(reason: "failure")
			}
			return .local(local)
		default:
			throw RecordDecodeFailure(reason: "failure")
		}
	}

	private func method() throws -> AccessMethod {
		guard let method = detail.flatMap(AccessMethod.init(rawValue:)) else {
			throw RecordDecodeFailure(reason: "failure")
		}
		return method
	}

	private func accessUnavailable() throws -> AccessUnavailable {
		switch detail {
		case "secureStorageLocked":
			return .secureStorageLocked
		case "secureStorageUnavailable":
			return .secureStorageUnavailable
		case let stored? where stored.hasPrefix(Self.notConfiguredPrefix):
			guard
				let method = AccessMethod(
					rawValue: String(stored.dropFirst(Self.notConfiguredPrefix.count)))
			else {
				throw RecordDecodeFailure(reason: "failure")
			}
			return .notConfigured(method)
		default:
			throw RecordDecodeFailure(reason: "failure")
		}
	}
}

private func milliseconds(_ duration: Duration) -> Int64 {
	duration.components.seconds * 1_000
		+ duration.components.attoseconds / 1_000_000_000_000_000
}
