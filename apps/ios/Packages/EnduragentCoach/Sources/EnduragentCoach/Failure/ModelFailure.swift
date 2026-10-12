import Foundation

public enum ModelFailure: Sendable, Equatable {
	case credentialRejected(AccessMethod)
	case requestBlocked
	case accessExhausted(AccessMethod)
	case rateLimited(retryAfter: Duration?)
	case providerDown(ProviderTrouble)
	case contextOverflow
	case invalidRequest
	case generationFailed(GenerationFault)
	case budgetExhausted(TurnBudgetExceeded.Kind)
	case accessUnavailable(AccessUnavailable)

	package init(_ failure: ProviderFailure, method: AccessMethod) {
		switch failure {
		case .credentialRejected:
			self = .credentialRejected(method)
		case .requestBlocked:
			self = .requestBlocked
		case .accessExhausted:
			self = .accessExhausted(method)
		case .rateLimited(let retryAfter):
			self = .rateLimited(retryAfter: retryAfter)
		case .serverError:
			self = .providerDown(.outage)
		case .network:
			self = .providerDown(.network)
		case .timeout:
			self = .providerDown(.timeout)
		case .contextOverflow:
			self = .contextOverflow
		case .invalidRequest:
			self = .invalidRequest
		case .unknownFinish:
			self = .generationFailed(.unknownFinish)
		case .malformedStream:
			self = .generationFailed(.malformedStream)
		}
	}
}
