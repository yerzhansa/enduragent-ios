import Foundation

package enum FailureCode: Sendable, Equatable {
	case ledger(LedgerFailure)
	case attempt(AttemptFailure)
	case provider(ProviderFailure)
	case access(AccessUnavailable)
	case keychain(KeychainStoreError)
	case training(TrainingFailure)
	case coach(CoachFailure)
	case url(Int)
	case cocoa(Int)
	case decoding
	case encoding
	case flush(FlushEnding)
	case type(PackageErrorType)
	case unclassified(ErrorTypeName)

	package init(_ error: any Error) {
		switch error {
		case let failure as LedgerFailure: self = .ledger(failure)
		case let failure as AttemptFailure: self = .attempt(failure)
		case let failure as ProviderFailure: self = .provider(failure)
		case let failure as AccessUnavailable: self = .access(failure)
		case let failure as KeychainStoreError: self = .keychain(failure)
		case let failure as URLError: self = .url(failure.code.rawValue)
		case let failure as CocoaError: self = .cocoa(failure.code.rawValue)
		case is DecodingError: self = .decoding
		case is EncodingError: self = .encoding
		default:
			let name = String(reflecting: Swift.type(of: error))
			if let named = PackageErrorType(reflectedName: name) {
				self = .type(named)
			} else {
				self = .unclassified(ErrorTypeName(name))
			}
		}
	}
}

package enum FlushEnding: Sendable, Equatable {
	case saved
	case nothingToSave
	case partial(CoachFailure)
	case failed(CoachFailure)

	package init(_ outcome: FlushOutcome) {
		switch outcome {
		case .saved: self = .saved
		case .nothingToSave: self = .nothingToSave
		case .partial(_, _, let failure): self = .partial(failure)
		case .failed(let failure): self = .failed(failure)
		}
	}
}

package enum ProviderDetail: Sendable, Equatable {
	case none
	case http(status: Int, openRouter: OpenRouterErrorCode)
	case url(Int)
	case unencodable
	case failure(FailureCode)

	package static func parse(status: Int, body: String) -> ProviderDetail {
		.http(status: status, openRouter: OpenRouterErrorCode(body: body))
	}
}

package enum OpenRouterErrorCode: Sendable, Equatable {
	case code(Int)
	case unparsed

	init(body: String) {
		let parsed: JSONValue
		do {
			parsed = try JSONValue.parse(body)
		} catch is DecodingError {
			self = .unparsed
			return
		}
		let number = parsed.objectFields["error"]?.objectFields["code"]?.numberValue
		guard let code = number.flatMap({ Int(exactly: $0) }) else {
			self = .unparsed
			return
		}
		self = .code(code)
	}
}

package enum PackageErrorType: String, Sendable, CaseIterable {
	case acceptFailure = "AcceptFailure"
	case appIdentityFailure = "AppIdentityFailure"
	case catalogIssue = "CatalogIssue"
	case compactorFailure = "Compactor.Failure"
	case consentWriteFailure = "ConsentWriteFailure"
	case credentialFailure = "CredentialFailure"
	case creditsFailure = "CreditsFailure"
	case feedbackRefusal = "FeedbackRefusal"
	case headMoved = "HeadMoved"
	case historyUnavailable = "HistoryUnavailable"
	case intervalsError = "IntervalsError"
	case invalidWorkout = "InvalidWorkout"
	case memoryQueryFailure = "MemoryQueryFailure"
	case modelCatalogIssue = "ModelCatalogIssue"
	case openRouterExchangeFailure = "OpenRouterExchangeFailure"
	case planDocumentCorrupt = "PlanDocumentCorrupt"
	case planDurationOutOfRange = "PlanDurationOutOfRange"
	case planNotSaved = "PlanNotSaved"
	case preferenceWriteFailure = "PreferenceWriteFailure"
	case preparationRefusal = "PreparationRefusal"
	case readRangeRefusal = "ReadRangeRefusal"
	case recordDecodeFailure = "RecordDecodeFailure"
	case replyParseFailure = "ReplyParseFailure"
	case retryRefusal = "RetryRefusal"
	case sessionSettingRejected = "SessionSettingRejected"
	case signInFailure = "SignInFailure"
	case skippedRow = "SkippedRow"
	case toolInputError = "ToolInputError"
	case transitionFailure = "TransitionFailure"
	case transitionRefusal = "TransitionRefusal"
	case turnBudgetExceeded = "TurnBudgetExceeded"
	case turnRefusal = "TurnRefusal"
	case unusableChannelName = "UnusableChannelName"

	private static let module =
		String(reflecting: Self.self).dropLast(String(describing: Self.self).count)

	init?(reflectedName: String) {
		guard reflectedName.hasPrefix(Self.module) else { return nil }
		self.init(rawValue: String(reflectedName.dropFirst(Self.module.count)))
	}
}

package struct ErrorTypeName: Sendable, Equatable {
	private static let limit = 64

	package let value: String

	package init(_ reflectedName: String) {
		value = String(
			reflectedName.filter { $0.isASCII && ($0.isLetter || $0.isNumber || $0 == ".") }
				.prefix(Self.limit))
	}
}
