import EnduragentCoach
import EnduragentCoachFixtures
import Foundation
import Testing

@Suite struct Build2bbe2eeStoreSeed {
	@Test func generate() async throws {
		let destination = try #require(
			ProcessInfo.processInfo.environment["UPGRADE_STORE_DESTINATION"])
		let root = URL(filePath: destination, directoryHint: .isDirectory)
		let log = SwiftDataRecordLog(
			deviceId: DeviceID(rawValue: "build-2bbe2ee"),
			synced: try ModelContainerHandle.withoutCloudKit(
				storeURL: root.appending(path: ModelContainerHandle.syncedStoreFileName)),
			local: try ModelContainerHandle.withoutCloudKit(
				storeURL: root.appending(path: ModelContainerHandle.localStoreFileName)))
		let clock = FixedClock(now: "1998-06-15T08:00:00Z", timeZone: "Europe/Ljubljana")
		let intervals = FakeIntervalsClient(athleteName: FirstWeekFixture.athleteName, ftp: 250)
		FirstWeekFixture.install(on: intervals)
		let transport = FakeModelTransport(
			respond: ScriptedReply.sequence([
				.toolCall(
					name: ToolName.memoryWrite.rawValue,
					arguments:
						#"{"type":"memory","section":"schedule","content":"Rides with a group on Saturdays."}"#
				),
				.finish(reason: .toolCalls), .text(FirstWeekFixture.rememberReply),
				.finish(reason: .stop),
			]))
		let coach = await makeCoach(
			transport: transport, intervals: intervals, store: log, clock: clock)
		let state = try await coach.sendAndSettle("Remember that I ride with a group on Saturdays")
		#expect(replyText(state) == FirstWeekFixture.rememberReply)
		transport.respond = ScriptedReply.sequence([.finish(reason: .stop)])
		#expect(await coach.startNewConversation(in: .main) == .started(memory: .saved))
		let question =
			"Give me a 60 minute endurance ride for tomorrow with two 10 minute tempo blocks"
		transport.respond = ScriptedReply.sequence(FirstWeekFixture.script(for: question))
		_ = try await coach.sendAndSettle(question)
		#expect(try await coach.history().count == 1)
		#expect(await coach.currentSnapshot(.main)?.review?.cards.count == 1)
		let consent = try await log.fetch(RecordQuery(scope: .deviceLocal([.providerConsent])))
		#expect(consent.skipped.isEmpty)
		#expect(consent.records.count == 1)
		let memory = try await log.fetch(RecordQuery(scope: .synced([.memorySection])))
		#expect(memory.skipped.isEmpty)
		#expect(memory.records.count == 1)
	}
}
