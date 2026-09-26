import Foundation
import Testing

@testable import EnduragentCoach

extension SwiftDataSuites {
	@Suite struct AcceptTests {
		let transport = FakeModelTransport()
		let clock = FixedClock(now: "1998-06-13T08:00:00+02:00", timeZone: "Europe/Amsterdam")

		@Test func acceptWritesUserMessageBeforeAnyModelRequest() async throws {
			transport.script = [.text("Two rides."), .finish(reason: .stop)]
			let recording = BatchRecordingLog(inner: InMemoryRecordLog())
			let coach = makeCoach(transport: transport, store: recording, clock: clock)
			let outcome = try await coach.send(draft("How was my week?"), to: .main)
			let turn = try #require(outcome.acceptedTurn)
			#expect(recording.batches == [["userMessage"]])
			#expect(transport.requests.isEmpty)
			let snapshot = try #require(await coach.currentSnapshot(.main))
			#expect(snapshot.turns.map(\.id) == [turn])
			#expect(snapshot.turns.first?.athleteText == "How was my week?")
			let rows = try await recording.fetch(
				RecordQuery(scope: .synced([.userMessage]), chatId: .main)
			).records
			#expect(rows.count == 1)
			#expect(rows.first?.body.turn == turn)
			#expect(
				replyText(try #require(await coach.settledState(of: turn, in: .main)))
					== "Two rides.")
			#expect(
				recording.batches == [
					["userMessage"], ["turnClaim"], ["replyObserved"], ["turnSettled"],
				])
		}

		@Test func acceptWithKnownDraftIdWritesNothingAndReturnsTheTurn() async throws {
			let recording = BatchRecordingLog(inner: InMemoryRecordLog())
			let coach = makeCoach(
				transport: transport, store: recording, clock: clock,
				coalescing: CoalescingPolicy(window: .seconds(60)))
			let sent = draft("How was my week?")
			let first = try #require(try await coach.send(sent, to: .main).acceptedTurn)
			let second = try #require(try await coach.send(sent, to: .main).acceptedTurn)
			#expect(first == second)
			#expect(recording.batches == [["userMessage"]])
			let snapshot = try #require(await coach.currentSnapshot(.main))
			#expect(snapshot.turns.count == 1)
		}

		@Test func concurrentAcceptsOfOneDraftWriteOneMessage() async throws {
			let recording = BatchRecordingLog(inner: InMemoryRecordLog())
			let coach = makeCoach(
				transport: transport, store: recording, clock: clock,
				coalescing: CoalescingPolicy(window: .seconds(60)))
			let sent = draft("How was my week?")
			async let first = coach.send(sent, to: .main)
			async let second = coach.send(sent, to: .main)
			let outcomes = try await [first, second]
			#expect(outcomes[0] == outcomes[1])
			#expect(recording.batches == [["userMessage"]])
			#expect(try #require(await coach.currentSnapshot(.main)).turns.count == 1)
		}

		@Test func aFragmentSavedWhileTheWindowClosesReachesTheModel() async throws {
			transport.script = [.text("Both days are on."), .finish(reason: .stop)]
			let slow = SlowAppendLog(inner: InMemoryRecordLog(), delay: .milliseconds(200))
			let coach = makeCoach(
				transport: transport, store: slow, clock: clock,
				coalescing: CoalescingPolicy(window: .milliseconds(300)))
			let first = try #require(
				try await coach.send(draft("Thursday?"), to: .main).acceptedTurn)
			try await Task.sleep(for: .milliseconds(200))
			let second = try #require(
				try await coach.send(draft("Friday?"), to: .main).acceptedTurn)
			_ = try #require(await coach.settledState(of: first, in: .main))
			_ = try #require(await coach.settledState(of: second, in: .main))
			let snapshot = try #require(await coach.currentSnapshot(.main))
			let requested = transport.requests.compactMap {
				$0.messages.last(where: { $0.role == .user })?.content
			}
			#expect(requested.count == snapshot.turns.count)
			for turn in snapshot.turns {
				let text = try #require(turn.athleteText)
				#expect(
					requested.contains { $0.hasPrefix(text) },
					"turn \(text) never reached the model: \(requested)")
			}
		}

		@Test func acceptWithFailingLedgerThrowsStorageUnavailable() async throws {
			let store = FaultInjectingRecordLog(wrapping: InMemoryRecordLog())
			store.failNextAppend = true
			let coach = makeCoach(transport: transport, store: store, clock: clock)
			await #expect(throws: AcceptFailure.storageUnavailable) {
				try await coach.send(draft("How was my week?"), to: .main)
			}
			let snapshot = try #require(await coach.currentSnapshot(.main))
			#expect(snapshot.turns.isEmpty)
			#expect(transport.requests.isEmpty)
			let turn = try #require(
				try await coach.send(draft("How was my week?"), to: .main).acceptedTurn)
			#expect(try #require(await coach.currentSnapshot(.main)).turns.map(\.id) == [turn])
		}

		@Test func blankTextIsIgnoredAndLanguageSlashRoutesWithoutARecord() async throws {
			let recording = BatchRecordingLog(inner: InMemoryRecordLog())
			let coach = makeCoach(transport: transport, store: recording, clock: clock)
			#expect(try await coach.send(draft("  \n"), to: .main) == .ignoredBlank)
			#expect(try await coach.send(draft("/language"), to: .main) == .showLanguagePicker)
			#expect(recording.batches.isEmpty)
			#expect(transport.requests.isEmpty)
		}

		@Test func acceptThenTerminateBeforeGenerationReopensOneRecoverableTurn() async throws {
			let store = InMemoryRecordLog()
			let recording = BatchRecordingLog(inner: store)
			let sent = draft("Is Thursday still on?")
			let before = makeCoach(
				transport: transport, store: recording, clock: clock,
				coalescing: CoalescingPolicy(window: .seconds(60)))
			let turn = try #require(try await before.send(sent, to: .main).acceptedTurn)
			#expect(recording.batches == [["userMessage"]])
			#expect(transport.requests.isEmpty)

			let reopened = makeCoach(transport: transport, store: recording, clock: clock)
			let snapshot = try #require(await reopened.currentSnapshot(.main))
			#expect(snapshot.turns.map(\.id) == [turn])
			#expect(snapshot.turns.first?.state == .accepted(.awaitingRestart))
			#expect(snapshot.turns.first?.state.retryable == true)
			#expect(snapshot.activity == .idle)
			#expect(transport.requests.isEmpty)
			#expect(try await reopened.send(sent, to: .main) == .accepted(turn))
			#expect(recording.batches == [["userMessage"]])
			#expect(try #require(await reopened.currentSnapshot(.main)).turns.count == 1)
		}

		@Test func acceptCommitOnDiskStaysUnderOneHundredMilliseconds() async throws {
			let store = try makeSwiftDataLog(deviceId: DeviceID(rawValue: "phone-a"))
			let coach = makeCoach(
				transport: transport, store: store, clock: clock,
				coalescing: CoalescingPolicy(window: .seconds(60)))
			_ = try await coach.send(draft("warm up"), to: .main)
			var samples: [Duration] = []
			for index in 0..<3 {
				let started = ContinuousClock.now
				_ = try await coach.send(draft("message \(index)"), to: .main)
				samples.append(ContinuousClock.now - started)
			}
			let median = try #require(samples.sorted().dropFirst().first)
			Attachment.record(
				samples.map { String(format: "%.2f", $0 / .milliseconds(1)) }.joined(
					separator: " "),
				named: "accept-commit-ms.txt")
			#expect(median < .milliseconds(100), "accept commit samples \(samples)")
		}
	}
}
