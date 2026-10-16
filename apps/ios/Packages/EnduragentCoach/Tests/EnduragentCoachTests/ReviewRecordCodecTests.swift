import EnduragentCoachFixtures
import Foundation
import SwiftData
import Testing

@testable import EnduragentCoach

extension SwiftDataSuites {
	@Suite struct ReviewRecordCodecTests {
		let phone = DeviceID(rawValue: "codec-phone")
		static let milestone3BodyVersion = 5

		func reviewBodies() throws -> [RecordBody] {
			try reviewRecordSamples([.completed, .canceled, .closedAtUpgrade])
		}

		@Test func eachReviewRecordRoundTripsThroughTheStore() async throws {
			let log = try makeSwiftDataLog(deviceId: phone)
			let bodies = try reviewBodies()
			for (index, body) in bodies.enumerated() {
				try await log.append(
					[storedRecord(device: phone, wall: Int64(index + 1), body: body)],
					locality: body.locality)
			}

			let synced = try await log.fetch(RecordQuery(scope: .synced([.reviewOutcome])))
			let local = try await log.fetch(
				RecordQuery(scope: .deviceLocal([.workoutReview, .reviewPreparing])))

			#expect((synced.records + local.records).map(\.body) == bodies)
			#expect(synced.skipped.isEmpty && local.skipped.isEmpty)
		}

		@Test func aMilestone3BuildSkipsOnlyTheReviewRecordsAsNewerVersions() async throws {
			let directory = try TestTemporaryFolders.make()
			let log = try makeSwiftDataLog(deviceId: phone, directory: directory)
			let earlier: [RecordBody] = [
				.synced(sampleUser(chatId: .main, text: "hi")),
				.synced(
					sampleReply(chatId: .main, turn: TurnID(ulid: fixedUlid(3)), text: "hello")),
				.deviceLocal(
					.replyObserved(
						ReplyObservedBody(
							chatId: .main, turn: TurnID(ulid: fixedUlid(3)),
							attempt: AttemptID(ulid: fixedUlid(4))))),
				.deviceLocal(
					.flushPending(
						FlushPendingBody(
							chatId: .main, messageUlids: [fixedUlid(5)],
							process: ProcessID(ulid: fixedUlid(6))))),
			]
			let bodies = try reviewBodies() + earlier
			for (index, body) in bodies.enumerated() {
				try await log.append(
					[storedRecord(device: phone, wall: Int64(index + 1), body: body)],
					locality: body.locality)
			}

			let rows = try ["synced.store", "local.store"].flatMap { file in
				try ModelContext(
					try ModelContainerHandle.withoutCloudKit(
						storeURL: directory.appending(path: file)
					)
					.container
				).fetch(FetchDescriptor<StoredAthleteRecord>())
			}.sorted { $0.hlcWallMs < $1.hlcWallMs }
			let skipped = rows.filter { $0.bodyVersion > Self.milestone3BodyVersion }

			#expect(rows.count == bodies.count)
			#expect(
				Set(skipped.map(\.kind)) == ["reviewOutcome", "workoutReview", "reviewPreparing"])
			#expect(skipped.count == bodies.count - earlier.count)
			#expect(
				RecordCodec.decode(
					kind: "aKindFromALaterBuild", version: RecordCodec.currentBodyVersion + 1,
					data: Data("{}".utf8), civilDate: "1998-06-13", ulid: "row"
				).failure
					== .newerVersion(
						kind: "aKindFromALaterBuild", version: RecordCodec.currentBodyVersion + 1,
						ulid: "row"))
			let read = rows.filter { $0.bodyVersion <= Self.milestone3BodyVersion }
				.map { $0.decode() }
			#expect(read.compactMap(\.success).map(\.body) == earlier)
		}
	}
}

func reviewRecordSamples(_ endings: [ReviewOutcomeBody.Ending]) throws -> [RecordBody] {
	let review = try reviewFixture("workout-review-unconfirmed")
	let actions: [ReviewCard.Action] = [
		.add, .edit(previousName: "Endurance"), .edit(previousName: nil), .delete, .add,
	]
	let results: [OutcomeLine.Result] = [
		.saved, .seenOnCalendar, .noLongerOnCalendar, .givenUp, .mayHaveBeenSaved,
	]
	let dates: [CivilDate] = ["1998-06-14", "1998-06-15", "1998-06-16", "1998-06-17", "1998-06-18"]
	let lines = zip(actions, zip(results, dates)).enumerated().map { position, line in
		OutcomeLine(
			position: position, action: line.0, name: "Workout \(position)", date: line.1.1,
			result: line.1.0)
	}
	let outcomes = endings.map { ending in
		RecordBody.synced(
			.reviewOutcome(
				ReviewOutcomeBody(
					chatId: .main, review: review.id, revision: review.revision,
					after: ending == .closedAtUpgrade ? nil : review.origin.turn, ending: ending,
					lines: ending == .canceled ? [] : lines)))
	}
	return outcomes + [
		.deviceLocal(.workoutReview(WorkoutReviewBody(review: review))),
		.deviceLocal(
			.reviewPreparing(
				ReviewPreparingBody(
					chatId: .main, turn: review.origin.turn, attempt: review.origin.attempt))),
	]
}
