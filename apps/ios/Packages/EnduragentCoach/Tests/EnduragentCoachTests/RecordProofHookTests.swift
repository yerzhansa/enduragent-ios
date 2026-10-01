import EnduragentCoachFixtures
import Foundation
import Testing

@testable import EnduragentCoach

@Suite(.timeLimit(.minutes(1))) struct RecordProofHookTests {
	@Test func nextReviewRecordReadFailsOnceAfterPresentation() async throws {
		let directory = FileManager.default.temporaryDirectory.appending(
			path: "enduragent-record-hook-\(UUID().uuidString)", directoryHint: .isDirectory)
		try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
		defer {
			do { try FileManager.default.removeItem(at: directory) } catch {
				Issue.record(error, "record hook fixture cleanup")
			}
		}
		try await checkRecordHook(directory: directory)
	}

	private func checkRecordHook(directory: URL) async throws {
		let fixture = try FixtureRecordStore(
			directory: directory, deviceId: DeviceID(rawValue: "phone"))
		let model = FakeModelTransport()
		let coach = await makeCoach(transport: model, store: fixture.faults.log)
		let (_, token) = try await DurableCalendarWriteTests().proposal(on: coach, model: model)
		await coach.stop(.main)
		let ready = try #require(await coach.currentSnapshot(.main)?.review)
		#expect(ready.token != nil)
		fixture.faults.failNextReviewRead()
		let unrelated = try await fixture.faults.log.fetch(
			RecordQuery(scope: .synced([.userMessage]), chatId: .main))
		#expect(unrelated.records.count == 1)
		_ = await coach.decide(.presented(token.ref), in: .main)
		let failed = try #require(await coach.currentSnapshot(.main)?.review)
		#expect(failed.cards == ready.cards)
		#expect(failed.notice?.key == Catalog.reviewStorageUnavailable)
		#expect(failed.controls == .none)
		#expect(await coach.decide(.checkAgain(token.ref), in: .main) == .presentationRecorded)
		#expect(await coach.currentSnapshot(.main)?.review == ready)
	}
}
