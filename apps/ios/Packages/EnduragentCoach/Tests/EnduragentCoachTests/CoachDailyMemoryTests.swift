import EnduragentCoachFixtures
import Foundation
import Testing

@testable import EnduragentCoach

extension SwiftDataSuites {
	@Suite struct CoachDailyMemoryTests {
		let phone = DeviceID(rawValue: "daily-memory-phone")

		@Test func duplicateFatigueNoteSurvivesRelaunchWithoutChangingCurrentFacts() async throws {
			let clock = FixedClock(now: "1998-06-13T12:00:00+02:00", timeZone: "Europe/Amsterdam")
			let directory = try TestTemporaryFolders.make()
			let store = try makeSwiftDataLog(deviceId: phone, directory: directory)
			let transport = FakeModelTransport()
			let before = await makeCoach(transport: transport, store: store, clock: clock)
			let profile = "- FTP: 215 watts; resting heart rate: 52 bpm."
			let schedule = "- Available training days: Tuesday and Saturday."
			try await write(
				[
					.object([
						"type": .string("memory"), "section": .string("cycling-profile"),
						"content": .string(profile),
					]),
					.object([
						"type": .string("memory"), "section": .string("schedule"),
						"content": .string(schedule),
					]),
				], using: before, transport: transport)
			let factsQuery = RecordQuery(scope: .synced([.memorySection, .journal, .provenance]))
			let savedFacts = try await store.fetch(factsQuery).records.sorted { $0.hlc < $1.hlc }
			#expect(
				savedFacts.filter { $0.body.kind == SyncedKind.memorySection.rawValue }.count == 2)
			let fatigue = "Fatigue: legs felt heavy after the morning ride."
			for _ in 0..<2 {
				try await write(
					[.object(["type": .string("daily"), "content": .string(fatigue)])],
					using: before, transport: transport)
			}
			await before.lifecycle(.willTerminate)

			let reopened = try makeSwiftDataLog(deviceId: phone, directory: directory)
			let relaunchedTransport = FakeModelTransport()
			let after = await makeCoach(
				transport: relaunchedTransport, store: reopened, clock: clock)
			let notes = try await reopened.fetch(RecordQuery(scope: .synced([.dailyNote]))).records
			try #require(notes.count == 1)
			#expect(notes[0].civilDate.rawValue == "1998-06-13")
			#expect(notes[0].timeZone.identifier == "Europe/Amsterdam")
			#expect(notes[0].body == .synced(.dailyNote(DailyNoteBody(note: fatigue))))
			let currentFacts = try await reopened.fetch(factsQuery).records.sorted {
				$0.hlc < $1.hlc
			}
			#expect(currentFacts == savedFacts)

			let request = try await query(
				[("1998-06-13", "1998-06-13")], containing: "Fatigue",
				using: after, transport: relaunchedTransport)
			let context = try #require(request.messages.first { $0.role == .system }).content
			#expect(context.contains("## cycling-profile\n_updated: 1998-06-13\n" + profile))
			#expect(context.contains("## schedule\n_updated: 1998-06-13\n" + schedule))
			#expect(context.contains("## Today's Notes\n" + fatigue))
			#expect(context.components(separatedBy: fatigue).count == 2)
			let results = try request.messages.filter { $0.role == .tool }.map(toolText)
			#expect(
				results == [
					"Memory query 1998-06-13..1998-06-13 matching \"Fatigue\"\n\n## 1998-06-13\n"
						+ fatigue
				])
		}

		@Test func notesAcrossLocalMidnightKeepTheirDaysAfterRelaunch() async throws {
			let clock = FixedClock(now: "1998-06-13T23:59:30+02:00", timeZone: "Europe/Amsterdam")
			let directory = try TestTemporaryFolders.make()
			let transport = FakeModelTransport()
			let before = await makeCoach(
				transport: transport,
				store: try makeSwiftDataLog(deviceId: phone, directory: directory), clock: clock)
			let evening = "Fatigue: tired legs before local midnight."
			let morning = "Recovery: legs felt better after local midnight."
			try await write(
				[.object(["type": .string("daily"), "content": .string(evening)])],
				using: before, transport: transport)
			clock.advance(by: 60)
			try await write(
				[.object(["type": .string("daily"), "content": .string(morning)])],
				using: before, transport: transport)
			await before.lifecycle(.willTerminate)

			let reopened = try makeSwiftDataLog(deviceId: phone, directory: directory)
			let relaunchedTransport = FakeModelTransport()
			let after = await makeCoach(
				transport: relaunchedTransport, store: reopened, clock: clock)
			let notes = try await reopened.fetch(RecordQuery(scope: .synced([.dailyNote]))).records
				.sorted { $0.hlc < $1.hlc }
			#expect(notes.map(\.civilDate.rawValue) == ["1998-06-13", "1998-06-14"])
			#expect(notes.map(\.timeZone.identifier) == ["Europe/Amsterdam", "Europe/Amsterdam"])
			#expect(
				notes.map(\.body) == [
					.synced(.dailyNote(DailyNoteBody(note: evening))),
					.synced(.dailyNote(DailyNoteBody(note: morning))),
				])
			let request = try await query(
				[
					("1998-06-13", "1998-06-13"), ("1998-06-14", "1998-06-14"),
					("1998-06-13", "1998-06-14"),
				], using: after, transport: relaunchedTransport)
			let results = try request.messages.filter { $0.role == .tool }.map(toolText)
			#expect(
				results == [
					"Memory query 1998-06-13..1998-06-13\n\n## 1998-06-13\n" + evening,
					"Memory query 1998-06-14..1998-06-14\n\n## 1998-06-14\n" + morning,
					"Memory query 1998-06-13..1998-06-14\n\n## 1998-06-14\n" + morning
						+ "\n\n## 1998-06-13\n" + evening,
				])
			let context = try #require(request.messages.first { $0.role == .system }).content
			#expect(context.contains("## Today's Notes\n" + morning))
			#expect(!context.contains(evening))
		}

		private func write(
			_ arguments: [JSONValue], using coach: Coach, transport: FakeModelTransport
		) async throws {
			let calls = arguments.map {
				ScriptedEvent.toolCall(name: "memory_write", arguments: $0.canonicalDigestInput())
			}
			transport.respond = ScriptedReply.sequence(
				calls + [.finish(reason: .toolCalls), .text("Saved."), .finish(reason: .stop)],
				otherwise: { _ in ScriptedReply([.finish(reason: .stop)]) })
			#expect(
				replyText(try await coach.sendAndSettle("Remember this training update."))
					== "Saved.")
			let request = try #require(sent(.chatAttempt, by: transport).last)
			let results = request.messages.filter { $0.role == .tool }
			#expect(results.count == arguments.count)
			for result in results {
				let payload = try JSONValue.parse(result.content)
				#expect(payload.objectFields["data"]?.objectFields["saved"]?.boolValue == true)
			}
		}

		private func query(
			_ ranges: [(String, String)], containing text: String? = nil,
			using coach: Coach, transport: FakeModelTransport
		) async throws -> CompletionRequest {
			let calls = ranges.map { from, to in
				var fields: [String: JSONValue] = ["from": .string(from), "to": .string(to)]
				if let text { fields["query"] = .string(text) }
				return ScriptedEvent.toolCall(
					name: "memory_query", arguments: JSONValue.object(fields).canonicalDigestInput()
				)
			}
			transport.respond = ScriptedReply.sequence(
				calls + [
					.finish(reason: .toolCalls), .text("Notes recovered."), .finish(reason: .stop),
				],
				otherwise: { _ in ScriptedReply([.finish(reason: .stop)]) })
			#expect(
				replyText(try await coach.sendAndSettle("What do my dated training notes say?"))
					== "Notes recovered.")
			return try #require(sent(.chatAttempt, by: transport).last)
		}

		private func toolText(_ message: WireMessage) throws -> String {
			let payload = try JSONValue.parse(message.content)
			#expect(payload.objectFields["untrusted_data"]?.stringValue == UntrustedEnvelope.banner)
			return try #require(payload.objectFields["data"]?.stringValue)
		}
	}
}
