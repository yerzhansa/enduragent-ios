import Foundation
import Testing

@testable import EnduragentCoach

private let english = CatalogPhrasebook(tag: .en)
private let phone = DeviceID(rawValue: "phone-a")
private let turn = TurnID(ulid: fixedUlid(1))
private let attempt = AttemptID(ulid: fixedUlid(2))
private let failedAt = Date(timeIntervalSince1970: 897_984_000)
private let memorySaved = WriteSummary(
	memorySections: 1, ledgerEvents: 0, planSaves: 0, calendarWrites: 0)

private let tryAgain = "Try again"
private let providerDown = "The model provider is having trouble — try again in a few minutes."
private let unknown = "Sorry, something went wrong. Please try again."
private let responseFailure = "The coach couldn't respond. Please try again."
private let notConfigured = "Choose how the coach reaches a model to continue."
private let lockedSentence = "Unlock your iPhone to continue. Your message is saved."
private let intervalsRejected =
	"intervals.icu rejected the request — check your intervals.icu connection or API key."
private let nothingChanged = "This reply stopped before it finished. Nothing was changed."
private let someSaved =
	"This reply stopped before it finished. Some information was saved first."

struct NoticeRow: Sendable, CustomTestStringConvertible {
	let settlement: Settlement
	let sentence: String
	let action: RecoveryAction?
	let button: String?

	var testDescription: String { "\(settlement)" }

	static func failed(
		_ failure: CoachFailure, _ sentence: String, _ action: RecoveryAction?,
		_ button: String?
	) -> NoticeRow {
		NoticeRow(
			settlement: .failed(failure, saved: .none), sentence: sentence, action: action,
			button: button)
	}

	static func rateLimited(_ retryAfter: Duration?, _ sentence: String) -> NoticeRow {
		failed(.model(.rateLimited(retryAfter: retryAfter)), sentence, .tryAgain(turn), tryAgain)
	}

	static let failures: [NoticeRow] = [
		failed(
			.model(.credentialRejected(.credits)),
			"Your Credits couldn't be used. Restore purchases to continue.", .restoreCredits,
			"Restore purchases"),
		failed(
			.model(.credentialRejected(.openRouterAccount)),
			"Your OpenRouter sign-in is no longer valid. Sign in again to continue.",
			.signInToOpenRouter, "Sign in again"),
		failed(
			.model(.accessExhausted(.credits)),
			"You're out of Credits. You can switch to your OpenRouter account.", .buyCredits,
			"Buy Credits"),
		failed(
			.model(.accessExhausted(.openRouterAccount)),
			"Your OpenRouter account is out of funds. Add funds on OpenRouter, or switch to Credits.",
			.chooseAccessMethod, "Choose access method"),
		rateLimited(.seconds(1), "Rate limited — please try again in ~1 seconds."),
		rateLimited(.seconds(7), "Rate limited — please try again in ~7 seconds."),
		rateLimited(.seconds(60), "Rate limited — please try again in ~1 minute."),
		rateLimited(.seconds(90), "Rate limited — please try again in ~2 minutes."),
		rateLimited(nil, "Rate limited — please try again in about a minute."),
		rateLimited(.zero, "Rate limited — please try again in about a minute."),
		failed(.model(.providerDown(.outage)), providerDown, .tryAgain(turn), tryAgain),
		failed(.model(.providerDown(.network)), providerDown, .tryAgain(turn), tryAgain),
		failed(.model(.providerDown(.timeout)), providerDown, .tryAgain(turn), tryAgain),
		failed(.model(.contextOverflow), unknown, .tryAgain(turn), tryAgain),
		failed(.model(.invalidRequest), unknown, .tryAgain(turn), tryAgain),
		failed(.model(.budgetExhausted(.generateAttempts)), unknown, .tryAgain(turn), tryAgain),
		failed(.model(.budgetExhausted(.generateCalls)), unknown, .tryAgain(turn), tryAgain),
		failed(.model(.budgetExhausted(.wallClock)), unknown, .tryAgain(turn), tryAgain),
		failed(
			.model(.generationFailed(.emptyAfterError)), responseFailure, .tryAgain(turn), tryAgain
		),
		failed(
			.model(.generationFailed(.contentFiltered)), responseFailure, .tryAgain(turn), tryAgain
		),
		failed(
			.model(.generationFailed(.unknownFinish)), responseFailure, .tryAgain(turn), tryAgain),
		failed(
			.model(.generationFailed(.malformedStream)), responseFailure, .tryAgain(turn), tryAgain
		),
		failed(
			.model(.accessUnavailable(.secureStorageLocked)),
			"Unlock your iPhone to continue. Your message is saved.", .tryAgain(turn), tryAgain),
		failed(
			.model(.accessUnavailable(.notConfigured(.credits))), notConfigured,
			.chooseAccessMethod, "Choose access method"),
		failed(
			.model(.accessUnavailable(.notConfigured(.openRouterAccount))), notConfigured,
			.chooseAccessMethod, "Choose access method"),
		failed(
			.model(.accessUnavailable(.secureStorageUnavailable)),
			"Secure storage is temporarily unavailable. Your saved coaching information is still here. Try again.",
			.chooseAccessMethod, "Choose access method"),
		failed(
			.model(.accessUnavailable(.malformedStoredCredential(.creditsAccount))),
			"The saved model access credential couldn't be read. Choose an access method to continue.",
			.chooseAccessMethod, "Choose access method"),
		failed(
			.model(.accessUnavailable(.malformedStoredCredential(.intervalsConnection))),
			"The saved intervals.icu connection couldn't be read. Replace the key to connect again.",
			.connectTraining, "Connect"),
		failed(
			.local(.recordStorage),
			"(Heads up: my disk is full, so I couldn't save this to our history — but your message went through. Please free up some space when you can.)",
			nil, nil),
	]

	static let interruptions: [NoticeRow] = InterruptionCause.allCases.flatMap { cause in
		[
			NoticeRow(
				settlement: .interrupted(partial: "Thursday is", cause: cause, saved: .none),
				sentence: nothingChanged, action: .tryAgain(turn), button: tryAgain),
			NoticeRow(
				settlement: .interrupted(partial: "", cause: cause, saved: memorySaved),
				sentence: someSaved, action: nil, button: nil),
		]
	}

	static let savedWork: [NoticeRow] = [
		NoticeRow(
			settlement: .savedWork(.writesSaved, saved: memorySaved),
			sentence:
				"I made a change to your calendar, but then ran into a problem finishing my reply. Your change is saved — please open your calendar to confirm it looks right, and tell me if you'd like me to adjust it.",
			action: nil, button: nil),
		NoticeRow(
			settlement: .savedWork(.savedUnverified, saved: memorySaved),
			sentence:
				"I saved your information, but couldn't verify my response. Please try again.",
			action: nil, button: nil),
	]

	static let all = failures + interruptions + savedWork
}

private let thisProcess = ProcessID(ulid: fixedUlid(60))

private func claimedFacts(by process: ProcessID) -> TurnFacts {
	var facts = TurnFacts(turn: turn, chat: .main, origin: phone)
	facts.fragments.append(
		Fragment(
			ulid: fixedUlid(1), hlc: HybridLogicalClock(wallMs: 1, logical: 0, deviceId: phone),
			civilDate: "1998-06-16", timeZone: amsterdamZone, index: 0, draft: DraftID(),
			text: "Is Thursday on?", slash: nil))
	facts.claims.append(
		ClaimedAttempt(
			hlc: HybridLogicalClock(wallMs: 2, logical: 0, deviceId: phone),
			body: TurnClaimBody(
				chatId: .main, turn: turn, attempt: attempt, process: process,
				lease: .continuedProcessing)))
	return facts
}

private func settledState(_ settlement: Settlement, overlay: TurnOverlay = .notInThisProcess)
	-> TurnState
{
	var facts = claimedFacts(by: thisProcess)
	facts.settlements.append(
		SettledAttempt(
			ulid: fixedUlid(3),
			hlc: HybridLogicalClock(
				wallMs: Int64(failedAt.timeIntervalSince1970 * 1000), logical: 0, deviceId: phone),
			attempt: attempt, settlement: settlement))
	return TurnLifecycle.state(
		of: facts, live: nil, overlay: overlay, device: phone, process: thisProcess)
}

private func family(_ failure: CoachFailure) -> String {
	switch failure {
	case .model(.credentialRejected): "credentialRejected"
	case .model(.accessExhausted): "accessExhausted"
	case .model(.rateLimited): "rateLimited"
	case .model(.providerDown): "providerDown"
	case .model(.contextOverflow): "contextOverflow"
	case .model(.invalidRequest): "invalidRequest"
	case .model(.generationFailed): "generationFailed"
	case .model(.budgetExhausted): "budgetExhausted"
	case .model(.accessUnavailable): "accessUnavailable"
	case .local(.recordStorage): "recordStorage"
	}
}

private let npmsUnknownThree: Set = ["contextOverflow", "invalidRequest", "budgetExhausted"]

@Suite struct AthleteNoticesTests {
	@Test(arguments: NoticeRow.all)
	func everyNoticeRendersItsEnglishAndAction(row: NoticeRow) throws {
		let state = settledState(row.settlement)
		let shown = try #require(turnNotice(of: state))
		#expect(shown.sentence(in: displayLocale()) == row.sentence)
		#expect(shown.action == row.action)
		#expect(shown.action.map { english.say($0.title) } == row.button)
	}

	@Test(arguments: LanguageTag.allCases)
	func productionNoticesRenderWithoutMissingVariables(tag: LanguageTag) throws {
		for row in NoticeRow.all {
			let shown = try #require(turnNotice(of: settledState(row.settlement)))
			let copy = shown.sentence(in: displayLocale(tag))
			#expect(!copy.contains("%#@"), "\(tag.rawValue) \(shown.key.rawValue)")
		}
	}

	@Test func everyFailureCaseHasARowAndNoneIsUnknownExceptTheThree() {
		var families: Set<String> = []
		for row in NoticeRow.failures {
			guard case .failed(let failure, _) = row.settlement else {
				Issue.record("expected a failure row, got \(row.settlement)")
				continue
			}
			families.insert(family(failure))
			let shown = AthleteNotices.notice(for: failure, turn: turn, waiting: false)
			#expect(
				(shown.key == Catalog.coachErrorUnknown)
					== npmsUnknownThree.contains(family(failure)))
		}
		#expect(families.count == 10)
	}

	@Test func aDeadClaimRecoveryHasNotSettledReadsHistoryUnavailableWithNoButton() throws {
		let state = TurnLifecycle.state(
			of: claimedFacts(by: ProcessID(ulid: fixedUlid(61))), live: nil,
			overlay: .notInThisProcess, device: phone, process: thisProcess)
		let shown = try #require(turnNotice(of: state))
		#expect(
			shown.sentence(in: displayLocale())
				== "Conversation history is temporarily unavailable.")
		#expect(shown.action == nil)
	}

	@Test(arguments: [
		(
			CoachFailure.model(.rateLimited(retryAfter: .seconds(7))),
			"Rate limited — please try again in ~7 seconds.", RecoveryAction?.none
		),
		(.model(.providerDown(.network)), providerDown, nil),
		(
			.model(.accessUnavailable(.secureStorageLocked)),
			"Unlock your iPhone to continue. Your message is saved.", nil
		),
		(
			.model(.accessExhausted(.credits)),
			"You're out of Credits. You can switch to your OpenRouter account.", .buyCredits
		),
	])
	func failureAfterSavedWorkKeepsItsSentenceAndOffersNoReplay(
		failure: CoachFailure, sentence: String, action: RecoveryAction?
	) throws {
		for overlay in [TurnOverlay.notInThisProcess, .waitingToTryAgain] {
			let state = settledState(.failed(failure, saved: memorySaved), overlay: overlay)
			let shown = try #require(turnNotice(of: state))
			#expect(shown.sentence(in: displayLocale()) == sentence)
			#expect(shown.action == action)
		}
	}

	@Test func savedWorkPicksTheInterruptedSentenceAndTheTurnAloneDecidesTryAgain() {
		for cause in InterruptionCause.allCases {
			let offered = AthleteNotices.notice(for: cause, saved: memorySaved, turn: turn)
			#expect(offered.key == Catalog.chatTurnInterruptedSomeSaved)
			#expect(offered.action == .tryAgain(turn))
			let refused = AthleteNotices.notice(for: cause, saved: .none, turn: nil)
			#expect(refused.key == Catalog.chatTurnInterruptedNothingChanged)
			#expect(refused.action == nil)
		}
	}

	@Test func rateLimitPicksSecondsMinutesOrDefault() {
		let seconds = AthleteNotices.notice(
			for: .model(.rateLimited(retryAfter: .milliseconds(6_200))), turn: turn,
			waiting: false)
		#expect(seconds.key == Catalog.coachErrorRateLimitSeconds)
		#expect(seconds.count == 7)
		#expect(seconds.vars == ["seconds": .integer(7)])
		let minutes = AthleteNotices.notice(
			for: .model(.rateLimited(retryAfter: .seconds(61))), turn: turn, waiting: false)
		#expect(minutes.key == Catalog.coachErrorRateLimitMinutes)
		#expect(minutes.count == 2)
		#expect(minutes.vars == ["minutes": .integer(2)])
		let fallback = AthleteNotices.notice(
			for: .model(.rateLimited(retryAfter: nil)), turn: turn, waiting: false)
		#expect(fallback.key == Catalog.coachErrorRateLimitDefault)
		#expect(fallback.vars.isEmpty)
	}

	@Test func aRateLimitOffersTryAgainOnlyOnceItsWaitHasEnded() throws {
		let failure = Settlement.failed(
			.model(.rateLimited(retryAfter: .seconds(7))), saved: .none)
		let waiting = settledState(failure, overlay: .waitingToTryAgain)
		let shown = try #require(turnNotice(of: waiting))
		#expect(
			shown.sentence(in: displayLocale()) == "Rate limited — please try again in ~7 seconds.")
		#expect(shown.action == .wait(thenTryAgain: turn))
		#expect(shown.action.map { english.say($0.title) } == tryAgain)
		#expect(turnNotice(of: settledState(failure))?.action == .tryAgain(turn))
		let down = settledState(
			.failed(.model(.providerDown(.network)), saved: .none), overlay: .waitingToTryAgain)
		#expect(turnNotice(of: down)?.action == .tryAgain(turn))
	}

	@Test func creditsFailuresOutsideATurnReadCatalogSentences() {
		let unavailable = "Credits are unavailable right now. Try again later."
		for failure in [CreditsFailure.banned, .unavailable, .unexpectedResponse(status: 500)] {
			#expect(
				AthleteNotice.credits(failure: failure).sentence(in: displayLocale()) == unavailable
			)
		}
		#expect(
			AthleteNotice.credits(failure: CreditsFailure.noAthleteKey).sentence(
				in: displayLocale())
				== notConfigured)
		let changed = AthleteNotice.credits(failure: CreditsFailure.accountChanged)
		#expect(
			changed.sentence(in: displayLocale())
				== "Your Credits account changed while this request was finishing. Your current account was kept."
		)
		#expect(changed.action == nil)
		let locked = AthleteNotice.credits(failure: AccessUnavailable.secureStorageLocked)
		#expect(locked.sentence(in: displayLocale()) == lockedSentence)
		#expect(locked.action == nil)
	}

	@Test func statusNoticeNamesALockedKeychainOrAnUnreadableProfile() {
		let summary = IntervalsSummary(
			connectionID: testConnection.id, keySuffix: "-key",
			profile: .failed(.temporarilyUnavailable))
		let account = TrainingAccount.intervals(connection: ConnectionID(), athlete: nil)
		let locked = CoachStatus(
			access: AccessStatus(state: .unreadable(.secureStorageLocked), builtInModel: testModel),
			training: .unavailable(.secureStorageLocked), preferences: .npmDefaults,
			providerConsent: ProviderConsent(at: Date(timeIntervalSince1970: 0)),
			resolve: testDisplayLocale)
		#expect(locked.notice?.sentence(in: displayLocale()) == lockedSentence)
		let offline = CoachStatus(
			access: AccessStatus(state: .credits(.ready), builtInModel: testModel),
			training: .connected(summary, account: account),
			preferences: .npmDefaults,
			providerConsent: ProviderConsent(at: Date(timeIntervalSince1970: 0)),
			resolve: testDisplayLocale)
		#expect(
			offline.notice?.sentence(in: displayLocale())
				== "Your athlete profile is temporarily unavailable. Try again.")
		let rejected = CoachStatus(
			access: AccessStatus(state: .credits(.ready), builtInModel: testModel),
			training: .connected(
				IntervalsSummary(
					connectionID: testConnection.id, keySuffix: "-key",
					profile: .failed(.credentialRejected)),
				account: account),
			preferences: .npmDefaults,
			providerConsent: ProviderConsent(at: Date(timeIntervalSince1970: 0)),
			resolve: testDisplayLocale)
		#expect(
			rejected.notice?.sentence(in: displayLocale())
				== "intervals.icu did not accept that key.")
		#expect(
			CoachStatus(
				access: AccessStatus(state: .defaultCredits(.needsSetup), builtInModel: testModel),
				training: .unconnected, preferences: .npmDefaults,
				providerConsent: ProviderConsent(at: Date(timeIntervalSince1970: 0)),
				resolve: testDisplayLocale
			)
			.notice == nil)
		#expect(
			CoachStatus(
				access: AccessStatus(state: .credits(.ready), builtInModel: testModel),
				training: .unconnected, preferences: .npmDefaults,
				providerConsent: ProviderConsent(at: Date(timeIntervalSince1970: 0)),
				resolve: testDisplayLocale
			).notice
				== nil)
	}
}
