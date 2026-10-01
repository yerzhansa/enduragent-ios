import EnduragentCoachFixtures
import Foundation
import Testing

@testable import EnduragentCoach

extension SwiftDataSuites {
	@Suite struct UpgradeStoreTests {
		@Test func testUpgradeHistory() async throws {
			let log = try open("history")
			let coach = await makeCoach(transport: FakeModelTransport(), store: log)
			let snapshot = try #require(await coach.currentSnapshot(.main))
			#expect(snapshot.opening == .welcome)
			#expect(snapshot.turns.isEmpty)
			let history = try await coach.history()
			#expect(history.count == 2)
			#expect(history.map(\.reason) == [.earlierChat, .earlierChat])
			#expect(
				history.map(\.firstQuestion) == [
					"Remember that I ride with a group on Saturdays",
					"What did my training look like this week?",
				])
			for summary in history {
				let archive = try #require(try await coach.archivedConversation(summary.id))
				#expect(archive.turns.count == 1)
				#expect(archive.turns.compactMap { replyText($0.state) }.count == 1)
			}
		}

		@Test func pendingV1ReviewIsReadOnly() async throws {
			let log = try open("review")
			let transport = FakeModelTransport()
			let coach = await makeCoach(transport: transport, store: log)
			let review = try #require(await coach.currentSnapshot(.main)?.review)
			#expect(review.authority == .readOnly)
			#expect(review.controls == .none)
			#expect(review.notice?.key == Catalog.reviewEarlierVersion)
			#expect(transport.requests.isEmpty)
			let page = try await log.fetch(
				RecordQuery(
					scope: .deviceLocal([.pendingProposal, .proposalCleared])))
			#expect(page.skipped.isEmpty)
			#expect(kinds(page.records) == ["pendingProposal"])
		}

		private func open(_ scenario: String) throws -> SwiftDataRecordLog {
			let source = try #require(
				Bundle.module.url(
					forResource: scenario, withExtension: nil, subdirectory: "Fixtures/v1-upgrade"))
			let root = FileManager.default.temporaryDirectory.appending(
				path: "enduragent-upgrade-\(UUID().uuidString)", directoryHint: .isDirectory)
			try FileManager.default.copyItem(at: source, to: root)
			return SwiftDataRecordLog(
				deviceId: DeviceID(rawValue: "v1-upgrade-fixture"),
				synced: try ModelContainerHandle.withoutCloudKit(
					storeURL: root.appending(path: "synced-records.store")),
				local: try ModelContainerHandle.withoutCloudKit(
					storeURL: root.appending(path: "local-records.store")))
		}
	}
}
