import EnduragentCoach
import Foundation
import Testing

@testable import Enduragent

extension FixtureLaunchTests {
	@Test func teachSavesTheScheduleThenReplies() async throws {
		let services = try services()
		let records = services.coach.recordSyncProbe()
		let model = model(services)
		model.startChatting()
		model.draft.text = "fixture:teach"
		await model.send()
		let settled = try await settledTurn(model)
		#expect(replyText(settled.state) == FirstWeekFixture.rememberReply)
		#expect(try await count("memorySection", in: records) == 1)
	}

	@Test func flushPartialLeavesTheJobPendingUntilTheNextLaunchDrainsIt() async throws {
		let services = try services()
		let records = services.coach.recordSyncProbe()
		let transport = try #require(services.fixtureTransport)
		let model = model(services)
		model.startChatting()
		try await exchange(model, ["fixture:flush-partial"] + longs(5) + ["How was my week?"])
		try await waitUntil { transport.requestCount == 7 + 4 }
		try await waitUntil { await services.leases().last?.ending != nil }
		#expect(try await count("flushPending", in: records) == 1)
		#expect(try await count("flushSettled", in: records) == 0)
		#expect(try await count("memorySection", in: records) == 1)
		#expect(try await count("ledgerEvent", in: records) == 1)

		let relaunched = self.model(try relaunch(.keep).0)
		let drained = relaunched.services.coach.recordSyncProbe()
		await relaunched.lifecycle.forward(.becameActive)
		try await waitUntil { try await count("flushSettled", in: drained) == 1 }
		#expect(try await count("flushPending", in: drained) == 1)
		#expect(try await count("ledgerEvent", in: drained) == 1)
	}

	@Test func longRepliesTrimIntoTheFixtureSummary() async throws {
		let services = try services()
		let records = services.coach.recordSyncProbe()
		let transport = try #require(services.fixtureTransport)
		let model = model(services)
		model.startChatting()
		try await exchange(model, longs(6) + ["How was my week?", "And Saturday?"])
		#expect(try await count("compactionSummary", in: records) == 1)
		#expect(try await count("windowStart", in: records) == 1)
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

	private func count(_ kind: String, in records: RecordSyncProbe)
		async throws -> Int
	{
		try await records.snapshot().counts.first { $0.kind == kind }?.count ?? 0
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
