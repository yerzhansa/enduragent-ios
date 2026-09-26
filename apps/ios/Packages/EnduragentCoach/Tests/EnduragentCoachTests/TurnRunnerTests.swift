import Foundation
import Testing

@testable import EnduragentCoach

@Suite struct TurnRunnerTests {
	let transport = FakeModelTransport()
	let intervals = FakeIntervalsClient(athleteName: "Ada", ftp: 250)
	let store = InMemoryRecordLog()
	let clock = FixedClock(now: "1998-06-13T08:00:00+02:00", timeZone: "Europe/Amsterdam")

	@Test func tenthStepRunsToolsThenStops() async throws {
		intervals.activities = [
			.ride(name: "Sunday long ride", date: "1998-06-07", durationS: 7200, trainingLoad: 120)
		]
		var script: [ScriptedEvent] = []
		for _ in 0..<10 {
			script.append(.text("."))
			script.append(.toolCall(name: "intervals_fetch_activities", arguments: #"{"days":7}"#))
			script.append(.finish(reason: .toolCalls))
		}
		transport.script = script
		let coach = makeCoach()
		let settled = try await coach.sendAndSettle("Keep fetching")
		#expect(replyText(settled) == ".")
		#expect(transport.requests.count == 10)
	}

	@Test func overflowLengthCompactsAndRetries() async throws {
		transport.finishUsage = Usage(
			inputTokens: TurnPolicy.contextWindowCap, outputTokens: 8, cost: nil)
		transport.script = [
			.text("truncated"),
			.finish(reason: .length),
			.text(
				"## Athlete Profile\n## Training Status\n## Coach Stance\n## Discussion Context\n## Pending Questions"
			),
			.finish(reason: .stop),
			.text("after compact"),
			.finish(reason: .stop),
		]
		let coach = makeCoach()
		let settled = try await coach.sendAndSettle("Long history")
		let text = try #require(replyText(settled))
		#expect(text.contains("after compact") || text.contains("truncated"))
		#expect(transport.requests.count >= 2)
		let records = try await store.fetch(
			RecordQuery(scope: .synced([.compactionSummary, .windowStart]), chatId: "main")
		).records
		#expect(!records.isEmpty)
	}

	@Test func lifecycleRecordsAreWrittenInThreeBatchesAroundTheModelCall() async throws {
		transport.script = [.text("Noted."), .finish(reason: .stop)]
		let recording = BatchRecordingLog(inner: store)
		let coach = EnduragentCoachTests.makeCoach(
			transport: transport, intervals: intervals, store: recording, clock: clock)
		let turn = try #require(
			try await coach.send(draft("Remember Saturdays"), to: .main).acceptedTurn)
		_ = try #require(await coach.settledState(of: turn, in: .main))
		#expect(recording.batches == [["userMessage"], ["turnClaim"], ["turnSettled"]])
		let everyKind: [String] = recording.batches.flatMap { $0 }
		#expect(!everyKind.contains("assistantMessage"))
		let synced = try await store.fetch(
			RecordQuery(scope: .synced([.userMessage, .turnSettled]), chatId: "main")
		).records
		let local = try await store.fetch(
			RecordQuery(scope: .deviceLocal([.turnClaim]), chatId: "main")
		)
		.records
		#expect(synced.map(\.body.kind) == ["userMessage", "turnSettled"])
		#expect(local.map(\.body.kind) == ["turnClaim"])
		#expect(Set((synced + local).map(\.body.turn)) == [turn])
		#expect((synced + local).allSatisfy { $0.account == .unconnected })
		guard case .operation(.turn(let claimedTurn), let attempt)? = local.first?.cause else {
			Issue.record("expected a turn stamp on the claim")
			return
		}
		#expect(claimedTurn == turn)
		#expect(synced.last?.cause == .operation(.turn(turn), attempt))
		guard case .operation(.turn(let acceptedTurn), let acceptAttempt)? = synced.first?.cause
		else {
			Issue.record("expected a turn stamp on the accept")
			return
		}
		#expect(acceptedTurn == turn)
		#expect(acceptAttempt != attempt)
		#expect(await coach.transcript(.main) == ["Remember Saturdays", "Noted."])
	}

	@Test func toolErrorReturnsToTheModelAsAResult() async throws {
		intervals.loadFailure = IntervalsError(
			code: "down", details: "intervals.icu is unavailable.")
		transport.script = [
			.toolCall(name: "intervals_fetch_wellness", arguments: #"{"days":7}"#),
			.finish(reason: .toolCalls),
			.text("I could not read your wellness data."),
			.finish(reason: .stop),
		]
		let coach = makeCoach()
		let settled = try await coach.sendAndSettle("How am I recovering?")
		#expect(replyText(settled) == "I could not read your wellness data.")
		#expect(transport.requests.count == 2)
		let toolMessage = try #require(
			transport.requests[1].messages.last(where: { $0.role == .tool }))
		#expect(toolMessage.content.contains("intervals.icu is unavailable."))
	}

	@Test func providerErrorsSettleAsTypedFailures() async throws {
		transport.failures = [.connection(.notConnectedToInternet)]
		let coach = makeCoach()
		let network = try await coach.sendAndSettle("one")
		#expect(failure(network) == .model(.providerDown(.network)))
		transport.failures = [ScriptedFailure(.unknownFinish)]
		let finish = try await coach.sendAndSettle("two")
		#expect(failure(finish) == .model(.generationFailed(.unknownFinish)))
		#expect(await coach.transcript(.main) == ["one", "two"])
		let prompt = try #require(transport.requests.last)
		#expect(prompt.messages.filter { $0.role == .user }.count == 1)
	}

	@Test(arguments: FailureRow.all)
	func everyProviderFailureSettlesWithItsNotice(row: FailureRow) async throws {
		transport.failures = [row.scripted]
		let coach = makeCoach()
		let turn = try #require(try await coach.send(draft("Plan my week"), to: .main).acceptedTurn)
		let settled = try #require(await coach.settledState(of: turn, in: .main))
		guard case .failed(let failed) = settled else {
			Issue.record("expected a failed turn, got \(settled)")
			return
		}
		#expect(failed.failure == .model(row.failure))
		#expect(failed.notice.key == row.key)
		#expect(failed.notice.action == (row.offersTryAgain ? .tryAgain(turn) : nil))
		#expect(english.say(failed.notice.key, failed.notice.vars) == row.english)
	}

	@Test func watchdogFireSettlesAsTimeoutFailure() async throws {
		transport.hangUntilCancelled = true
		let coach = makeCoach()
		let turn = try #require(try await coach.send(draft("Hello"), to: .main).acceptedTurn)
		let settled = try #require(
			await coach.settledState(of: turn, in: .main, within: .seconds(60)))
		#expect(failure(settled) == .model(.providerDown(.timeout)))
		guard case .failed(let failed) = settled else { return }
		#expect(failed.notice.key == Catalog.coachErrorProviderDown)
		#expect(failed.notice.action == .tryAgain(turn))
		let claim = try #require(
			try await store.fetch(RecordQuery(scope: .deviceLocal([.turnClaim]), turn: turn))
				.records.first)
		guard case .operation(_, let attempt) = claim.cause else {
			Issue.record("expected a turn stamp on the claim")
			return
		}
		#expect(
			coach.diagnostics.entries.map(\.event) == [
				.providerFailure(attempt, .timeout(.firstToken), detail: "")
			])
	}

	@Test func missingKeySettlesNotConfiguredWithoutARequest() async throws {
		let coach = makeCoach(secrets: FakeSecretStore())
		let turn = try #require(try await coach.send(draft("Hello"), to: .main).acceptedTurn)
		let settled = try #require(await coach.settledState(of: turn, in: .main))
		#expect(failure(settled) == .model(.accessUnavailable(.notConfigured(.credits))))
		#expect(settled.retryable)
		#expect(transport.requestCount == 0)
		let claims = try await store.fetch(
			RecordQuery(scope: .deviceLocal([.turnClaim]), turn: turn))
		#expect(claims.records.count == 1)
	}

	@Test func lockedKeychainSettlesSecureStorageLocked() async throws {
		let secrets = keyedSecrets()
		secrets.locked = true
		let coach = makeCoach(secrets: secrets)
		let settled = try await coach.sendAndSettle("Hello")
		#expect(failure(settled) == .model(.accessUnavailable(.secureStorageLocked)))
		#expect(transport.requestCount == 0)
	}

	@Test func keyStoredAfterLaunchReachesTheNextAttempt() async throws {
		let secrets = FakeSecretStore()
		let coach = makeCoach(secrets: secrets)
		let turn = try #require(try await coach.send(draft("Hello"), to: .main).acceptedTurn)
		_ = try #require(await coach.settledState(of: turn, in: .main))
		try secrets.storeOpenRouterKey("sk-or-stored-after-launch")
		transport.script = [.text("Hello, Ada."), .finish(reason: .stop)]
		try await coach.retry(turn, in: .main)
		let answered = try #require(await coach.settledState(of: turn, in: .main))
		#expect(replyText(answered) == "Hello, Ada.")
		let request = try #require(transport.requests.only)
		#expect(
			request.credential
				== ProviderCredential(secret: "sk-or-stored-after-launch", method: .credits))
		#expect(request.model == testModel)
		#expect(request.charge == .chatAttempt)
	}

	private func makeCoach(secrets: any SecretStore = keyedSecrets()) -> Coach {
		EnduragentCoachTests.makeCoach(
			transport: transport, intervals: intervals, store: store, clock: clock, secrets: secrets
		)
	}
}

private let english = CatalogPhrasebook(tag: .en, locale: "en")

struct FailureRow: Sendable, CustomTestStringConvertible {
	let scripted: ScriptedFailure
	let failure: ModelFailure
	let key: CatalogKey
	let offersTryAgain: Bool
	let english: String

	var testDescription: String { "\(failure)" }

	static let all: [FailureRow] = [
		FailureRow(
			scripted: .http(status: 401), failure: .credentialRejected(.credits),
			key: Catalog.coachErrorProviderCredentials, offersTryAgain: false,
			english: "The model provider rejected the API key — check your provider credentials."),
		FailureRow(
			scripted: .http(status: 402), failure: .accessExhausted(.credits),
			key: Catalog.coachErrorUnknown, offersTryAgain: false,
			english: "Sorry, something went wrong. Please try again."),
		FailureRow(
			scripted: .http(status: 429, headers: ["retry-after": "7"]),
			failure: .rateLimited(retryAfter: .seconds(7)),
			key: Catalog.coachErrorRateLimitSeconds, offersTryAgain: true,
			english: "Rate limited — please try again in ~7 seconds."),
		FailureRow(
			scripted: .http(status: 429, headers: ["retry-after": "90"]),
			failure: .rateLimited(retryAfter: .seconds(90)),
			key: Catalog.coachErrorRateLimitMinutes, offersTryAgain: true,
			english: "Rate limited — please try again in ~2 minutes."),
		FailureRow(
			scripted: .http(status: 429), failure: .rateLimited(retryAfter: nil),
			key: Catalog.coachErrorRateLimitDefault, offersTryAgain: true,
			english: "Rate limited — please try again in about a minute."),
		FailureRow(
			scripted: .http(status: 500), failure: .providerDown(.outage),
			key: Catalog.coachErrorProviderDown, offersTryAgain: true,
			english: "The model provider is having trouble — try again in a few minutes."),
		FailureRow(
			scripted: .connection(.notConnectedToInternet), failure: .providerDown(.network),
			key: Catalog.coachErrorProviderDown, offersTryAgain: true,
			english: "The model provider is having trouble — try again in a few minutes."),
		FailureRow(
			scripted: .connection(.timedOut), failure: .providerDown(.timeout),
			key: Catalog.coachErrorProviderDown, offersTryAgain: true,
			english: "The model provider is having trouble — try again in a few minutes."),
		FailureRow(
			scripted: .http(status: 400, body: #"{"error":{"message":"maximum context length"}}"#),
			failure: .contextOverflow,
			key: Catalog.coachErrorUnknown, offersTryAgain: true,
			english: "Sorry, something went wrong. Please try again."),
		FailureRow(
			scripted: .http(status: 400), failure: .invalidRequest,
			key: Catalog.coachErrorUnknown, offersTryAgain: true,
			english: "Sorry, something went wrong. Please try again."),
		FailureRow(
			scripted: ScriptedFailure(.malformedStream),
			failure: .generationFailed(.malformedStream),
			key: Catalog.chatNoticeResponseFailure, offersTryAgain: true,
			english: "The coach couldn't respond. Please try again."),
	]
}

extension Array {
	fileprivate var only: Element? {
		count == 1 ? first : nil
	}
}
