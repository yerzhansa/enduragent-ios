import EnduragentCoachFixtures
import Foundation
import Testing

@testable import EnduragentCoach

extension MemoryToolsTests {
	@Test func memoryQueryIncludesOnlyMatchingMixedRecordsAtBothEndpoints() async throws {
		let transport = FakeModelTransport()
		let coach = try await seedMixedHistory(transport: transport, store: InMemoryRecordLog())
		let results = try await queryHistory(
			[("1998-06-13", "1998-06-14", "tempo")], coach: coach, transport: transport)
		let result = try #require(results.first)
		let lines = result.split(separator: "\n").map(String.init)
		#expect(lines.filter { $0.hasPrefix("## ") } == ["## 1998-06-14", "## 1998-06-13"])
		#expect(lines.count == 9)
		#expect(lines.contains("First TeMpO note."))
		#expect(lines.contains("Last TeMpO note."))
		let events = try lines.filter { $0.hasPrefix("event: ") }.map {
			try JSONValue.parse(String($0.dropFirst("event: ".count)))
		}
		#expect(
			events.map { $0.objectFields["date"]?.stringValue } == ["1998-06-14", "1998-06-13"])
		#expect(events.map { $0.objectFields["kind"]?.stringValue } == ["decision", "decision"])
		#expect(
			events.map { $0.objectFields["text"]?.stringValue }
				== ["Last TeMpO decision.", "First TeMpO decision."])
		#expect(
			lines.filter { $0.hasPrefix("history: ") } == [
				"history: schedule \u{2014} was: _updated: 1998-06-13 - First TeMpO fact."
					+ " / now: _updated: 1998-06-14 - Last TeMpO fact.",
				"history: schedule \u{2014} was:  / now: _updated: 1998-06-13 - First TeMpO fact.",
			])
		#expect(!result.contains("Before"))
		#expect(!result.contains("After"))
		#expect(!result.contains("recovery"))
	}

	@Test func memoryQueryMatchesEveryRecordKindWithoutChangingCase() async throws {
		let store = InMemoryRecordLog()
		let transport = FakeModelTransport()
		let coach = try await seedMixedHistory(transport: transport, store: store)
		let storedQuery = RecordQuery(
			scope: .synced([.dailyNote, .ledgerEvent, .journal, .memorySection]))
		let before = try await store.fetch(storedQuery).records.sorted { $0.hlc < $1.hlc }
		#expect(
			before.contains {
				$0.body
					== .synced(
						.dailyNote(DailyNoteBody(note: "First TeMpO note.\nFirst recovery only.")))
			})
		#expect(
			before.contains {
				$0.body
					== .synced(
						.ledgerEvent(
							LedgerEventBody(
								date: "1998-06-13", kind: .decision, text: "First TeMpO decision.",
								source: .chat)))
			})
		#expect(
			before.contains {
				$0.body
					== .synced(
						.memorySection(
							MemorySectionBody(
								name: .schedule,
								content: "_updated: 1998-06-13\n- First TeMpO fact.")))
			})
		let terms = ["tempo", "TEMPO", "TeMpO"]
		let results = try await queryHistory(
			terms.map { ("1998-06-13", "1998-06-14", $0) }, coach: coach, transport: transport)
		let bodies = results.map {
			$0.components(separatedBy: "\n").dropFirst().joined(separator: "\n")
		}
		let body = try #require(bodies.first)
		#expect(bodies.allSatisfy { $0 == body })
		for (term, result) in zip(terms, results) {
			#expect(
				result.hasPrefix("Memory query 1998-06-13..1998-06-14 matching \"\(term)\"\n\n"))
			for endpoint in ["First", "Last"] {
				#expect(result.contains("\(endpoint) TeMpO note."))
				#expect(result.contains("\"text\":\"\(endpoint) TeMpO decision.\""))
				#expect(result.contains("- \(endpoint) TeMpO fact."))
			}
			#expect(!result.contains("recovery"))
		}
		let after = try await store.fetch(storedQuery).records.sorted { $0.hlc < $1.hlc }
		#expect(after == before)
	}

	@Test func memoryQueryBoundsAndEmptyResultsReachTheModel() async throws {
		let rangeClock = FixedClock(now: "1998-01-01T12:00:00+01:00", timeZone: "Europe/Amsterdam")
		let transport = FakeModelTransport()
		let coach = await makeCoach(
			transport: transport, store: InMemoryRecordLog(), clock: rangeClock)
		_ = try await runMemoryTools(
			[
				.toolCall(
					name: "memory_write", arguments: #"{"type":"daily","content":"First day."}"#)
			],
			coach: coach, transport: transport)
		rangeClock.advance(by: 365 * 24 * 60 * 60)
		_ = try await runMemoryTools(
			[
				.toolCall(
					name: "memory_write", arguments: #"{"type":"daily","content":"Last day."}"#)
			],
			coach: coach, transport: transport)
		let results = try await queryHistory(
			[
				("1998-01-01", "1999-01-01", nil),
				("1998-01-01", "1999-01-02", nil),
				("1999-01-01", "1998-01-01", nil),
				("1998-02-30", "1998-03-01", nil),
				("1998-02-01", "1998-02-30", nil),
				("2024/01/01", "2024/01/02", nil),
				("1999-02-01", "1999-02-03", nil),
				("1998-01-01", "1999-01-01", "absent"),
			], coach: coach, transport: transport)
		#expect(
			results == [
				"Memory query 1998-01-01..1999-01-01\n\n## 1999-01-01\nLast day.\n\n## 1998-01-01\nFirst day.",
				"Error: range is 367 days; the maximum is 366. Query a narrower range.",
				"Error: 'from' (1999-01-01) is after 'to' (1998-01-01). Swap the bounds.",
				"Error: 1998-02-30..1998-03-01 contains an invalid calendar date. Use real YYYY-MM-DD dates.",
				"Error: 1998-02-01..1998-02-30 contains an invalid calendar date. Use real YYYY-MM-DD dates.",
				"Error: 2024/01/01..2024/01/02 contains an invalid calendar date. Use real YYYY-MM-DD dates.",
				"Memory query 1999-02-01..1999-02-03: no daily notes, events, or history found.",
				"Memory query 1998-01-01..1999-01-01 matching \"absent\": no daily notes, events, or history found.",
			])
	}

	@Test func memoryQueryOversizedResultsStayBoundedAndExplicitlyTruncated() async throws {
		let transport = FakeModelTransport()
		let coach = await makeCoach(transport: transport, store: InMemoryRecordLog(), clock: clock)
		let note = "TeMpO " + String(repeating: "🚴", count: 10_050) + "\nFinal marker."
		_ = try await runMemoryTools(
			[
				.toolCall(
					name: "memory_write",
					arguments: JSONValue.object([
						"type": .string("daily"), "content": .string(note),
					])
					.canonicalDigestInput())
			], coach: coach, transport: transport)
		let results = try await queryHistory(
			[("1998-06-13", "1998-06-13", nil), ("1998-06-13", "1998-06-13", "Final marker")],
			coach: coach, transport: transport)
		let result = try #require(results.first)
		let notice = "[truncated \u{2014} narrow the date range or add a query term]"
		let parts = result.components(separatedBy: "\n" + notice)
		try #require(parts.count == 2)
		let content = parts[0]
		let complete = "Memory query 1998-06-13..1998-06-13\n\n## 1998-06-13\n" + note
		#expect((19_999...20_000).contains(content.utf16.count))
		#expect(complete.hasPrefix(content))
		#expect(content.contains("TeMpO 🚴"))
		#expect(!content.contains("\u{FFFD}"))
		#expect(!result.contains("Final marker."))
		#expect(parts[1].isEmpty)
		#expect(result.hasSuffix("\n" + notice))
		#expect(result.utf16.count <= 20_000 + 1 + notice.utf16.count)
		#expect(
			results.last
				== "Memory query 1998-06-13..1998-06-13 matching \"Final marker\"\n\n## 1998-06-13\nFinal marker."
		)
	}

	private func seedMixedHistory(transport: FakeModelTransport, store: InMemoryRecordLog)
		async throws -> Coach
	{
		let historyClock = FixedClock(
			now: "1998-06-12T12:00:00+02:00", timeZone: "Europe/Amsterdam")
		let coach = await makeCoach(transport: transport, store: store, clock: historyClock)
		let rows: [(String, String, SectionName)] = [
			("1998-06-12", "Before", .person), ("1998-06-13", "First", .schedule),
			("1998-06-14", "Last", .schedule), ("1998-06-15", "After", .cyclingEquipment),
		]
		for (date, label, section) in rows {
			let arguments: [(String, JSONValue)] = [
				(
					"memory_write",
					.object([
						"type": .string("daily"),
						"content": .string("\(label) TeMpO note.\n\(label) recovery only."),
					])
				),
				(
					"ledger_append",
					.object([
						"date": .string(date), "kind": .string("decision"),
						"text": .string("\(label) TeMpO decision."),
					])
				),
				(
					"memory_write",
					.object([
						"type": .string("memory"), "section": .string(section.rawValue),
						"content": .string("- \(label) TeMpO fact."),
					])
				),
				(
					"ledger_append",
					.object([
						"date": .string(date), "kind": .string("decision"),
						"text": .string("\(label) recovery decision."),
					])
				),
				(
					"memory_write",
					.object([
						"type": .string("memory"), "section": .string("notes"),
						"content": .string("- \(label) recovery fact."),
					])
				),
			]
			let results = try await runMemoryTools(
				arguments.map { .toolCall(name: $0.0, arguments: $0.1.canonicalDigestInput()) },
				coach: coach, transport: transport)
			for (call, result) in zip(arguments, results) {
				let success = call.0 == "ledger_append" ? "recorded" : "saved"
				#expect(result.objectFields[success]?.boolValue == true)
			}
			historyClock.advance(by: 24 * 60 * 60)
		}
		return coach
	}

	private func queryHistory(
		_ ranges: [(String, String, String?)], coach: Coach, transport: FakeModelTransport
	) async throws -> [String] {
		let calls = ranges.map { from, to, query in
			var fields: [String: JSONValue] = ["from": .string(from), "to": .string(to)]
			if let query { fields["query"] = .string(query) }
			return ScriptedEvent.toolCall(
				name: "memory_query", arguments: JSONValue.object(fields).canonicalDigestInput())
		}
		return try await runMemoryTools(calls, coach: coach, transport: transport).map {
			try #require($0.stringValue)
		}
	}

	private func runMemoryTools(
		_ calls: [ScriptedEvent], coach: Coach, transport: FakeModelTransport
	) async throws -> [JSONValue] {
		transport.respond = ScriptedReply.sequence(
			calls + [
				.finish(reason: .toolCalls), .text("Checked memory."), .finish(reason: .stop),
			],
			otherwise: { _ in ScriptedReply([.finish(reason: .stop)]) })
		#expect(
			replyText(try await coach.sendAndSettle("Check my training memory."))
				== "Checked memory.")
		let request = try #require(sent(.chatAttempt, by: transport).last)
		let messages = request.messages.filter { $0.role == .tool }
		try #require(messages.count == calls.count)
		return try messages.map { message in
			let payload = try JSONValue.parse(message.content)
			#expect(payload.objectFields["untrusted_data"]?.stringValue == UntrustedEnvelope.banner)
			return try #require(payload.objectFields["data"])
		}
	}
}
