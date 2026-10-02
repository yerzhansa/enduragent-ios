import EnduragentCoachFixtures
import Foundation
import Testing

@testable import EnduragentCoach

extension SwiftDataSuites {
	@Suite(.timeLimit(.minutes(1))) struct CoachLedgerHistoryTests {
		let clock = FixedClock(now: "1998-06-13T12:00:00+02:00", timeZone: "Europe/Amsterdam")
		let phone = DeviceID(rawValue: "ledger-history-phone")

		@Test(arguments: [LedgerSource.chat, .flush])
		func allEventKindsSurviveRelaunchWithTheirDatesWordingAndSources(source: LedgerSource)
			async throws
		{
			let directory = try TestTemporaryFolders.make()
			let store = try makeSwiftDataLog(deviceId: phone, directory: directory)
			let transport = FakeModelTransport()
			let before = await makeCoach(transport: transport, store: store, clock: clock)
			let events = [
				event("decision", on: "1998-06-01", text: "Keep Saturday free for the group ride."),
				event(
					"override", on: "1998-06-02",
					text: "Replace Tuesday intervals with an easy ride."),
				event("illness", on: "1998-06-03", text: "Sore throat; skipped the morning ride."),
				event(
					"experiment", on: "1998-06-04", text: "Try 60 grams of carbohydrate per hour."),
				event("outcome", on: "1998-06-05", text: "The fueling trial felt comfortable."),
			]
			let results: [JSONValue]
			if source == .chat {
				results = try await append(events, using: before, transport: transport)
			} else {
				transport.respond = ScriptedReply.sequence(
					[.text("Noted."), .finish(reason: .stop)],
					otherwise: { _ in ScriptedReply([.finish(reason: .stop)]) })
				#expect(
					replyText(try await before.sendAndSettle("Remember my dated training events."))
						== "Noted.")
				transport.respond = ScriptedReply.sequence(
					events.map {
						.toolCall(name: "ledger_append", arguments: $0.canonicalDigestInput())
					} + [.finish(reason: .toolCalls), .finish(reason: .stop)],
					for: .flush, otherwise: transport.respond)
				let reset = try await beforeDeadline(within: .hangGuard) {
					await before.startNewConversation(in: .main)
				}
				#expect(try #require(reset) == .started(memory: .saved))
				let request = try #require(sent(.memoryFlush, by: transport).last)
				results = try request.messages.filter { $0.role == .tool }.map {
					try JSONValue.parse($0.content)
				}
			}
			#expect(results == Array(repeating: .object(["recorded": .bool(true)]), count: 5))
			await before.lifecycle(.willTerminate)

			let reopened = try makeSwiftDataLog(deviceId: phone, directory: directory)
			let relaunchedTransport = FakeModelTransport()
			let after = await makeCoach(
				transport: relaunchedTransport, store: reopened, clock: clock)
			let history = try await query(
				from: "1998-06-01", to: "1998-06-05", using: after, transport: relaunchedTransport)
			for arguments in events {
				let date = try #require(arguments.objectFields["date"]?.stringValue)
				#expect(history.contains("## \(date)\n"))
			}
			#expect(
				try historyEvents(history)
					== events.reversed().map { recorded($0, source: source) })
			let records = try await reopened.fetch(RecordQuery(scope: .synced([.ledgerEvent])))
				.records
			#expect(records.count == 5)
		}

		@Test func duplicateAndInvalidInputsLeaveOnlyTheOriginalEventAfterRelaunch() async throws {
			let directory = try TestTemporaryFolders.make()
			let store = try makeSwiftDataLog(deviceId: phone, directory: directory)
			let transport = FakeModelTransport()
			let before = await makeCoach(transport: transport, store: store, clock: clock)
			let original = event("decision", on: "1998-06-01", text: "Keep Saturday free.")
			#expect(
				try await append([original], using: before, transport: transport)
					== [.object(["recorded": .bool(true)])])
			let recordQuery = RecordQuery(scope: .synced([.ledgerEvent, .provenance]))
			let saved = try await store.fetch(recordQuery).records
			#expect(saved.filter { $0.body.kind == SyncedKind.ledgerEvent.rawValue }.count == 1)
			#expect(saved.filter { $0.body.kind == SyncedKind.provenance.rawValue }.count == 1)
			#expect(
				try await append([original], using: before, transport: transport)
					== [.object(["duplicate": .bool(true), "recorded": .bool(false)])])
			#expect(try await store.fetch(recordQuery).records == saved)
			let invalid = [
				event("decision", on: "next Tuesday", text: "This date must be refused."),
				event("workout", on: "1998-06-02", text: "This kind must be refused."),
				event("decision", on: "1998-06-03", text: ""),
			]
			for arguments in invalid {
				let results = try await append([arguments], using: before, transport: transport)
				let error = try #require(results.first?.stringValue)
				#expect(error.hasPrefix("Error:"))
				#expect(error.contains("Use YYYY-MM-DD."))
				#expect(try await store.fetch(recordQuery).records == saved)
			}
			await before.lifecycle(.willTerminate)

			let reopened = try makeSwiftDataLog(deviceId: phone, directory: directory)
			let relaunchedTransport = FakeModelTransport()
			let after = await makeCoach(
				transport: relaunchedTransport, store: reopened, clock: clock)
			#expect(try await reopened.fetch(recordQuery).records == saved)
			let history = try await query(
				from: "1998-06-01", to: "1998-06-13", using: after, transport: relaunchedTransport)
			#expect(try historyEvents(history) == [recorded(original, source: .chat)])
		}

		@Test func impossibleCalendarDateReturnsErrorAndLeavesHistoryUnchangedAfterRelaunch()
			async throws
		{
			let directory = try TestTemporaryFolders.make()
			let store = try makeSwiftDataLog(deviceId: phone, directory: directory)
			let transport = FakeModelTransport()
			let before = await makeCoach(transport: transport, store: store, clock: clock)
			let original = event("decision", on: "2026-02-28", text: "Keep Saturday free.")
			#expect(
				try await append([original], using: before, transport: transport)
					== [.object(["recorded": .bool(true)])])
			let recordQuery = RecordQuery(scope: .synced([.ledgerEvent, .provenance]))
			let saved = try await store.fetch(recordQuery).records
			#expect(saved.filter { $0.body.kind == SyncedKind.ledgerEvent.rawValue }.count == 1)
			#expect(saved.filter { $0.body.kind == SyncedKind.provenance.rawValue }.count == 1)
			let impossible = event(
				"decision", on: "2026-02-30", text: "This impossible date must be refused.")
			#expect(
				try await append([impossible], using: before, transport: transport)
					== [
						.string(
							"Error: 2026-02-30 is not a real calendar date. Use YYYY-MM-DD.")
					])
			#expect(try await store.fetch(recordQuery).records == saved)
			await before.lifecycle(.willTerminate)

			let reopened = try makeSwiftDataLog(deviceId: phone, directory: directory)
			let relaunchedTransport = FakeModelTransport()
			let after = await makeCoach(
				transport: relaunchedTransport, store: reopened, clock: clock)
			#expect(try await reopened.fetch(recordQuery).records == saved)
			let history = try await query(
				from: "2026-02-01", to: "2026-03-31", using: after, transport: relaunchedTransport)
			#expect(history.contains("## 2026-02-28\n"))
			#expect(try historyEvents(history) == [recorded(original, source: .chat)])
		}

		@Test func laterDifferentDecisionKeepsBothDatedEventsAfterRelaunch() async throws {
			let directory = try TestTemporaryFolders.make()
			let transport = FakeModelTransport()
			let before = await makeCoach(
				transport: transport,
				store: try makeSwiftDataLog(deviceId: phone, directory: directory), clock: clock)
			let earlier = event("decision", on: "1998-06-01", text: "Keep Saturday free.")
			let later = event("decision", on: "1998-06-08", text: "Move the group ride to Sunday.")
			for arguments in [earlier, later] {
				#expect(
					try await append([arguments], using: before, transport: transport)
						== [.object(["recorded": .bool(true)])])
			}
			await before.lifecycle(.willTerminate)

			let reopened = try makeSwiftDataLog(deviceId: phone, directory: directory)
			let relaunchedTransport = FakeModelTransport()
			let after = await makeCoach(
				transport: relaunchedTransport, store: reopened, clock: clock)
			let history = try await query(
				from: "1998-06-01", to: "1998-06-08", using: after, transport: relaunchedTransport)
			#expect(history.contains("## 1998-06-01\n"))
			#expect(history.contains("## 1998-06-08\n"))
			#expect(
				try historyEvents(history)
					== [recorded(later, source: .chat), recorded(earlier, source: .chat)])
			let records = try await reopened.fetch(RecordQuery(scope: .synced([.ledgerEvent])))
				.records
			#expect(records.count == 2)
		}

		@Test func whitespaceOnlyTextIsAcceptedAndPreservedAfterRelaunch() async throws {
			let directory = try TestTemporaryFolders.make()
			let transport = FakeModelTransport()
			let before = await makeCoach(
				transport: transport,
				store: try makeSwiftDataLog(deviceId: phone, directory: directory), clock: clock)
			let whitespace = event("outcome", on: "1998-06-01", text: " \t\n ")
			#expect(
				try await append([whitespace], using: before, transport: transport)
					== [.object(["recorded": .bool(true)])])
			await before.lifecycle(.willTerminate)

			let reopened = try makeSwiftDataLog(deviceId: phone, directory: directory)
			let relaunchedTransport = FakeModelTransport()
			let after = await makeCoach(
				transport: relaunchedTransport, store: reopened, clock: clock)
			let history = try await query(
				from: "1998-06-01", to: "1998-06-01", using: after, transport: relaunchedTransport)
			#expect(try historyEvents(history) == [recorded(whitespace, source: .chat)])
			let records = try await reopened.fetch(RecordQuery(scope: .synced([.ledgerEvent])))
				.records
			#expect(records.count == 1)
		}

		private func event(_ kind: String, on date: String, text: String) -> JSONValue {
			.object(["kind": .string(kind), "date": .string(date), "text": .string(text)])
		}

		private func recorded(_ arguments: JSONValue, source: LedgerSource) -> JSONValue {
			var fields = arguments.objectFields
			fields["source"] = .string(source.rawValue)
			fields["ts"] = .string("1998-06-13T10:00:00.000Z")
			return .object(fields)
		}

		private func append(
			_ arguments: [JSONValue], using coach: Coach, transport: FakeModelTransport
		) async throws -> [JSONValue] {
			let calls = arguments.map {
				ScriptedEvent.toolCall(name: "ledger_append", arguments: $0.canonicalDigestInput())
			}
			transport.respond = ScriptedReply.sequence(
				calls + [.finish(reason: .toolCalls), .text("Checked."), .finish(reason: .stop)],
				otherwise: { _ in ScriptedReply([.finish(reason: .stop)]) })
			#expect(
				replyText(try await coach.sendAndSettle("Remember this dated training event."))
					== "Checked.")
			let request = try #require(sent(.chatAttempt, by: transport).last)
			let results = try request.messages.filter { $0.role == .tool }.map(toolData)
			#expect(results.count == arguments.count)
			return results
		}

		private func query(
			from: String, to: String, using coach: Coach, transport: FakeModelTransport
		) async throws -> String {
			transport.respond = ScriptedReply.sequence(
				[
					.toolCall(
						name: "memory_query",
						arguments: JSONValue.object(["from": .string(from), "to": .string(to)])
							.canonicalDigestInput()),
					.finish(reason: .toolCalls), .text("History recovered."),
					.finish(reason: .stop),
				], otherwise: { _ in ScriptedReply([.finish(reason: .stop)]) })
			#expect(
				replyText(try await coach.sendAndSettle("What happened over those dates?"))
					== "History recovered.")
			let request = try #require(sent(.chatAttempt, by: transport).last)
			let results = request.messages.filter { $0.role == .tool }
			try #require(results.count == 1)
			return try #require(toolData(results[0]).stringValue)
		}

		private func toolData(_ message: WireMessage) throws -> JSONValue {
			let payload = try JSONValue.parse(message.content)
			#expect(payload.objectFields["untrusted_data"]?.stringValue == UntrustedEnvelope.banner)
			return try #require(payload.objectFields["data"])
		}

		private func historyEvents(_ text: String) throws -> [JSONValue] {
			try text.split(separator: "\n").filter { $0.hasPrefix("event: ") }.map {
				try JSONValue.parse(String($0.dropFirst("event: ".count)))
			}
		}
	}
}
