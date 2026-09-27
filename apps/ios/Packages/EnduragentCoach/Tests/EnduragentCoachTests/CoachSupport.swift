import Foundation
import Synchronization
import Testing

@testable import EnduragentCoach

let quickWindow = CoalescingPolicy(window: .milliseconds(20))
let testModel = ModelID(rawValue: "test/coach-model")
let testKey = "sk-or-test-credits-key"
let testAccess = ResolvedAccess(
	credential: ProviderCredential(secret: testKey, method: .credits), model: testModel)

func keyedSecrets(_ key: String = testKey) -> FakeSecretStore {
	let secrets = FakeSecretStore()
	do {
		try secrets.storeOpenRouterKey(key)
	} catch {
		Issue.record(error)
	}
	return secrets
}

func testRequest(
	_ messages: [WireMessage], tools: [ToolSchema] = [], deadline: Duration = .seconds(600),
	attempt: AttemptID = AttemptID(ulid: fixedUlid(900))
) -> CompletionRequest {
	CompletionRequest(
		access: testAccess, attempt: attempt, charge: .chatAttempt, messages: messages,
		tools: tools, deadline: deadline)
}

func makeCoach(
	transport: FakeModelTransport,
	intervals: FakeIntervalsClient = FakeIntervalsClient(athleteName: "Ada", ftp: 250),
	store: any RecordLog,
	clock: any Clock = FixedClock(now: "1998-06-13T08:00:00+02:00", timeZone: "Europe/Amsterdam"),
	coalescing: CoalescingPolicy = quickWindow,
	secrets: any SecretStore = keyedSecrets(),
	host: any ExecutionHost = ImmediateExecutionHost()
) -> Coach {
	Coach(
		sport: .cycling,
		models: .scripted(transport),
		builtInModel: testModel,
		secrets: secrets,
		intervals: intervals,
		store: store,
		clock: clock,
		language: .init(ui: .en, coachReply: nil),
		host: host,
		coalescing: coalescing
	)
}

func draft(_ text: String) -> Draft {
	Draft(id: DraftID(), text: text)
}

extension Coach {
	func sendAndSettle(
		_ text: String, in chat: ChatID = .main, within limit: Duration = .seconds(30)
	) async throws -> TurnState {
		let turn = try #require(try await send(draft(text), to: chat).acceptedTurn)
		return try #require(await settledState(of: turn, in: chat, within: limit))
	}

	func waitUntilProcessing(_ turn: TurnID, in chat: ChatID = .main) async {
		for await snapshot in await observe(chat) {
			if case .processing? = snapshot.turns.first(where: { $0.id == turn })?.state {
				return
			}
		}
	}

	func waitForLiveText(_ turn: TurnID, in chat: ChatID = .main) async {
		for await snapshot in await observe(chat) {
			if case .processing(let processing)? = snapshot.turns.first(where: { $0.id == turn })?
				.state, !processing.liveText.isEmpty
			{
				return
			}
		}
	}

	func state(of turn: TurnID, in chat: ChatID = .main) async -> TurnState? {
		await currentSnapshot(chat)?.turns.first(where: { $0.id == turn })?.state
	}

	func interruption(of turn: TurnID) async -> InterruptionCause? {
		guard case .interrupted(let interrupted)? = await state(of: turn) else { return nil }
		return interrupted.cause
	}

	func waitForState(
		of turn: TurnID, within limit: Duration = .seconds(5), until matches: (TurnState?) -> Bool
	) async throws -> TurnState? {
		let deadline = ContinuousClock.now + limit
		while ContinuousClock.now < deadline {
			let current = await state(of: turn)
			if matches(current) { return current }
			try await Task.sleep(for: .milliseconds(10))
		}
		return await state(of: turn)
	}

	func dieWithoutWriting(to log: FaultInjectingRecordLog) async {
		for kind in SyncedKind.allCases {
			log.failAppends(ofKind: kind)
		}
		for kind in DeviceLocalKind.allCases {
			log.failAppends(ofKind: kind)
		}
		await lifecycle(.willTerminate)
	}
}

func waitUntil(within limit: Duration = .seconds(5), _ condition: () -> Bool) async throws {
	let deadline = ContinuousClock.now + limit
	while !condition() {
		guard ContinuousClock.now < deadline else {
			Issue.record("condition never held")
			return
		}
		try await Task.sleep(for: .milliseconds(10))
	}
}

func settlements(of turn: TurnID, in store: any RecordLog) async throws -> [Settlement] {
	try await store.fetch(RecordQuery(scope: .synced([.turnSettled]), turn: turn)).records
		.compactMap { record in
			guard case .synced(.turnSettled(let body)) = record.body else { return nil }
			return body.settlement
		}
}

func claims(of turn: TurnID, in store: any RecordLog) async throws -> [AthleteRecord] {
	try await store.fetch(RecordQuery(scope: .deviceLocal([.turnClaim]), turn: turn)).records
}

func waitForRecords(
	_ scope: RecordQuery.Scope, count: Int, in store: any RecordLog,
	within limit: Duration = .seconds(5)
) async throws {
	let deadline = ContinuousClock.now + limit
	while try await store.fetch(RecordQuery(scope: scope)).records.count < count {
		guard ContinuousClock.now < deadline else {
			Issue.record("\(scope) never reached \(count) records")
			return
		}
		try await Task.sleep(for: .milliseconds(10))
	}
}

func refusal(_ retry: @Sendable () async throws(RetryRefusal) -> Void) async -> RetryRefusal? {
	do {
		try await retry()
		return nil
	} catch {
		return error
	}
}

func replyText(_ state: TurnState) -> String? {
	guard case .completed(let completed) = state, case .model(let text) = completed.reply else {
		return nil
	}
	return text
}

func isInterrupted(_ state: TurnState) -> Bool {
	guard case .interrupted = state else { return false }
	return true
}

func failure(_ state: TurnState) -> CoachFailure? {
	guard case .failed(let failed) = state else { return nil }
	return failed.failure
}

func historyBudget(clock: any Clock) -> Int {
	let volatile = PromptAssembly.volatile(
		context: "",
		snapshot: nil,
		timeZoneName: clock.timeZone.identifier,
		replyLanguage: PromptAssembly.replyLanguageSection(
			resolution: LanguageResolution(language: .en, source: .surface, locale: "en"))
	)
	let system = PromptAssembly.cyclingPrefix(gated: true) + "\n\n" + volatile
	return HistoryWindow.historyTokenBudget(
		systemTokens: estimateTokens(system), window: TurnPolicy.contextWindowCap,
		ratio: TurnPolicy.historyTokenBudgetRatio)
}

struct SeededTurn {
	let turn: TurnID
	let user: ULID
	let reply: ULID
}

@discardableResult
func seedHistory(
	_ store: any RecordLog, clock: any Clock, turns count: Int, tokens: Int,
	chat: ChatID = .main
) async throws -> [SeededTurn] {
	let replyChars = Int(Double(tokens / count) / 1.2 * 4)
	var seeded: [SeededTurn] = []
	for index in 0..<count {
		let asked = clock.now.addingTimeInterval(TimeInterval(-60 * (count - index)))
		let answered = asked.addingTimeInterval(1)
		let user = ULID.generate(at: asked)
		let reply = ULID.generate(at: answered)
		let turn = TurnID(ulid: user)
		try await seed(
			store,
			[
				seededRecord(
					store, at: asked, ulid: user,
					body: .synced(sampleUser(chatId: chat, text: "Question \(index)", turn: turn))),
				seededRecord(
					store, at: answered, ulid: reply,
					body: .synced(
						sampleReply(
							chatId: chat, turn: turn,
							text: "Answer \(index) " + String(repeating: "w", count: replyChars)))),
			])
		seeded.append(SeededTurn(turn: turn, user: user, reply: reply))
	}
	return seeded
}

func seededRecord(_ store: any RecordLog, at date: Date, ulid: ULID, body: RecordBody)
	-> AthleteRecord
{
	AthleteRecord(
		ulid: ulid,
		deviceId: store.deviceId,
		hlc: HybridLogicalClock(
			wallMs: Int64((date.timeIntervalSince1970 * 1_000).rounded(.down)), logical: 0,
			deviceId: store.deviceId),
		timeZone: amsterdamZone,
		civilDate: "1998-06-13",
		cause: .legacy,
		account: .unconnected,
		body: body
	)
}

func sent(_ charge: GenerateCharge, by transport: FakeModelTransport) -> [CompletionRequest] {
	transport.requests.filter { $0.charge == charge }
}
