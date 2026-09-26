import EnduragentCoach
import Foundation
import Testing

@testable import Enduragent

extension FixtureLaunchTests {
	@Test func teachSavesTheScheduleThenReplies() async throws {
		let services = try services()
		let records = try #require(services.fixtureRecordLog)
		let model = model(services)
		model.startChatting()
		model.draft.text = "fixture:teach"
		await model.send()
		let settled = try await settledTurn(model)
		#expect(replyText(settled.state) == FirstWeekFixture.rememberReply)
		#expect(try await count(.synced([.memorySection]), in: records) == 1)
	}

	@Test func flushPartialLeavesTheJobPendingUntilTheNextLaunchDrainsIt() async throws {
		let services = try services(store: .keep)
		let records = try #require(services.fixtureRecordLog)
		let transport = try #require(services.fixtureTransport)
		let model = model(services)
		model.startChatting()
		try await exchange(model, ["fixture:flush-partial"] + longs(5) + ["How was my week?"])
		try await waitUntil { transport.requestCount == 7 + 3 }
		#expect(try await count(.deviceLocal([.flushPending]), in: records) == 1)
		#expect(try await count(.deviceLocal([.flushSettled]), in: records) == 0)
		#expect(try await count(.synced([.memorySection]), in: records) == 1)
		#expect(try await count(.synced([.ledgerEvent]), in: records) == 1)

		let relaunched = self.model(try self.services(store: .keep))
		let drained = try #require(relaunched.services?.fixtureRecordLog)
		await relaunched.lifecycle.forward(.becameActive)
		try await waitUntil { try await count(.deviceLocal([.flushSettled]), in: drained) == 1 }
		#expect(try await count(.deviceLocal([.flushPending]), in: drained) == 1)
		#expect(try await count(.synced([.ledgerEvent]), in: drained) == 1)
	}

	@Test func longRepliesTrimIntoTheFixtureSummary() async throws {
		let services = try services()
		let records = try #require(services.fixtureRecordLog)
		let transport = try #require(services.fixtureTransport)
		let model = model(services)
		model.startChatting()
		try await exchange(model, longs(6) + ["How was my week?", "And Saturday?"])
		let summaries = try await records.fetch(RecordQuery(scope: .synced([.compactionSummary])))
			.records.compactMap { record -> String? in
				guard case .synced(.compactionSummary(let body)) = record.body else { return nil }
				return body.markdown
			}
		#expect(summaries == [FirstWeekFixture.earlierSummary])
		#expect(try await count(.synced([.windowStart]), in: records) == 1)
		#expect(transport.lastChatHistoryHead == "[Previous conversation summary]")
		#expect(model.chat?.turns.count == 8)
	}

	private func longs(_ count: Int) -> [String] {
		Array(repeating: "fixture:long", count: count)
	}

	private func exchange(_ model: ShellModel, _ messages: [String]) async throws {
		for message in messages {
			let before = model.chat?.turns.count ?? 0
			model.draft.text = message
			await model.send()
			try await waitUntil(within: .seconds(30)) {
				guard let turns = model.chat?.turns, turns.count == before + 1,
					let last = turns.last
				else {
					return false
				}
				return replyText(last.state) != nil
			}
		}
	}

	private func count(_ scope: RecordQuery.Scope, in records: FaultInjectingRecordLog)
		async throws -> Int
	{
		try await records.fetch(RecordQuery(scope: scope)).records.count
	}

	private func waitUntil(
		within limit: Duration = .seconds(10), _ condition: () async throws -> Bool
	) async throws {
		let deadline = ContinuousClock.now + limit
		while try await !condition() {
			guard ContinuousClock.now < deadline else {
				Issue.record("condition never held in \(limit)")
				return
			}
			try await Task.sleep(for: .milliseconds(20))
		}
	}
}
