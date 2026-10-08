import EnduragentCoachFixtures
import Foundation
import Testing

@testable import EnduragentCoach

extension SwiftDataSuites {
	@Suite struct PartialFlushFixtureTests {
		let device = DeviceID(rawValue: "partial-flush-phone")
		let directory: URL

		init() throws {
			directory = try TestTemporaryFolders.make()
		}
		let clock = FixedClock(now: "1998-06-15T08:00:00+02:00", timeZone: "Europe/Amsterdam")

		@Test(
			arguments: [
				ScriptedFailure.connection(.notConnectedToInternet), .connection(.timedOut),
				.http(status: 429), .http(status: 500), .http(status: 402),
			], [false, true])
		func overflowAndPostTurnDrainKeepPartialWritesPendingUntilRelaunch(
			failure: ScriptedFailure, interrupted: Bool
		) async throws {
			let fixture = try FixtureRecordStore(directory: directory, deviceId: device)
			let store = fixture.faults.log
			let host = ImmediateExecutionHost()
			let transport = FakeModelTransport(
				respond: PartialFlushFixture.responses(failingWith: failure))
			transport.respond = ScriptedReply.sequence(
				[.text("Earlier conversation."), .finish(reason: .stop)], for: .summary,
				otherwise: transport.respond)
			transport.respond = ScriptedReply.sequence(
				[
					.text("Noted."), .finish(reason: .stop),
					.fail(.http(status: 400, body: "maximum context length is 131072 tokens")),
					.text("After rescue."), .finish(reason: .stop),
					.text("Unfinished reply."), .hang,
				], otherwise: transport.respond)
			let before = await makeCoach(
				transport: transport, store: store, clock: clock, host: host)
			#expect(replyText(try await before.sendAndSettle("fixture:flush-partial")) == "Noted.")
			_ = try #require(await host.ended(0))
			_ = try await before.sendAndSettle("fixture:fail overflow")
			_ = try #require(await host.ended(1))
			let ledger = Ledger(log: store, clock: clock, diagnostics: DiagnosticsLog(clock: clock))
			let jobs = try await ledger.flushJobs(in: try await ledger.conversation(.main))
			#expect(jobs.count == 1)
			try #require(jobs.map(\.phase) == [.pending])
			#expect(try await rows(.deviceLocal([.flushSettled]), in: store).isEmpty)
			let sections = try await rows(.synced([.memorySection]), in: store)
			let events = try await rows(.synced([.ledgerEvent]), in: store)
			#expect(sections.count == 1)
			#expect(events.count == 1)
			let flushes = sent(.memoryFlush, by: transport)
			#expect(Set(flushes.map(\.attempt)).count == 2)
			let original = Array(try #require(flushes.first).messages.dropFirst().prefix(2))
			#expect(original.map(\.unstampedContent) == ["fixture:flush-partial", "Noted."])
			let turn: TurnID?
			if interrupted {
				turn = try #require(
					try await before.send(draft("fixture:hang"), to: .main).acceptedTurn)
				await before.waitForLiveText(try #require(turn))
				try await before.dieWithoutWriting(to: store)
				#expect(try await settlements(of: try #require(turn), in: store).isEmpty)
			} else {
				turn = nil
				await before.lifecycle(.willTerminate)
			}
			#expect(try await rows(.deviceLocal([.flushSettled]), in: store).isEmpty)
			try await recover(
				jobs: jobs, sections: sections, events: events, original: original, turn: turn)
		}

		private func recover(
			jobs: [FlushJob], sections: [AthleteRecord], events: [AthleteRecord],
			original: [WireMessage], turn: TurnID?
		) async throws {
			let reopened = try FixtureRecordStore(directory: directory, deviceId: device)
			let store = reopened.faults.log
			let host = ImmediateExecutionHost()
			let transport = FakeModelTransport(
				respond: ScriptedReply.sequence(
					PartialFlushFixture.writes + [.finish(reason: .stop)], for: .flush))
			let after = await makeCoach(
				transport: transport, store: store, clock: clock, host: host)
			await after.lifecycle(.becameActive)
			_ = try #require(await host.ended(0))
			let flushes = sent(.memoryFlush, by: transport)
			#expect(flushes.count == 2)
			for request in flushes {
				#expect(Array(request.messages.dropFirst().prefix(2)) == original)
			}
			let ledger = Ledger(log: store, clock: clock, diagnostics: DiagnosticsLog(clock: clock))
			let recovered = try await ledger.flushJobs(in: try await ledger.conversation(.main))
			#expect(recovered.map(\.id) == jobs.map(\.id))
			#expect(recovered.map(\.phase) == [.settled(.recorded(.saved(sections: 1, events: 0)))])
			#expect(try await rows(.deviceLocal([.flushSettled]), in: store).count == 1)
			#expect(try await rows(.synced([.ledgerEvent]), in: store) == events)
			let restoredSections = try await rows(.synced([.memorySection]), in: store)
			#expect(Set(restoredSections.map(\.ulid)).isSuperset(of: Set(sections.map(\.ulid))))
			if let turn {
				#expect(await after.interruption(of: turn) == .processEnded)
				#expect(try await settlements(of: turn, in: store).count == 1)
			}
			await after.lifecycle(.becameActive)
			transport.respond = ScriptedReply.sequence(
				[.text("Still noted."), .finish(reason: .stop)], otherwise: transport.respond)
			#expect(replyText(try await after.sendAndSettle("Anything else?")) == "Still noted.")
			_ = try #require(await host.ended(1))
			#expect(sent(.memoryFlush, by: transport).count == flushes.count)
			#expect(try await rows(.deviceLocal([.flushPending]), in: store).count == 1)
			#expect(try await rows(.deviceLocal([.flushSettled]), in: store).count == 1)
			#expect(try await rows(.synced([.ledgerEvent]), in: store) == events)
		}

		private func rows(_ scope: RecordQuery.Scope, in store: any RecordLog)
			async throws -> [AthleteRecord]
		{
			try await store.fetch(RecordQuery(scope: scope)).records
		}
	}
}
