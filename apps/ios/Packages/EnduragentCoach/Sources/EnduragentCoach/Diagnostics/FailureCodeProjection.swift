import Foundation

extension FailureCode {
	package var code: ProblemCode {
		switch self {
		case .ledger(let failure): ProblemCode("ledger").then(failure.code)
		case .attempt(let failure): ProblemCode("attempt").then(failure.code)
		case .provider(let failure): ProblemCode("provider").then(failure.code)
		case .access(let failure): ProblemCode("access").then(failure.code)
		case .keychain(let failure): ProblemCode("keychain").then(failure.code)
		case .training(let failure): ProblemCode("training").then(failure.code)
		case .coach(let failure): ProblemCode("coach").then(failure.code)
		case .url(let code): ProblemCode("url", code)
		case .cocoa(let code): ProblemCode("cocoa", code)
		case .decoding: ProblemCode("decoding")
		case .encoding: ProblemCode("encoding")
		case .flush(let ending): ProblemCode("flush").then(ending.code)
		case .type(let type): ProblemCode("type").then(ProblemCode(caseOf: type))
		case .unclassified(let name): ProblemCode("unclassified").then(name)
		}
	}
}

extension ProviderDetail {
	package var code: ProblemCode {
		switch self {
		case .none: ProblemCode("none")
		case .http(let status, .code(let code)):
			ProblemCode("http", status).then(ProblemCode("openRouter", code))
		case .http(let status, .unparsed): ProblemCode("http", status).then(ProblemCode("unparsed"))
		case .url(let code): ProblemCode("url", code)
		case .unencodable: ProblemCode("unencodable")
		case .failure(let failure): ProblemCode("failure").then(failure.code)
		}
	}
}

extension LedgerFailure {
	fileprivate var code: ProblemCode {
		switch self {
		case .unavailable: ProblemCode("unavailable")
		case .rejectedBatch: ProblemCode("rejectedBatch")
		}
	}
}

extension AttemptFailure {
	fileprivate var code: ProblemCode {
		switch self {
		case .budget(let exceeded): ProblemCode("budget").then(exceeded.kind.code)
		case .provider(let failure): ProblemCode("provider").then(failure.code)
		case .windowExceededFinish: ProblemCode("windowExceededFinish")
		case .generation(let fault): ProblemCode("generation").then(fault.code)
		case .recordStorage: ProblemCode("recordStorage")
		case .access(let failure): ProblemCode("access").then(failure.code)
		case .rescueFailed(let failure): ProblemCode("rescueFailed").then(failure.code)
		}
	}
}

extension ProviderFailure {
	fileprivate var code: ProblemCode {
		switch self {
		case .credentialRejected(let status): ProblemCode("credentialRejected", status)
		case .requestBlocked: ProblemCode("requestBlocked")
		case .accessExhausted: ProblemCode("accessExhausted")
		case .rateLimited: ProblemCode("rateLimited")
		case .serverError(let status, _): ProblemCode("serverError", status)
		case .network(let loss): ProblemCode("network").then(loss.code)
		case .timeout(let kind): ProblemCode("timeout").then(kind.code)
		case .contextOverflow: ProblemCode("contextOverflow")
		case .invalidRequest: ProblemCode("invalidRequest")
		case .unknownFinish: ProblemCode("unknownFinish")
		case .malformedStream: ProblemCode("malformedStream")
		}
	}
}

extension ConnectionLoss {
	fileprivate var code: ProblemCode {
		switch self {
		case .noConnection: ProblemCode("noConnection")
		case .unreachable: ProblemCode("unreachable")
		}
	}
}

extension TimeoutKind {
	fileprivate var code: ProblemCode {
		switch self {
		case .firstToken: ProblemCode("firstToken")
		case .interChunk: ProblemCode("interChunk")
		case .request: ProblemCode("request")
		}
	}
}

extension AccessUnavailable {
	fileprivate var code: ProblemCode {
		switch self {
		case .openRouterKeyRejected: ProblemCode("openRouterKeyRejected")
		case .providerConsentRequired: ProblemCode("providerConsentRequired")
		case .recordStorageUnavailable: ProblemCode("recordStorageUnavailable")
		case .trainingIdentityUnverified(let failure):
			ProblemCode("trainingIdentityUnverified").then(failure.code)
		case .notConfigured(let method): ProblemCode("notConfigured").then(method.code)
		case .secureStorageLocked: ProblemCode("secureStorageLocked")
		case .secureStorageUnavailable: ProblemCode("secureStorageUnavailable")
		case .malformedStoredCredential(let slot):
			ProblemCode("malformedStoredCredential").then(slot.code)
		}
	}
}

extension AccessMethod {
	fileprivate var code: ProblemCode {
		switch self {
		case .credits: ProblemCode("credits")
		case .openRouterAccount: ProblemCode("openRouterAccount")
		}
	}
}

extension CredentialSlot {
	fileprivate var code: ProblemCode {
		switch self {
		case .creditsAccount: ProblemCode("creditsAccount")
		case .openRouterAccountKey: ProblemCode("openRouterAccountKey")
		case .intervalsConnection: ProblemCode("intervalsConnection")
		case .accessSelection: ProblemCode("accessSelection")
		}
	}
}

extension KeychainStoreError {
	fileprivate var code: ProblemCode {
		switch self {
		case .keychain(let status): ProblemCode("keychain", Int(status))
		case .encoding: ProblemCode("encoding")
		case .fileSystem(let code): ProblemCode("fileSystem", code)
		case .unexpected: ProblemCode("unexpected")
		}
	}
}

extension TrainingFailure {
	fileprivate var code: ProblemCode {
		switch self {
		case .credentialRejected: ProblemCode("credentialRejected")
		case .temporarilyUnavailable: ProblemCode("temporarilyUnavailable")
		case .requestRejected: ProblemCode("requestRejected")
		case .noConnection: ProblemCode("noConnection")
		}
	}
}

extension CoachFailure {
	fileprivate var code: ProblemCode {
		switch self {
		case .model(let failure): ProblemCode("model").then(failure.code)
		case .local(.recordStorage): ProblemCode("local").then(ProblemCode("recordStorage"))
		}
	}
}

extension ModelFailure {
	fileprivate var code: ProblemCode {
		switch self {
		case .credentialRejected(let method): ProblemCode("credentialRejected").then(method.code)
		case .requestBlocked: ProblemCode("requestBlocked")
		case .accessExhausted(let method): ProblemCode("accessExhausted").then(method.code)
		case .rateLimited: ProblemCode("rateLimited")
		case .providerDown(let trouble): ProblemCode("providerDown").then(trouble.code)
		case .contextOverflow: ProblemCode("contextOverflow")
		case .invalidRequest: ProblemCode("invalidRequest")
		case .generationFailed(let fault): ProblemCode("generationFailed").then(fault.code)
		case .budgetExhausted(let kind): ProblemCode("budgetExhausted").then(kind.code)
		case .accessUnavailable(let failure): ProblemCode("accessUnavailable").then(failure.code)
		}
	}
}

extension ProviderTrouble {
	fileprivate var code: ProblemCode {
		switch self {
		case .outage: ProblemCode("outage")
		case .network: ProblemCode("network")
		case .timeout: ProblemCode("timeout")
		case .noConnection: ProblemCode("noConnection")
		}
	}
}

extension GenerationFault {
	fileprivate var code: ProblemCode {
		switch self {
		case .emptyAfterError: ProblemCode("emptyAfterError")
		case .contentFiltered: ProblemCode("contentFiltered")
		case .unknownFinish: ProblemCode("unknownFinish")
		case .malformedStream: ProblemCode("malformedStream")
		}
	}
}

extension TurnBudgetExceeded.Kind {
	fileprivate var code: ProblemCode {
		switch self {
		case .generateCalls: ProblemCode("generateCalls")
		case .generateAttempts: ProblemCode("generateAttempts")
		case .wallClock: ProblemCode("wallClock")
		}
	}
}

extension FlushEnding {
	fileprivate var code: ProblemCode {
		switch self {
		case .saved: ProblemCode("saved")
		case .nothingToSave: ProblemCode("nothingToSave")
		case .partial(let failure): ProblemCode("partial").then(failure.code)
		case .failed(let failure): ProblemCode("failed").then(failure.code)
		}
	}
}
