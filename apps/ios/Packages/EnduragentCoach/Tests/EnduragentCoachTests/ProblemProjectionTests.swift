import EnduragentCoachFixtures
import Foundation
import Testing

@testable import EnduragentCoach

@Suite struct ProblemProjectionTests {
	static let at = Date(timeIntervalSince1970: 1_793_092_443.5)

	private static func sample(of kind: ProblemKind) -> DiagnosticsEvent {
		let attempt = AttemptID(ulid: fixedUlid(11))
		switch kind {
		case .providerFailure:
			return .providerFailure(
				attempt, .serverError(status: 502, retryAfter: .seconds(3)),
				detail: .http(status: 502, openRouter: .code(502)))
		case .toolFailed: return .toolFailed(attempt, .memoryQuery, failure: .toolFailed)
		case .memoryFlushFailed:
			return .memoryFlushFailed(.main, .flush(.partial(.local(.recordStorage))))
		case .compactionFailed:
			return .compactionFailed(
				.main, .attempt(.rescueFailed(.provider(.timeout(.firstToken)))))
		case .replyObservedUnsaved:
			return .replyObservedUnsaved(
				attempt, .unclassified(ErrorTypeName("EnduragentCoachTests.SecretBearingError")))
		case .skippedRecord:
			return .skippedRecord(
				.newerVersion(kind: "sk-or-v1-abc", version: 4, ulid: "Bearer xyz"))
		case .recoveryUnavailable: return .recoveryUnavailable(.unavailable)
		case .importsUnavailable: return .importsUnavailable(.main, .rejectedBatch)
		case .secureStorageFailed:
			return .secureStorageFailed(.openRouterAccountKey, failure: .keychain(-25_300))
		case .preferencesUnavailable: return .preferencesUnavailable(.unavailable)
		case .consentUnavailable:
			return .consentUnavailable(.trainingIdentityUnverified(.credentialRejected))
		case .snapshotReadFailed:
			return .snapshotReadFailed(attempt, .wellness, .temporarilyUnavailable)
		case .snapshotDeadlineMissed: return .snapshotDeadlineMissed(attempt)
		case .reviewOutcomeUnsaved: return .reviewOutcomeUnsaved(.unavailable)
		case .settlementUnsaved:
			return .settlementUnsaved(TurnID(ulid: fixedUlid(12)), .unavailable)
		case .reviewUnavailable: return .reviewUnavailable(.main, .unavailable)
		case .planConfirmationUnavailable:
			return .planConfirmationUnavailable(.main, .rejectedBatch)
		case .planSaveStalled:
			return .planSaveStalled(PlanConfirmationID(ulid: fixedUlid(13)), .unavailable)
		case .journalRestarted: return .journalRestarted(.unreadable)
		case .journalLinesDropped: return .journalLinesDropped(count: 2)
		case .diagnosticsFileFailed: return .diagnosticsFileFailed(.couldNotWrite, .cocoa(513))
		}
	}

	@Test(arguments: ProblemKind.allCases)
	func everyEventProjectsToALineThatDecodesBack(_ kind: ProblemKind) throws {
		let line = Self.sample(of: kind).line
		#expect(line.kind == kind)
		#expect((line.row != nil) == (kind == .skippedRecord))
		let stamped = StampedLine(at: Self.at, line: .problem(line))
		#expect(try StampedLine(decoding: stamped.encoded()) == stamped)
	}

	@Test func aSkippedRowIsStoredScrubbedWithItsVersionAsACode() throws {
		let line = Self.sample(of: .skippedRecord).line
		#expect(line.cause == ProblemCode("newerVersion", 4))
		let row = try #require(line.row)
		#expect(row.kind.text == "[redacted]")
		#expect(row.ulid.text == "[redacted]")
	}

	@Test func aConversationIdOutsideTheReferenceSetIsLeftOut() throws {
		let chat = try #require(ChatID(rawValue: "telegram:4242"))
		#expect(DiagnosticsEvent.reviewUnavailable(chat, .unavailable).line.subject == nil)
		let main = try #require(ChatRef(.main))
		#expect(DiagnosticsEvent.reviewUnavailable(.main, .unavailable).line.subject == .chat(main))
	}
}
