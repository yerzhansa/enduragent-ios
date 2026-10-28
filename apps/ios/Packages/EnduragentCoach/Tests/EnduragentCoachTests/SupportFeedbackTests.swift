import EnduragentCoachFixtures
import Foundation
import Testing

@testable import EnduragentCoach

@Suite struct SupportFeedbackTests {
	struct RelaunchCase: Sendable, CustomTestStringConvertible {
		let kept: KeptPhase
		let shown: FeedbackStatus
		let saved: KeptPhase

		var testDescription: String { "\(kept)" }
	}

	static let relaunchCases = [
		RelaunchCase(kept: .ready, shown: .notSent(.stopped), saved: .notSent(.stopped)),
		RelaunchCase(kept: .sending, shown: .notConfirmed, saved: .notConfirmed),
		RelaunchCase(kept: .notSent(.busy), shown: .notSent(.busy), saved: .notSent(.busy)),
		RelaunchCase(kept: .notConfirmed, shown: .notConfirmed, saved: .notConfirmed),
	]

	static let text = "The long ride on Sunday left no time to recover."

	let clock = HeldClock()
	let folder: URL

	init() throws {
		folder = try TestTemporaryFolders.make()
	}

	@Test func theTraceScriptIsReceivedOnTryAgainWithOneStoredNote() async throws {
		let server = FakeFeedbackServer(script: try script("lost,lost"))
		let rig = rig(server)
		#expect(try await rig.support.send(Self.text) == .notConfirmed)
		#expect(server.requestCount == 2)
		#expect(server.storedCount == 1)
		#expect(await rig.support.tryAgain() == receivedOutcome)
		#expect(server.requestCount == 3)
		#expect(Set(try server.requests.map { try $0.note().id }).count == 1)
		#expect(server.storedCount == 1)
		#expect(!FileManager.default.fileExists(atPath: rig.file.file.path))
	}

	@Test func tryAgainAfterNotConfirmedStaysNotConfirmedWhenOffline() async throws {
		let server = FakeFeedbackServer(script: try script("lost,lost,offline,offline"))
		let rig = rig(server)
		#expect(try await rig.support.send(Self.text) == .notConfirmed)
		#expect(await rig.support.tryAgain() == .notConfirmed)
		#expect(server.requestCount == 4)
		#expect(Set(try server.requests.map { try $0.note().id }).count == 1)
		#expect(try rig.file.load()?.phase == .notConfirmed)
	}

	@Test func theNoteIsKeptReadyThenSendingBeforeTheFirstRequest() async throws {
		let server = FakeFeedbackServer()
		let spy = MemoryKeptNoteStorage(watching: server)
		let rig = rig(server, notes: spy)
		#expect(try await rig.support.send(Self.text) == receivedOutcome)
		#expect(spy.saves.map(\.phase) == [.ready, .sending])
		#expect(spy.saves.map(\.requestsBefore) == [0, 0])
		#expect(server.requestCount == 1)
	}

	@Test(arguments: relaunchCases)
	func aRelaunchShowsWhatTheKeptPhaseProves(_ relaunch: RelaunchCase) async throws {
		let server = FakeFeedbackServer()
		let note = FeedbackNote.first(try FeedbackText(validating: Self.text))
		let file = FileKeptNoteStorage(directory: folder)
		try file.save(KeptNote(note: note, phase: relaunch.kept))
		let support = rig(server).support
		let shown = try await supportSnapshot(in: await support.observe()) { _ in true }
		#expect(shown.feedback == relaunch.shown)
		#expect(shown.keptText == Self.text)
		#expect(try file.load() == KeptNote(note: note, phase: relaunch.saved))
		#expect(server.requestCount == 0)
	}

	@Test func tryAgainAfterARelaunchResendsTheKeptId() async throws {
		let server = FakeFeedbackServer()
		let note = FeedbackNote.first(try FeedbackText(validating: Self.text))
		_ = await server.client.deliver(note)
		let file = FileKeptNoteStorage(directory: folder)
		try file.save(KeptNote(note: note, phase: .sending))
		let support = rig(server).support
		let shown = try await supportSnapshot(in: await support.observe()) { _ in true }
		#expect(shown.feedback == .notConfirmed)
		#expect(await support.tryAgain() == receivedOutcome)
		#expect(try server.requests.dropFirst().map { try $0.note().id } == [note.id.rawValue])
		#expect(server.storedCount == 1)
		#expect(!FileManager.default.fileExists(atPath: file.file.path))
	}

	@Test func sendWithTheKeptTextAfterNotConfirmedStaysNotConfirmed() async throws {
		let server = FakeFeedbackServer(script: try script("lost,lost,offline,offline"))
		let rig = rig(server)
		#expect(try await rig.support.send(Self.text) == .notConfirmed)
		let kept = try #require(try rig.file.load()?.note.id.rawValue)
		#expect(try await rig.support.send(Self.text) == .notConfirmed)
		#expect(try server.requests.map { try $0.note().id } == Array(repeating: kept, count: 4))
	}

	@Test func editedTextStartsClean() async throws {
		let server = FakeFeedbackServer(script: try script("lost,lost,offline,offline"))
		let rig = rig(server)
		#expect(try await rig.support.send(Self.text) == .notConfirmed)
		#expect(
			try await rig.support.send(Self.text + " Wednesday too.") == .notSent(.noConnection))
		let ids = try server.requests.map { try $0.note().id }
		#expect(ids.count == 4)
		#expect(ids[2] == ids[3])
		#expect(ids[2] != ids[0])
		let kept = try #require(try rig.file.load())
		#expect(kept.note.id.rawValue == ids[2])
		#expect(kept.phase == .notSent(.noConnection))
	}

	@Test(arguments: [
		("", FeedbackRefusal.empty), (" \n\u{FEFF}", .empty), ("ride\u{0}", .containsNul),
		(String(repeating: "a", count: FeedbackRefusal.limit + 1), .tooLong(units: 4_001)),
	])
	func aRefusedTextIsNeitherKeptNorSent(_ draft: String, _ refusal: FeedbackRefusal)
		async throws
	{
		let server = FakeFeedbackServer()
		let spy = MemoryKeptNoteStorage(watching: server)
		let rig = rig(server, notes: spy)
		await #expect(throws: refusal) { try await rig.support.send(draft) }
		#expect(spy.saves.isEmpty)
		#expect(server.requestCount == 0)
		let shown = try await supportSnapshot(in: await rig.support.observe()) { _ in true }
		#expect(shown.feedback == .idle)
		#expect(shown.keptText == nil)
	}

	@Test(arguments: [
		("503,503", [AttemptAnswer.unavailable, .unavailable], "unavailable.unavailable"),
		("502", [.mayHaveLeft(.serverStatus(502))], "mayHaveLeft.serverStatus(502)"),
		(
			"offline,timeout",
			[.neverLeft(.notConnectedToInternet), .mayHaveLeft(.transport(.timedOut))],
			"neverLeft(-1009).mayHaveLeft.transport(-1001)"
		),
	])
	func anUndeliveredNoteRecordsEachAnswer(
		_ words: String, _ answers: [AttemptAnswer], _ cause: String
	) async throws {
		let server = FakeFeedbackServer(script: try script(words))
		let rig = rig(server)
		_ = try await rig.support.send(Self.text)
		#expect(rig.log.entries.map(\.event) == [.feedbackNotDelivered(answers: answers)])
		#expect(rig.log.entries.first?.event.line.cause?.rawValue == cause)
	}

	@Test func aReceivedNoteRecordsNothing() async throws {
		let server = FakeFeedbackServer(script: try script("503,204"))
		let rig = rig(server)
		#expect(try await rig.support.send(Self.text) == receivedOutcome)
		#expect(rig.log.entries.isEmpty)
	}

	@Test func aKeptNoteThatCannotBeSavedIsRecordedAndStillSent() async throws {
		let server = FakeFeedbackServer()
		let spy = MemoryKeptNoteStorage(watching: server)
		spy.failSaves()
		let rig = rig(server, notes: spy)
		#expect(try await rig.support.send(Self.text) == receivedOutcome)
		#expect(server.requestCount == 1)
		#expect(server.storedCount == 1)
		let unsaved = DiagnosticsEvent.feedbackNoteUnsaved(
			FailureCode(CocoaError(.fileWriteOutOfSpace)))
		#expect(rig.log.entries.map(\.event) == [unsaved, unsaved])
	}

	@Test func aSecondSendDuringDeliveryJoinsIt() async throws {
		let server = FakeFeedbackServer()
		let spy = MemoryKeptNoteStorage(watching: server)
		let rig = rig(server, notes: spy)
		server.hold()
		let (first, second) = await rig.support.sendTwice(Self.text)
		server.release()
		let outcomes = try await beforeDeadline(within: .hangGuard) {
			[try await first.value, try await second.value]
		}
		#expect(outcomes == [receivedOutcome, receivedOutcome])
		#expect(server.requestCount == 1)
		#expect(spy.saves.filter { $0.phase == .ready }.count == 1)
	}

	@Test func cancelingTheCallerDoesNotCancelDelivery() async throws {
		let server = FakeFeedbackServer()
		let rig = rig(server)
		let snapshots = await rig.support.observe()
		server.hold()
		let caller = Task { try await rig.support.send(Self.text) }
		_ = try await supportSnapshot(in: snapshots) { $0.feedback == .sending }
		caller.cancel()
		server.release()
		_ = try await supportSnapshot(in: snapshots) { $0.feedback == .received }
		#expect(try await caller.value == receivedOutcome)
		#expect(server.requestCount == 1)
		#expect(!FileManager.default.fileExists(atPath: rig.file.file.path))
	}

	private struct Rig {
		let support: Support
		let log: DiagnosticsLog
		let file: FileKeptNoteStorage
	}

	private func rig(_ server: FakeFeedbackServer, notes: (any KeptNoteStorage)? = nil) -> Rig {
		let file = FileKeptNoteStorage(directory: folder)
		let service = SupportService(
			journal: MemoryJournalStorage(), keptNotes: notes ?? file,
			shareFolder: ShareFolder(in: folder), feedback: server.client, app: .fixture,
			device: .fixture)
		let log = service.openLog(clock: clock)
		let support = Support(
			log: log, service: service,
			census: SupportCensus(
				status: { SupportDiagnosticsTests.facts },
				records: { SupportDiagnosticsTests.records }))
		return Rig(support: support, log: log, file: file)
	}
}

extension Support {
	fileprivate func sendTwice(_ draft: String) -> (
		Task<FeedbackOutcome, any Error>, Task<FeedbackOutcome, any Error>
	) {
		let first = Task { try await send(draft) }
		let second = Task { try await send(draft) }
		return (first, second)
	}
}
