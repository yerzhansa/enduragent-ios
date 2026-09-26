import Foundation
import Testing

@testable import EnduragentCoach

private let english = CatalogPhrasebook(tag: .en, locale: "en-US")
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
			"You're out of Credits. Buy more, or switch to your OpenRouter account.", .buyCredits,
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
			.model(.accessUnavailable(.secureStorageUnavailable)), notConfigured,
			.chooseAccessMethod, "Choose access method"),
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

private func settledState(_ settlement: Settlement, overlay: TurnOverlay = .notInThisProcess)
	-> TurnState
{
	var facts = TurnFacts(turn: turn, chat: .main, origin: phone)
	facts.fragments.append(
		Fragment(
			ulid: fixedUlid(1), hlc: HybridLogicalClock(wallMs: 1, logical: 0, deviceId: phone),
			civilDate: "1998-06-16", index: 0, draft: DraftID(), text: "Is Thursday on?",
			slash: nil))
	facts.claims.append(TurnClaimBody(chatId: .main, turn: turn, attempt: attempt))
	facts.settlements.append(
		SettledAttempt(
			ulid: fixedUlid(3),
			hlc: HybridLogicalClock(
				wallMs: Int64(failedAt.timeIntervalSince1970 * 1000), logical: 0, deviceId: phone),
			civilDate: "1998-06-16", attempt: attempt, settlement: settlement))
	return TurnLifecycle.state(
		of: facts, live: nil, overlay: overlay, device: phone)
}

private func notice(of state: TurnState) -> AthleteNotice? {
	switch state {
	case .failed(let failed): failed.notice
	case .interrupted(let interrupted): interrupted.notice
	case .savedWork(let savedWork): savedWork.notice
	case .accepted, .processing, .completed: nil
	}
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
		let shown = try #require(notice(of: state))
		#expect(shown.sentence(in: english) == row.sentence)
		#expect(shown.action == row.action)
		#expect(shown.action.map { english.say($0.title) } == row.button)
		#expect(state.retryable == (row.button == tryAgain))
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

	@Test func interruptedWithSavedWorkOffersNoTryAgain() {
		for cause in InterruptionCause.allCases {
			let state = settledState(.interrupted(partial: "", cause: cause, saved: memorySaved))
			#expect(notice(of: state)?.key == Catalog.chatTurnInterruptedSomeSaved)
			#expect(notice(of: state)?.action == nil)
			#expect(!state.retryable)
			let clean = settledState(.interrupted(partial: "", cause: cause, saved: .none))
			#expect(notice(of: clean)?.key == Catalog.chatTurnInterruptedNothingChanged)
			#expect(clean.retryable)
		}
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
			"You're out of Credits. Buy more, or switch to your OpenRouter account.", .buyCredits
		),
	])
	func failureAfterSavedWorkKeepsItsSentenceAndOffersNoReplay(
		failure: CoachFailure, sentence: String, action: RecoveryAction?
	) throws {
		for overlay in [TurnOverlay.notInThisProcess, .waitingToTryAgain] {
			let state = settledState(.failed(failure, saved: memorySaved), overlay: overlay)
			let shown = try #require(notice(of: state))
			#expect(shown.sentence(in: english) == sentence)
			#expect(shown.action == action)
			#expect(!state.retryable)
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

	@Test func savedUnverifiedOffersNoAction() {
		let state = settledState(.savedWork(.savedUnverified, saved: memorySaved))
		#expect(notice(of: state)?.key == Catalog.chatNoticeSavedUnverified)
		#expect(notice(of: state)?.action == nil)
		#expect(!state.retryable)
	}

	@Test func rateLimitPicksSecondsMinutesOrDefault() {
		let seconds = AthleteNotices.notice(
			for: .model(.rateLimited(retryAfter: .milliseconds(6_200))), turn: turn,
			waiting: false)
		#expect(seconds.key == Catalog.coachErrorRateLimitSeconds)
		#expect(seconds.vars == ["count": "7", "seconds": "7"])
		let minutes = AthleteNotices.notice(
			for: .model(.rateLimited(retryAfter: .seconds(61))), turn: turn, waiting: false)
		#expect(minutes.key == Catalog.coachErrorRateLimitMinutes)
		#expect(minutes.vars == ["count": "2", "minutes": "2"])
		let fallback = AthleteNotices.notice(
			for: .model(.rateLimited(retryAfter: nil)), turn: turn, waiting: false)
		#expect(fallback.key == Catalog.coachErrorRateLimitDefault)
		#expect(fallback.vars.isEmpty)
	}

	@Test func aRateLimitOffersTryAgainOnlyOnceItsWaitHasEnded() throws {
		let failure = Settlement.failed(
			.model(.rateLimited(retryAfter: .seconds(7))), saved: .none)
		let waiting = settledState(failure, overlay: .waitingToTryAgain)
		let shown = try #require(notice(of: waiting))
		#expect(shown.sentence(in: english) == "Rate limited — please try again in ~7 seconds.")
		#expect(shown.action == .wait(thenTryAgain: turn))
		#expect(shown.action.map { english.say($0.title) } == tryAgain)
		#expect(!waiting.retryable)
		#expect(settledState(failure).retryable)
		#expect(notice(of: settledState(failure))?.action == .tryAgain(turn))
		let down = settledState(
			.failed(.model(.providerDown(.network)), saved: .none), overlay: .waitingToTryAgain)
		#expect(notice(of: down)?.action == .tryAgain(turn))
	}

	@Test func aFailureOutsideATurnOffersNoTurnAction() {
		let rateLimited = AthleteNotices.notice(
			for: .model(.rateLimited(retryAfter: .seconds(7))), turn: nil, waiting: true)
		#expect(rateLimited.action == nil)
		let down = AthleteNotices.notice(
			for: .model(.providerDown(.network)), turn: nil, waiting: true)
		#expect(down.action == nil)
		let exhausted = AthleteNotices.notice(
			for: .model(.accessExhausted(.credits)), turn: nil, waiting: true)
		#expect(exhausted.action == .buyCredits)
	}
}
