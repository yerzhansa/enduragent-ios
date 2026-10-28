import EnduragentCoachFixtures
import Foundation
import Synchronization
import Testing

@testable import EnduragentCoach

@Suite struct SupportDiagnosticsTests {
	static let facts = StatusFacts(
		access: .credits(.ready), training: .connected, language: LanguageCode(.automatic))
	static let records = RecordCensus.counted(
		synced: [.userMessage: 3, .dailyNote: 1], local: [.turnClaim: 1],
		legacy: [.assistantMessage: 2], skipped: 1)
	static let problem = DiagnosticsEvent.recoveryUnavailable(.unavailable)

	let clock = HeldClock()
	let storage = MemoryJournalStorage()

	@Test func aboutHoldsTheIdentityThePortWasGiven() async throws {
		let identity = try #require(
			AppIdentity(name: "Enduragent Beta", version: "2.4.1", build: "907"))
		let coach = await makeCoach(
			transport: FakeModelTransport(), store: InMemoryRecordLog(),
			support: .inMemory(app: identity))
		#expect(coach.support.about == About(app: identity))
		#expect(coach.support.about.app.name == "Enduragent Beta")
		#expect(coach.support.about.app.version == "2.4.1")
		#expect(coach.support.about.app.build == "907")
		#expect(About.privacyPolicy.absoluteString == "https://enduragent.icu/privacy.html")
	}

	@Test func makingAFilePublishesPreparingThenReadyWithTheCensusWindowAndHealth() async throws {
		let rig = try rig()
		let gate = CensusGate(facts: Self.facts, records: Self.records)
		let support = Support(log: rig.log, service: rig.service, census: gate.census)
		let snapshots = await support.observe()
		rig.log.record(Self.problem)
		let making = Task { await support.makeDiagnosticsFile() }
		try await gate.waitUntilHeld()
		_ = try await supportSnapshot(in: snapshots) { $0.diagnosticsFile == .preparing }
		#expect(await support.makeDiagnosticsFile() == .preparing)
		gate.release()
		guard case .ready(let handle) = await making.value else {
			Issue.record("The file was not made")
			return
		}
		_ = try await supportSnapshot(in: snapshots) { $0.diagnosticsFile == .ready(handle) }
		#expect(try sharedFiles(in: rig.share) == [handle.url.resolvingSymlinksInPath()])
		#expect(
			try Data(contentsOf: handle.url)
				== expectedFile(lines: [
					StampedLine(at: clock.now, line: .problem(Self.problem.line))
				]))
	}

	@Test func aFileMadeFourteenDaysAndASecondLaterHoldsNoEarlierLine() async throws {
		let rig = try rig()
		let support = Support(log: rig.log, service: rig.service, census: openCensus())
		rig.log.record(Self.problem)
		let early = try await madeFile(support)
		#expect(
			try Data(contentsOf: early.url)
				== expectedFile(lines: [
					StampedLine(at: clock.now, line: .problem(Self.problem.line))
				]))
		#expect(await support.finishShare(early, .canceled) == .canceled)
		clock.advance(by: .seconds(JournalPrune.keptFor) + .seconds(1))
		let late = try await madeFile(support)
		#expect(try Data(contentsOf: late.url) == expectedFile(lines: []))
	}

	@Test(
		arguments: zip(
			[ShareOutcome.saved, ShareOutcome.shared, ShareOutcome.canceled, ShareOutcome.failed],
			[
				DiagnosticsFileState.saved, DiagnosticsFileState.shared,
				DiagnosticsFileState.canceled,
				DiagnosticsFileState.failed(.shareFailed),
			]))
	func finishingAShareRemovesTheFileAndPublishesItsOutcome(
		_ outcome: ShareOutcome, _ shown: DiagnosticsFileState
	) async throws {
		let rig = try rig()
		let support = Support(log: rig.log, service: rig.service, census: openCensus())
		let snapshots = await support.observe()
		let handle = try await madeFile(support)
		#expect(await support.finishShare(handle, outcome) == shown)
		_ = try await supportSnapshot(in: snapshots) { $0.diagnosticsFile == shown }
		#expect(!FileManager.default.fileExists(atPath: handle.url.path))
		#expect(try sharedFiles(in: rig.share).isEmpty)
	}

	@Test func aLateFinishForAnOlderHandleChangesNothing() async throws {
		let rig = try rig()
		let support = Support(log: rig.log, service: rig.service, census: openCensus())
		let older = try await madeFile(support)
		#expect(await support.finishShare(older, .canceled) == .canceled)
		let current = try await madeFile(support)
		#expect(await support.finishShare(older, .saved) == .ready(current))
		#expect(try sharedFiles(in: rig.share) == [current.url.resolvingSymlinksInPath()])
		#expect(await support.finishShare(current, .saved) == .saved)
	}

	@Test func aFileLeftInTheShareFolderIsRemovedWhenSupportOpens() throws {
		let rig = try rig()
		let left = rig.share.directory.appending(path: "01LEFTBEHIND/enduragent-diagnostics.json")
		try FileManager.default.createDirectory(
			at: left.deletingLastPathComponent(), withIntermediateDirectories: true)
		try Data("{}".utf8).write(to: left)
		#expect(try sharedFiles(in: rig.share).count == 1)
		_ = Support(log: rig.log, service: rig.service, census: openCensus())
		#expect(try sharedFiles(in: rig.share).isEmpty)
		#expect(!FileManager.default.fileExists(atPath: left.deletingLastPathComponent().path))
	}

	@Test func aFailedLogWriteAndTheNextGoodOneArePublishedWithNoCall() async throws {
		let rig = try rig()
		let support = Support(log: rig.log, service: rig.service, census: openCensus())
		let snapshots = await support.observe()
		storage.failNextWrites(1)
		rig.log.record(Self.problem)
		let failed = try await supportSnapshot(in: snapshots) { $0.journal != .saving }
		#expect(failed.journal == .notSaving(since: clock.now, firstCause: .appendFailed))
		rig.log.record(.preferencesUnavailable(.unavailable))
		let recovered = try await supportSnapshot(in: snapshots) { $0.journal == .saving }
		#expect(recovered.diagnosticsFile == .idle)
	}

	@Test func aFileMadeWhileTheLogIsNotSavingSaysSo() async throws {
		let rig = try rig()
		let support = Support(log: rig.log, service: rig.service, census: openCensus())
		storage.failNextWrites(1)
		rig.log.record(Self.problem)
		let failedAt = clock.now
		clock.advance(by: .seconds(30))
		let handle = try await madeFile(support)
		let health = JournalHealth.notSaving(since: failedAt, firstCause: .appendFailed)
		let bytes = try Data(contentsOf: handle.url)
		#expect(
			try bytes
				== expectedFile(
					journal: health,
					lines: [StampedLine(at: failedAt, line: .problem(Self.problem.line))]))
		let journal = try JSONValue.parse(String(decoding: bytes, as: UTF8.self))
			.objectFields["journal"]?.objectFields["notSaving"]?.objectFields
		#expect(journal?["firstCause"] == .string("appendFailed"))
	}

	@Test func aWriteFailureInTheShareFolderIsRecordedAndShown() async throws {
		let rig = try rig()
		let support = Support(log: rig.log, service: rig.service, census: openCensus())
		let snapshots = await support.observe()
		try #require(
			FileManager.default.createFile(atPath: rig.share.directory.path, contents: nil))
		#expect(await support.makeDiagnosticsFile() == .failed(.couldNotWrite))
		_ = try await supportSnapshot(in: snapshots) {
			$0.diagnosticsFile == .failed(.couldNotWrite)
		}
		let recorded = rig.log.entries.compactMap { entry -> DiagnosticsFileFailure? in
			guard case .diagnosticsFileFailed(let failure, _) = entry.event else { return nil }
			return failure
		}
		#expect(recorded == [.couldNotWrite])
		let written = try #require(storage.contents)
		#expect(
			String(decoding: written, as: UTF8.self).contains(#""kind":"diagnosticsFileFailed""#))
	}

	@Test func aFileFromASeededCoachHoldsNoSecretOrAthleteText() async throws {
		let openRouterKey = "sk-or-v1-" + String(repeating: "7f3a", count: 16)
		let athlete = try #require(IntervalsAthleteID(rawValue: "i1234567"))
		let intervalsKey = "intervals-test-key-7f3a"
		let sentence = "My threshold is 287 watts and the Sweet Spot Seventeen session hurt"
		let secrets = ICloudKeychainStore(backing: FixtureSecretStoreBacking())
		try secrets.installOpenRouterChoice(model: testModel, key: openRouterKey)
		try secrets.storeIntervalsConnection(
			IntervalsConnection(
				id: ConnectionID(), credential: .apiKey(intervalsKey), selection: .keyOwner,
				resolvedAthlete: athlete))
		let quoted = """
			{"error":{"code":502,"message":"\(sentence) for \(athlete.rawValue) with \(openRouterKey) and \(intervalsKey)"}}
			"""
		let requests = Mutex(0)
		let models = try OpenRouterStub.models { _ in
			let count = requests.withLock { count in
				count += 1
				return count
			}
			guard count > 1 else { return .reply(.json(502, quoted)) }
			return .reply(
				.sse(
					#"data: {"choices":[{"delta":{"content":"Noted."},"finish_reason":"stop"}]}"#
						+ "\n\ndata: [DONE]\n\n"))
		}
		let store = InMemoryRecordLog()
		let rig = try rig()
		let clock = FixedClock(now: "1998-06-13T08:00:00+02:00", timeZone: "Europe/Amsterdam")
		let ports = CoachPorts(
			records: RecordStore(
				log: SkippingLog(
					base: store, skipped: [.malformed(kind: "userMessage", ulid: openRouterKey)]),
				chain: store),
			secrets: secrets, models: models,
			training: .fake { _, _ in
				FakeIntervalsClient(athlete: .cyclist(id: athlete.rawValue, name: "Ada", ftp: 287))
			},
			credits: .fake(FakeCreditsClient()), host: ImmediateExecutionHost(), clock: clock,
			support: rig.service)
		let coach = await consentingCoach(
			Coach(
				sport: .cycling, ports: ports, builtInModel: testModel,
				displayLocale: testDisplayLocale, coalescing: quickWindow))
		guard case .completed = try await coach.sendAndSettle(sentence) else {
			Issue.record("The turn did not reply after the provider failed once")
			return
		}
		let handle = try await madeFile(coach.support)
		let bytes = try Data(contentsOf: handle.url)
		let text = String(decoding: bytes, as: UTF8.self)
		for secret in [
			openRouterKey, athlete.rawValue, intervalsKey, sentence, "Sweet Spot Seventeen",
			"287 watts",
		] {
			#expect(!text.contains(secret), "The diagnostics file holds \(secret)")
		}
		let problems = try JSONDecoder().decode(WrittenLines.self, from: bytes).lines.compactMap {
			stamped -> ProblemLine? in
			guard case .problem(let problem) = stamped.line else { return nil }
			return problem
		}
		#expect(problems.filter { $0.kind == .providerFailure }.count == 1)
		let skipped = try #require(problems.first { $0.kind == .skippedRecord }?.row)
		#expect(skipped.ulid.text == "[redacted]")
	}

	private struct WrittenLines: Decodable {
		let lines: [StampedLine]
	}

	private struct Rig {
		let service: SupportService
		let log: DiagnosticsLog
		var share: ShareFolder { service.shareFolder }
	}

	private func rig() throws -> Rig {
		let folder = try TestTemporaryFolders.make()
		try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
		let service = SupportService(
			journal: storage, shareFolder: ShareFolder(in: folder), app: .fixture, device: .fixture)
		return Rig(service: service, log: service.openLog(clock: clock))
	}

	private func openCensus() -> SupportCensus {
		SupportCensus(status: { Self.facts }, records: { Self.records })
	}

	private func madeFile(_ support: Support) async throws -> DiagnosticsFileHandle {
		guard case .ready(let handle) = await support.makeDiagnosticsFile() else {
			throw UnmadeFile()
		}
		return handle
	}

	private func expectedFile(journal: JournalHealth = .saving, lines: [StampedLine]) throws
		-> Data
	{
		try DiagnosticsFile(
			made: clock.now, app: .fixture, device: .fixture, facts: Self.facts,
			records: Self.records, journal: journal, lines: lines
		).encoded()
	}
}

struct UnmadeFile: Error {}

func supportSnapshot(
	in stream: AsyncStream<SupportSnapshot>,
	where matches: @escaping @Sendable (SupportSnapshot) -> Bool
) async throws -> SupportSnapshot {
	let found = try await beforeDeadline(within: .hangGuard) {
		await stream.first(where: matches)
	}
	return try #require(found ?? nil, "No snapshot matched before the hang guard expired")
}

func sharedFiles(in share: ShareFolder) throws -> [URL] {
	guard
		let walk = FileManager.default.enumerator(
			at: share.directory, includingPropertiesForKeys: [.isRegularFileKey])
	else { return [] }
	var found: [URL] = []
	for case let url as URL in walk {
		guard try url.resourceValues(forKeys: [.isRegularFileKey]).isRegularFile == true else {
			continue
		}
		found.append(url.resolvingSymlinksInPath())
	}
	return found
}
