#if DEBUG
	import Foundation
	import EnduragentCoachFixtures

	enum FixtureStorePolicy: String, CaseIterable {
		case fresh
		case keep
		case unreadable
		case v1History = "v1-history"
		case v1Review = "v1-review"
		case preVault = "pre-vault-5de5c782"
		case openReviewBeforeUpgrade = "build-6833d90f-open-review"
		case unknownWriteBeforeUpgrade = "build-6833d90f-unknown-write"
		case completedBeforeUpgrade = "build-6833d90f-completed"

		static let reviewSeedDevice = "build-6833d90f"
		static let reviewSeedConnection = UUID(
			uuid: (
				0x7F, 0x23, 0x99, 0x00, 0x8A, 0x92, 0x44, 0xE2, 0xAB, 0xC4, 0xC6, 0x64, 0x55, 0x5D,
				0xC5, 0xAE
			))
		static let reviewSeedAthlete = "i1001"

		var upgradeResource: (folder: String?, name: String, device: String)? {
			switch self {
			case .v1History: ("v1-upgrade", "history", "v1-upgrade-fixture")
			case .v1Review: ("v1-upgrade", "review", "v1-upgrade-fixture")
			case .preVault: (nil, rawValue, rawValue)
			case .openReviewBeforeUpgrade:
				(Self.reviewSeedDevice, "open-review", Self.reviewSeedDevice)
			case .unknownWriteBeforeUpgrade:
				(Self.reviewSeedDevice, "unknown-write", Self.reviewSeedDevice)
			case .completedBeforeUpgrade:
				(Self.reviewSeedDevice, "completed", Self.reviewSeedDevice)
			case .fresh, .keep, .unreadable: nil
			}
		}

		var keepsSeedConnection: Bool {
			switch self {
			case .openReviewBeforeUpgrade, .unknownWriteBeforeUpgrade, .completedBeforeUpgrade: true
			case .fresh, .keep, .unreadable, .v1History, .v1Review, .preVault: false
			}
		}
	}

	enum FixtureKeychainPolicy: String {
		case nativeProof = "native-proof"
		case unlocked
		case locked
		case empty
		case unavailable
		case malformedIntervals = "malformed-intervals"
		case malformedAccess = "malformed-access"
	}

	enum FixtureAccessMethod: String, CaseIterable {
		case catalogOpenRouter = "catalog-openrouter"
		case credits
		case openRouter = "openrouter"
		case missingOpenRouter = "missing-openrouter"
		case rejectedOpenRouter = "rejected-openrouter"
		case syncedOpenRouter = "synced-openrouter"
		case creditsNeedsSetup = "credits-needs-setup"
		case openRouterNeedsCredits = "openrouter-needs-credits"
	}

	enum FixtureCreditsOutcome: String, CaseIterable {
		case ready
		case zero
		case unavailable
		case provisioningFailed = "provisioning-failed"
		case alreadyGranted = "already-granted"
	}

	enum FixtureSignInOutcome: String, CaseIterable {
		case success
		case cancel
		case rejectedCallback = "rejected-callback"
		case exchangeFailure = "exchange-failure"
		case held
	}

	enum FixtureCalendarSaveFault: String {
		case loseAnswerOnce = "lose-answer-once"
	}

	enum FixtureCalendarReadFault: String {
		case failOnce = "fail-once"
	}

	enum FixtureRecordReadFault: String {
		case failAfterPresentedOnce = "fail-after-presented-once"
	}

	enum FixtureReviewStage: String, CaseIterable {
		case sending
		case partial
		case unconfirmed
		case refreshed
		case blocked
		case storage
	}

	enum FixturePlanSaveStage: String, CaseIterable {
		case saving
		case storage
	}

	enum FixturePlanTap: String, CaseIterable {
		case expired
		case replaced
		case twice
	}

	enum FixturePresentationFault: String {
		case failLastCardOnce = "fail-last-card-once"
	}

	enum FixtureResetFault: String {
		case failBoundary
	}

	enum FixtureReplyParserFault: String {
		case fail
	}

	enum FixtureTrainingDisplay: String, CaseIterable {
		case profileRejected = "profile-rejected"
		case profileRequestRejected = "profile-request-rejected"
		case profileUnavailable = "profile-unavailable"
		case wellnessRejected = "wellness-rejected"
		case wellnessUnavailable = "wellness-unavailable"
		case emptyWellness = "empty-wellness"
		case partialWellness = "partial-wellness"
	}

	enum FixtureCredentialWriteFault: String {
		case failOnce = "fail-once"
		case failSelection = "fail-selection"
	}

	enum FixtureTextSize: String {
		case accessibilityXXXL = "UICTContentSizeCategoryAccessibilityXXXL"
	}

	struct FixtureFeedbackScript: RawRepresentable, Equatable {
		let rawValue: String
		let answers: [FakeFeedbackAnswer]

		init?(rawValue: String) {
			var answers: [FakeFeedbackAnswer] = []
			for word in rawValue.split(separator: ",", omittingEmptySubsequences: false) {
				guard let answer = FakeFeedbackAnswer(word: String(word)) else { return nil }
				answers.append(answer)
			}
			self.rawValue = rawValue
			self.answers = answers
		}
	}

	struct FixtureArguments: Equatable {
		var store: FixtureStorePolicy = .fresh
		var keychain: FixtureKeychainPolicy = .unlocked
		var coalescingMilliseconds: Int?
		var recovery = "readable"
		var host: String?
		var language = "en"
		var locale = "en_US"
		var clock: String?
		var onboarded = false
		var calendarSaveFault: FixtureCalendarSaveFault?
		var calendarReadFault: FixtureCalendarReadFault?
		var recordReadFault: FixtureRecordReadFault?
		var presentationFault: FixturePresentationFault?
		var reviewStage: FixtureReviewStage?
		var planSaveStage: FixturePlanSaveStage?
		var planTap: FixturePlanTap?
		var resetFault: FixtureResetFault?
		var replyParserFault: FixtureReplyParserFault?
		var trainingDisplay: FixtureTrainingDisplay?
		var credentialWriteFault: FixtureCredentialWriteFault?
		var accessMethod = FixtureAccessMethod.credits
		var creditsOutcome = FixtureCreditsOutcome.ready
		var signInOutcome = FixtureSignInOutcome.cancel
		var catalogResponse = FixtureCatalogResponse.offline
		var textSize: FixtureTextSize?
		var feedback: FixtureFeedbackScript?
		var journal: FixtureJournal?

		var launchArguments: [String] {
			var values = [
				"-EnduragentFixture", "first-week", "-EnduragentFixtureStore", store.rawValue,
				"-EnduragentFixtureKeychain", keychain.rawValue,
				"-EnduragentFixtureRecovery", recovery,
				"-AppleLanguages", "(\(language))", "-AppleLocale", locale,
			]
			if let coalescingMilliseconds {
				values += ["-EnduragentFixtureCoalescing", String(coalescingMilliseconds)]
			}
			if let host { values += ["-EnduragentFixtureHost", host] }
			if let clock { values += ["-EnduragentFixtureClock", clock] }
			if onboarded { values += ["-enduragent.onboardingCompleted", "YES"] }
			if let calendarSaveFault {
				values += ["-EnduragentFixtureCalendarSave", calendarSaveFault.rawValue]
			}
			if let calendarReadFault {
				values += ["-EnduragentFixtureCalendarRead", calendarReadFault.rawValue]
			}
			if let recordReadFault {
				values += ["-EnduragentFixtureRecordRead", recordReadFault.rawValue]
			}
			if let presentationFault {
				values += ["-EnduragentFixturePresentation", presentationFault.rawValue]
			}
			if let reviewStage {
				values += ["-EnduragentFixtureReviewStage", reviewStage.rawValue]
			}
			if let planSaveStage {
				values += ["-EnduragentFixturePlanSave", planSaveStage.rawValue]
			}
			if let planTap { values += ["-EnduragentFixturePlanTap", planTap.rawValue] }
			if let resetFault { values += ["-EnduragentFixtureReset", resetFault.rawValue] }
			if let replyParserFault {
				values += ["-EnduragentFixtureReplyParser", replyParserFault.rawValue]
			}
			if let trainingDisplay {
				values += ["-EnduragentFixtureTrainingDisplay", trainingDisplay.rawValue]
			}
			if let credentialWriteFault {
				values += ["-EnduragentFixtureCredentialWrite", credentialWriteFault.rawValue]
			}
			values += ["-EnduragentFixtureAccess", accessMethod.rawValue]
			values += ["-EnduragentFixtureCredits", creditsOutcome.rawValue]
			values += ["-EnduragentFixtureSignIn", signInOutcome.rawValue]
			values += ["-EnduragentFixtureCatalog", catalogResponse.rawValue]
			if let textSize { values += [Self.textSizeArgument, textSize.rawValue] }
			if let feedback { values += ["-EnduragentFixtureFeedback", feedback.rawValue] }
			if let journal { values += ["-EnduragentFixtureJournal", journal.rawValue] }
			return values
		}

		mutating func update(from arguments: [String]) throws {
			guard arguments.count.isMultiple(of: 2) else {
				throw DecodingError.dataCorrupted(
					.init(codingPath: [], debugDescription: "unpaired launch argument"))
			}
			var values: [String: String] = [:]
			for index in stride(from: 0, to: arguments.count, by: 2) {
				values[arguments[index]] = arguments[index + 1]
			}
			store = try policy(values, "-EnduragentFixtureStore") ?? .fresh
			keychain = try policy(values, "-EnduragentFixtureKeychain") ?? .unlocked
			coalescingMilliseconds = try values["-EnduragentFixtureCoalescing"].map { raw in
				guard let value = Int(raw) else {
					throw DecodingError.dataCorrupted(
						.init(codingPath: [], debugDescription: "invalid coalescing window"))
				}
				return value
			}
			recovery = values["-EnduragentFixtureRecovery"] ?? "readable"
			host = values["-EnduragentFixtureHost"]
			language = (values["-AppleLanguages"] ?? "(en)").trimmingCharacters(
				in: CharacterSet(charactersIn: "()"))
			locale = values["-AppleLocale"] ?? "en_US"
			clock = values["-EnduragentFixtureClock"]
			onboarded = values["-enduragent.onboardingCompleted"] == "YES"
			calendarSaveFault = try policy(values, "-EnduragentFixtureCalendarSave")
			calendarReadFault = try policy(values, "-EnduragentFixtureCalendarRead")
			recordReadFault = try policy(values, "-EnduragentFixtureRecordRead")
			presentationFault = try policy(values, "-EnduragentFixturePresentation")
			reviewStage = try policy(values, "-EnduragentFixtureReviewStage")
			planSaveStage = try policy(values, "-EnduragentFixturePlanSave")
			planTap = try policy(values, "-EnduragentFixturePlanTap")
			resetFault = try policy(values, "-EnduragentFixtureReset")
			replyParserFault = try policy(values, "-EnduragentFixtureReplyParser")
			trainingDisplay = try policy(values, "-EnduragentFixtureTrainingDisplay")
			credentialWriteFault = try policy(values, "-EnduragentFixtureCredentialWrite")
			accessMethod = try policy(values, "-EnduragentFixtureAccess") ?? .credits
			creditsOutcome = try policy(values, "-EnduragentFixtureCredits") ?? .ready
			signInOutcome = try policy(values, "-EnduragentFixtureSignIn") ?? .cancel
			catalogResponse = try policy(values, "-EnduragentFixtureCatalog") ?? .offline
			textSize = try policy(values, Self.textSizeArgument)
			feedback = try policy(values, "-EnduragentFixtureFeedback")
			journal = try policy(values, "-EnduragentFixtureJournal")
		}

		private static let textSizeArgument = "-UIPreferredContentSizeCategoryName"

		private func policy<Policy: RawRepresentable>(
			_ values: [String: String], _ key: String
		) throws -> Policy? where Policy.RawValue == String {
			guard let raw = values[key] else { return nil }
			guard let value = Policy(rawValue: raw) else {
				throw DecodingError.dataCorrupted(
					.init(codingPath: [], debugDescription: "invalid \(key): \(raw)"))
			}
			return value
		}
	}
#endif
