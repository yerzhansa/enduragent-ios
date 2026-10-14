import EnduragentCoachFixtures
import Foundation
import Synchronization
import Testing

@testable import EnduragentCoach

extension IntervalsRESTClientTests {
	@Suite struct SnapshotNpmParityTests {
		@Test func snapshotTextMatchesNpmOutsideTheNamedDifferences() async throws {
			let cases = try SnapshotCase.all()
			#expect(cases.count == 43)
			for sample in cases {
				let clock = FixedClock(
					now: "\(sample.today)T12:00:00+02:00", timeZone: "Europe/Amsterdam")
				let snapshot = try await liveSnapshot(clock: clock) { url in
					let read = url.path.contains("/wellness") ? sample.wellness : sample.athlete
					return read.map { (200, $0) } ?? (503, Data())
				}

				#expect(
					PromptAssembly.snapshotSection(snapshot) == sample.phone ?? sample.npm,
					"\(sample.name)")
				if let difference = sample.difference {
					#expect((2...6).contains(difference), "\(sample.name)")
					#expect(sample.phone != sample.npm, "\(sample.name)")
				}
			}
		}

		@Test func wellnessIsReadForSevenDaysEndingOnThePhonesToday() async throws {
			let clock = FixedClock(now: "1998-06-13T00:30:00+02:00", timeZone: "Europe/Amsterdam")
			let queries = Mutex<[String]>([])

			_ = try await liveSnapshot(clock: clock) { url in
				if url.path.contains("/wellness") {
					queries.withLock { $0.append(url.query ?? "") }
				}
				return (200, Data("[]".utf8))
			}

			#expect(queries.withLock { $0 } == ["oldest=1998-06-07&newest=1998-06-13"])
		}

		@Test(arguments: [401, 403])
		func rejectedKeyFailsBothReadsAndGivesTheFallback(status: Int) async throws {
			let clock = FixedClock(now: "1998-06-13T08:00:00+02:00", timeZone: "Europe/Amsterdam")
			let diagnostics = DiagnosticsLog(clock: clock)
			let attempt = AttemptID(ulid: fixedUlid(1))

			let snapshot = try await liveSnapshot(
				clock: clock, diagnostics: diagnostics, attempt: attempt
			) { _ in (status, Data(#"{"error":"Unauthorized"}"#.utf8)) }

			#expect(snapshot == .unavailable(.nothingUsable))
			#expect(PromptAssembly.snapshotSection(snapshot) == PromptStaticBlocks.snapshotFallback)
			#expect(
				diagnostics.entries.map(\.event) == [
					.snapshotReadFailed(attempt, .profile, .credentialRejected),
					.snapshotReadFailed(attempt, .wellness, .credentialRejected),
				])
		}

		@Test(arguments: [401, 403])
		func keyRejectedBeforeTheIdentityCheckStopsTheTurnBeforeTheSnapshot(status: Int)
			async throws
		{
			let transport = FakeModelTransport()
			let coach = try await liveCoach(transport: transport) { _ in (status, Data()) }

			let settled = try await coach.sendAndSettle("How is my form?")

			#expect(
				failure(settled)
					== .model(.accessUnavailable(.trainingIdentityUnverified(.credentialRejected))))
			#expect(transport.requests.isEmpty)
			#expect(coach.diagnostics.entries.isEmpty)
		}

		@Test(arguments: [401, 403])
		func keyRejectedAfterTheIdentityCheckGivesTheTurnTheFallback(status: Int) async throws {
			let transport = FakeModelTransport()
			transport.respond = ScriptedReply.sequence(
				[.text("Easy spin today."), .finish(reason: .stop)], for: .chat,
				otherwise: transport.respond)
			let rejecting = Mutex(false)
			let coach = try await liveCoach(transport: transport) { url in
				if rejecting.withLock({ $0 }) { return (status, Data()) }
				return (
					200,
					try fixtureData(
						url.path.contains("/wellness") ? "intervals-wellness" : "intervals-athlete")
				)
			}
			_ = try await coach.vault.trainingConnection()
			rejecting.withLock { $0 = true }

			let settled = try await coach.sendAndSettle("How is my form?")

			#expect(replyText(settled) == "Easy spin today.")
			let request = try #require(transport.requests.first)
			let system = try #require(request.messages.first?.content)
			#expect(
				system.contains(
					PromptStaticBlocks.snapshotFallback + PromptAssembly.sectionSeparator))
			#expect(
				coach.diagnostics.entries.map(\.event) == [
					.snapshotReadFailed(request.attempt, .profile, .credentialRejected),
					.snapshotReadFailed(request.attempt, .wellness, .credentialRejected),
				])
		}

		private func liveSnapshot(
			clock: FixedClock, diagnostics: DiagnosticsLog? = nil,
			attempt: AttemptID = AttemptID(ulid: fixedUlid(1)),
			answer: @escaping @Sendable (URL) throws -> (Int, Data)
		) async throws -> TrainingSnapshot {
			let client = try stubbedClient(clock: clock, answer: answer)
			let reader = TrainingSnapshotReader(
				clock: clock, deadlineSleep: HeldClock().sleep,
				diagnostics: diagnostics ?? DiagnosticsLog(clock: clock))
			return try await reader.snapshot(
				for: connectedTraining(client),
				attempt: attempt)
		}

		private func liveCoach(
			transport: FakeModelTransport,
			answer: @escaping @Sendable (URL) throws -> (Int, Data)
		) async throws -> Coach {
			let clock = FixedClock(now: "1998-06-13T08:00:00+02:00", timeZone: "Europe/Amsterdam")
			return await makeCoach(
				transport: transport, intervals: try stubbedClient(clock: clock, answer: answer),
				store: InMemoryRecordLog(), clock: clock)
		}

		private func stubbedClient(
			clock: FixedClock, answer: @escaping @Sendable (URL) throws -> (Int, Data)
		) throws -> IntervalsRESTClient {
			let client = try IntervalsRESTClientTests().makeClient(clock: clock)
			IntervalsURLProtocolStub.handler = { request in try answer(try #require(request.url)) }
			return client
		}
	}
}

struct SnapshotCase: Sendable {
	let name: String
	let today: String
	let athlete: Data?
	let wellness: Data?
	let npm: String
	let phone: String?
	let difference: Int?

	static func all() throws -> [SnapshotCase] {
		let text = try #require(
			String(data: try fixtureData("snapshot-npm-cases"), encoding: .utf8))
		return try #require(try JSONValue.parse(text).arrayValue).map { entry in
			let fields = entry.objectFields
			return SnapshotCase(
				name: try #require(fields["name"]?.stringValue),
				today: try #require(fields["today"]?.stringValue),
				athlete: try response(in: fields["athlete"]),
				wellness: try response(in: fields["wellness"]),
				npm: try #require(fields["npm"]?.stringValue),
				phone: fields["phone"]?.stringValue,
				difference: fields["difference"]?.intValue())
		}
	}

	private static func response(in read: JSONValue?) throws -> Data? {
		let fields = try #require(read).objectFields
		if fields["failed"] == .bool(true) { return nil }
		return Data(canonicalJSON(try #require(fields["response"])).utf8)
	}
}
