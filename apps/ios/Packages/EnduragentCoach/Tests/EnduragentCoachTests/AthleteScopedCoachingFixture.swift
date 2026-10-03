import EnduragentCoachFixtures
import Foundation
import Testing

@testable import EnduragentCoach

struct AthleteScopedCoachingFixture {
	let clock = FixedClock(now: "1998-06-13T12:00:00+02:00", timeZone: "Europe/Amsterdam")
	let transport = FakeModelTransport()
	let secrets: ICloudKeychainStore
	let peer: FixtureTrainingPeer
	let accountA: TrainingAccount
	let accountB: TrainingAccount
	let store: any RecordLog

	init(store: any RecordLog) throws {
		self.store = store
		let backing = FixtureSecretStoreBacking()
		secrets = keyedSecrets(backing: backing)
		peer = FixtureTrainingPeer(
			secrets: ICloudKeychainStore(backing: backing),
			athleteA: FakeIntervalsClient(athleteName: "Fixture A", ftp: 220, athleteId: "i1001"))
		accountA = testConnection.account
		accountB = .intervals(
			connection: ConnectionID(), athlete: IntervalsAthleteID(rawValue: "i2002"))
	}

	func open(store: (any RecordLog)? = nil) async -> Coach {
		var ports = CoachPorts(
			records: RecordStore(log: store ?? self.store), secrets: secrets,
			models: .scripted(transport),
			training: .fake { credential, _ in peer.client(for: credential) },
			credits: .fake(FakeCreditsClient()), host: ImmediateExecutionHost(), clock: clock)
		ports.watchdogSleep = HeldClock().sleep
		return await consentingCoach(
			Coach(
				sport: .cycling, ports: ports, builtInModel: testModel,
				displayLocale: testDisplayLocale, coalescing: quickWindow))
	}

	func connect(_ key: FixtureTrainingPeer.Key, using coach: Coach) async throws {
		guard
			case .replaced = await coach.changeTraining(
				.replace(apiKey: key.secret, athlete: .keyOwner))
		else {
			Issue.record("Fixture connection was not replaced")
			return
		}
	}

	func read(using coach: Coach, question: String = "Read my saved information") async throws
		-> CompletionRequest
	{
		transport.respond = ScriptedReply.sequence(
			[
				.toolCall(
					name: "memory_query", arguments: #"{"from":"1998-06-13","to":"1998-06-13"}"#),
				.toolCall(name: "memory_read", arguments: "{}"), .finish(reason: .toolCalls),
				.text("Scoped information read."), .finish(reason: .stop),
			], for: .chat, otherwise: { _ in ScriptedReply([.finish(reason: .stop)]) })
		#expect(replyText(try await coach.sendAndSettle(question)) == "Scoped information read.")
		return try #require(sent(.chatAttempt, by: transport).last)
	}

	func assertInformation(_ label: String, excluding other: String, in request: CompletionRequest)
		throws
	{
		let system = try #require(request.messages.first { $0.role == .system }).content
		#expect(system.contains("\(label)_FACT"))
		#expect(system.contains("\(label)_DAILY"))
		#expect(system.contains("\(label)_EVENT"))
		#expect(request.messages.contains { $0.content.contains("\(label)_SUMMARY") })
		#expect(request.messages.contains { $0.content.contains("\(label)_QUESTION") })
		#expect(request.messages.contains { $0.content.contains("\(label)_REPLY") })
		let query = try toolText("memory_query", in: request)
		#expect(query.contains("\(label)_DAILY"))
		#expect(query.contains("\(label)_EVENT"))
		#expect(query.contains("\(label)_JOURNAL"))
		#expect(try toolText("memory_read", in: request).contains("\(label)_HIDDEN"))
		assertAbsent(other, from: request)
	}

	func assertAbsent(_ text: String, from request: CompletionRequest) {
		#expect(request.messages.allSatisfy { !$0.content.contains(text) })
		#expect(request.tools.allSatisfy { !$0.parameters.canonicalDigestInput().contains(text) })
	}

	func toolText(_ name: String, in request: CompletionRequest) throws -> String {
		let call = try #require(request.messages.flatMap(\.toolCalls).first { $0.name == name })
		let message = try #require(
			request.messages.first { $0.role == .tool && $0.toolCallId == call.id })
		return try #require(JSONValue.parse(message.content).objectFields["data"]?.stringValue)
	}

	@discardableResult
	func seedInformation(
		_ label: String, account: TrainingAccount, offset: Int,
		device: DeviceID? = nil, reply: String? = nil
	) async throws -> [AthleteRecord] {
		let turn = TurnID(ulid: fixedUlid(offset + 1))
		let bodies: [RecordBody] = [
			.synced(sampleUser(chatId: .main, text: "\(label)_QUESTION", turn: turn)),
			.synced(sampleReply(chatId: .main, turn: turn, text: reply ?? "\(label)_REPLY")),
			.synced(
				.memorySection(
					MemorySectionBody(
						name: .person, content: "_updated: 1998-06-13\n- \(label)_FACT"))),
			.synced(
				.memorySection(
					MemorySectionBody(
						name: .notes, content: "_updated: 1998-06-13\n- \(label)_HIDDEN"))),
			.synced(.dailyNote(DailyNoteBody(note: "\(label)_DAILY"))),
			.synced(
				.ledgerEvent(
					LedgerEventBody(
						date: "1998-06-13", kind: .decision,
						text: "\(label)_EVENT", source: .chat))),
			.synced(.journal(JournalBody(op: .writeSection, preview: "\(label)_JOURNAL"))),
			.synced(
				.compactionSummary(
					CompactionSummaryBody(chatId: .main, markdown: "\(label)_SUMMARY"))),
		]
		let records = bodies.enumerated().map { index, body in
			storedRecord(
				device: device ?? store.deviceId, wall: Int64(offset + index + 1),
				ulid: fixedUlid(offset + index + 1), account: account, body: body)
		}
		try await seed(store, records)
		return records
	}

	func record(
		_ index: Int, account: TrainingAccount, body: RecordBody, device: DeviceID? = nil,
		cause: RecordCause = .legacy
	) -> AthleteRecord {
		storedRecord(
			device: device ?? store.deviceId, wall: Int64(index), ulid: fixedUlid(index),
			cause: cause, account: account, body: body)
	}
}
