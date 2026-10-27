import Foundation
import Testing

@testable import EnduragentCoach

@Suite struct FailureCodeTests {
	static let namedFailures: [(any Error, FailureCode)] = [
		(LedgerFailure.rejectedBatch, .ledger(.rejectedBatch)),
		(AttemptFailure.recordStorage, .attempt(.recordStorage)),
		(ProviderFailure.accessExhausted, .provider(.accessExhausted)),
		(AccessUnavailable.secureStorageLocked, .access(.secureStorageLocked)),
		(KeychainStoreError.fileSystem(28), .keychain(.fileSystem(28))),
		(URLError(.notConnectedToInternet), .url(-1009)),
		(CocoaError(.fileWriteOutOfSpace), .cocoa(640)),
		(
			DecodingError.dataCorrupted(
				.init(codingPath: [], debugDescription: "My knee hurts after the long ride.")),
			.decoding
		),
		(
			EncodingError.invalidValue(
				Double.nan, .init(codingPath: [], debugDescription: "Saturday's long ride")),
			.encoding
		),
	]

	@Test(arguments: namedFailures)
	func aFailureTheSitesCatchKeepsItsOwnCase(_ error: any Error, _ expected: FailureCode) {
		#expect(FailureCode(error) == expected)
	}

	@Test(arguments: PackageErrorType.allCases)
	func everyPackageErrorTypeIsNamedByItsCase(_ type: PackageErrorType) {
		#expect(FailureCode(Self.sample(of: type)) == .type(type))
	}

	@Test func aForeignErrorIsNamedByItsTypeOnly() {
		let error = SecretBearingError()
		#expect(
			FailureCode(error)
				== .unclassified(ErrorTypeName("EnduragentCoachTests.SecretBearingError")))
		let named = String(describing: FailureCode(error))
		for secret in ["sk-or-v1-abc", "Bearer xyz", "knee"] {
			#expect(String(describing: error).contains(secret))
			#expect(!named.contains(secret))
		}
	}

	@Test func aGenericErrorIsNamedWithItsArguments() {
		#expect(
			FailureCode(Wrapper<Int>.Failure())
				== .unclassified(ErrorTypeName("EnduragentCoachTests.WrapperSwift.Int.Failure")))
	}

	@Test func aLongTypeNameIsCutToItsFirstSixtyFourCharacters() {
		let error = AnErrorWhoseReflectedNameRunsPastSixtyFourLetters()
		#expect(String(reflecting: type(of: error)).count == 70)
		#expect(
			FailureCode(error)
				== .unclassified(
					ErrorTypeName(
						"EnduragentCoachTests.AnErrorWhoseReflectedNameRunsPastSixtyFourL")))
	}

	private static func sample(of type: PackageErrorType) -> any Error {
		switch type {
		case .acceptFailure: AcceptFailure.storageUnavailable
		case .catalogIssue: CatalogIssue.offline
		case .compactorFailure: Compactor.Failure(reason: .length)
		case .consentWriteFailure: ConsentWriteFailure.notSaved
		case .credentialFailure: CredentialFailure.signIn(.canceled)
		case .creditsFailure: CreditsFailure.banned
		case .headMoved: HeadMoved(current: .empty)
		case .historyUnavailable: HistoryUnavailable.storageUnavailable
		case .intervalsError: IntervalsError(code: "server_error", details: "busy", status: 503)
		case .invalidWorkout: InvalidWorkout(message: "no steps")
		case .memoryQueryFailure: MemoryQueryFailure(message: "no section")
		case .modelCatalogIssue: ModelCatalogIssue.malformed
		case .openRouterExchangeFailure: OpenRouterExchangeFailure.http(status: 500)
		case .planDocumentCorrupt: PlanDocumentCorrupt(reason: "no weeks")
		case .planDurationOutOfRange: PlanDurationOutOfRange(totalWeeks: 99)
		case .planNotSaved: PlanNotSaved.expired
		case .preferenceWriteFailure: PreferenceWriteFailure.notSaved
		case .preparationRefusal: PreparationRefusal.reviewRunning
		case .readRangeRefusal: ReadRangeRefusal.tooWide(days: 400)
		case .recordDecodeFailure: RecordDecodeFailure(reason: "bad body")
		case .replyParseFailure: ReplyParseFailure.documentStructure
		case .retryRefusal: RetryRefusal.unknownTurn
		case .sessionSettingRejected:
			SessionSettingRejected(
				field: .historyBudgetRatio,
				reason: Catalog.settingsConversationValidationHistoryTokenBudgetRatio)
		case .signInFailure: SignInFailure.canceled
		case .skippedRow: SkippedRow.malformed(kind: "userMessage", ulid: "row")
		case .toolInputError: ToolInputError(code: "invalid", details: "no date")
		case .transitionFailure: TransitionFailure.storage(.unavailable)
		case .transitionRefusal: TransitionRefusal.wrongStage
		case .turnBudgetExceeded: TurnBudgetExceeded(kind: .wallClock)
		case .turnRefusal: TurnRefusal.unknownTurn
		case .unusableChannelName: UnusableChannelName(name: "watts")
		}
	}
}

struct SecretBearingError: Error, CustomStringConvertible {
	var description: String {
		"sk-or-v1-abc rejected Bearer xyz while my knee hurts after Saturday's long ride"
	}
}

struct Wrapper<Value> {
	struct Failure: Error {}
}

struct AnErrorWhoseReflectedNameRunsPastSixtyFourLetters: Error {}
