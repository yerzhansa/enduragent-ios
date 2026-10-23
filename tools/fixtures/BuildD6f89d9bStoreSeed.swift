import EnduragentCoach
import EnduragentCoachFixtures
import Foundation
import Testing

@Suite struct BuildD6f89d9bStoreSeed {
	static let remember = "Remember that I ride with a group on Saturdays"
	static let rename = "Rename Wednesday's tempo ride to Tempo 2x8"
	static let document =
		#"{"steps":[{"warmup":true,"duration":600,"power":{"units":"%ftp","start":50,"end":65},"_power":{"start":125,"end":162.5},"cadence":{"units":"rpm","value":90}},{"reps":2,"steps":[{"duration":480,"power":{"units":"%ftp","value":87.5},"_power":{"value":218.75},"hr":{"units":"%lthr","value":88.3}},{"duration":240,"power":{"units":"%ftp","value":55},"_power":{"value":137.5}}]},{"cooldown":true,"duration":600,"power":{"units":"%ftp","value":50},"_power":{"value":168.33333333333334},"text":"Easy spin"}],"duration":3360,"ftp":250}"#
	static let preparation =
		#"{"preparation":{"kind":"complete","changes":[{"kind":"edit","eventId":4101,"patch":{"name":"Tempo 2x8"}}]}}"#

	@Test func generate() async throws {
		let destination = try #require(
			ProcessInfo.processInfo.environment["UPGRADE_STORE_DESTINATION"])
		let root = URL(filePath: destination, directoryHint: .isDirectory)
			.appending(path: "waiting-review")
		let log = SwiftDataRecordLog(
			deviceId: DeviceID(rawValue: "build-d6f89d9b"),
			synced: try ModelContainerHandle.withoutCloudKit(
				storeURL: root.appending(path: ModelContainerHandle.syncedStoreFileName)),
			local: try ModelContainerHandle.withoutCloudKit(
				storeURL: root.appending(path: ModelContainerHandle.localStoreFileName)))
		let intervals = FakeIntervalsClient(athleteName: "Ada", ftp: 250)
		intervals.events = [
			CalendarEvent(
				description: "Two tempo blocks", type: "Ride", id: EventID(rawValue: 4101),
				startDateLocal: "1998-06-17T00:00:00", name: "Tempo ride", category: "WORKOUT",
				externalId: nil, uid: nil, tags: [IntervalsPolicy.coachTag], coachCreated: true,
				movingTime: 3360, trainingLoad: 58,
				workoutDocument: try JSONValue.parse(Self.document))
		]
		let transport = FakeModelTransport(
			respond: ScriptedReply.sequence([
				.toolCall(
					name: ToolName.memoryWrite.rawValue,
					arguments:
						#"{"type":"memory","section":"schedule","content":"Rides with a group on Saturdays."}"#
				),
				.finish(reason: .toolCalls), .text("Noted. Saturdays are group rides."),
				.finish(reason: .stop),
			]))
		let coach = await makeCoach(
			transport: transport, intervals: intervals, store: log,
			clock: FixedClock(now: "1998-06-15T08:00:00Z", timeZone: "Europe/Ljubljana"))
		_ = try await coach.sendAndSettle(Self.remember)
		transport.respond = ScriptedReply.sequence([
			.toolCall(name: "prepare_workout_changes", arguments: Self.preparation),
			.finish(reason: .toolCalls), .text("I've prepared the rename. Approve it to save."),
			.finish(reason: .stop),
		])
		_ = try await coach.sendAndSettle(Self.rename)

		let review = try #require(await coach.currentSnapshot(.main)?.review)
		#expect(review.cards.count == 1)
		#expect(try await count(.synced([.memorySection]), in: log) == 1)
		#expect(try await count(.synced([.journal]), in: log) == 1)
		#expect(try await count(.synced([.turnSettled]), in: log) == 2)
		#expect(try await count(.deviceLocal([.workoutReview]), in: log) == 1)
		let writes = intervals.calls.filter { call in
			switch call {
			case .createEvent, .updateEvent, .deleteEvent: true
			default: false
			}
		}
		#expect(writes.isEmpty)
	}

	private func count(_ scope: RecordQuery.Scope, in log: SwiftDataRecordLog) async throws -> Int {
		let page = try await log.fetch(RecordQuery(scope: scope))
		#expect(page.skipped.isEmpty)
		return page.records.count
	}
}
