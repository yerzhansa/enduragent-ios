import Foundation
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
	secrets: any SecretStore = keyedSecrets()
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
}

func replyText(_ state: TurnState) -> String? {
	guard case .completed(let completed) = state, case .model(let text) = completed.reply else {
		return nil
	}
	return text
}

func failure(_ state: TurnState) -> CoachFailure? {
	guard case .failed(let failed) = state else { return nil }
	return failed.failure
}

final class BatchRecordingLog: RecordLog, @unchecked Sendable {
	let inner: any RecordLog
	private(set) var batches: [[String]] = []

	init(inner: any RecordLog) {
		self.inner = inner
	}

	var deviceId: DeviceID { inner.deviceId }

	func append(_ batch: [AthleteRecord], locality: RecordLocality) async throws {
		batches.append(batch.map(\.body.kind))
		try await inner.append(batch, locality: locality)
	}

	func fetch(_ query: RecordQuery) async throws -> RecordPage {
		try await inner.fetch(query)
	}

	var imports: AsyncStream<Void> { inner.imports }
}
