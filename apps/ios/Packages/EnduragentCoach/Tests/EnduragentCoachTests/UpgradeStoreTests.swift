import Foundation
import Testing

@testable import EnduragentCoach

extension SwiftDataSuites {
	@Suite struct UpgradeStoreTests {
		@Test func committedV1HistoryOpensTwoReadableArchives() async throws {
			let root = try copyStore("history")
			defer {
				do { try FileManager.default.removeItem(at: root) } catch { Issue.record(error) }
			}
			let coach = try await coach(root)
			#expect(await coach.currentSnapshot(.main)?.turns.isEmpty == true)
			let history = try await coach.history()
			#expect(history.count == 2)
			#expect(history.allSatisfy { $0.reason == .earlierChat })
			#expect(
				history.map(\.firstQuestion) == [
					"Remember that I ride with a group on Saturdays",
					"What did my training look like this week?",
				])
			for summary in history {
				let archive = try #require(try await coach.archivedConversation(summary.id))
				#expect(archive.turns.count == 1)
				#expect(archive.turns.first?.athleteText == summary.firstQuestion)
				#expect(archive.turns.allSatisfy { $0.state.isSettled })
				let question = try #require(summary.firstQuestion)
				let reply = try #require(archive.turns.first.flatMap { replyText($0.state) })
				#expect(
					reply.contains(
						question.hasPrefix("What")
							? "Tuesday sweet spot" : "Noted."))
			}
		}

		@Test func committedV1ReviewIsReadOnly() async throws {
			let root = try copyStore("review")
			defer {
				do { try FileManager.default.removeItem(at: root) } catch { Issue.record(error) }
			}
			let coach = try await coach(root)
			let review = try #require(await coach.currentSnapshot(.main)?.review)
			_ = await coach.decide(.presented(review.ref), in: .main)
			let presented = try #require(await coach.currentSnapshot(.main)?.review)
			#expect(presented.authority == .readOnly)
			#expect(presented.controls == .none)
			#expect(presented.notice?.key.rawValue == "review.earlierVersion")
		}

		private func copyStore(_ scenario: String) throws -> URL {
			let source = try #require(
				Bundle.module.url(
					forResource: scenario, withExtension: nil, subdirectory: "Fixtures/v1-upgrade"))
			let root = FileManager.default.temporaryDirectory.appending(path: UUID().uuidString)
			try FileManager.default.copyItem(at: source, to: root)
			return root
		}

		private func coach(_ root: URL) async throws -> Coach {
			let store = SwiftDataRecordLog(
				deviceId: DeviceID(rawValue: "v1-upgrade-proof"),
				synced: try .withoutCloudKit(
					storeURL: root.appending(path: "synced-records.store")),
				local: try .withoutCloudKit(storeURL: root.appending(path: "local-records.store")))
			return await makeCoach(
				transport: FakeModelTransport(), store: store,
				clock: FixedClock(now: "1998-06-15T08:00:00Z", timeZone: "Europe/Ljubljana"))
		}
	}
}
