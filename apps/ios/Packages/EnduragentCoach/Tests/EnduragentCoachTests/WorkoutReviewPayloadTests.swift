import Foundation
import Testing

@testable import EnduragentCoach

struct WorkoutReviewPayloadTests {
	@Test(arguments: ReviewStage.allCases)
	func everyStageRoundTripsThroughTheStoredValue(_ stage: ReviewStage) throws {
		let review = try ReviewStages()[stage]
		let stored = try WorkoutReviewPayload.encode(review)
		#expect(try WorkoutReviewPayload.decode(stored) == review)
		#expect(try WorkoutReviewPayload.encode(try WorkoutReviewPayload.decode(stored)) == stored)
	}

	@Test func theFixturesDecodeToTheValuesTheyDescribe() throws {
		let review = try reviewFixture("workout-review-unconfirmed")
		#expect(review.revision == ReviewRevision(rawValue: 2))
		#expect(review.chat == .main)
		#expect(review.work.finished.map(\.change.position) == [0, 1, 2])
		#expect(
			review.work.finished.dropFirst().map(\.result) == [
				.seenOnCalendar(EventID(rawValue: 101)), .noLongerOnCalendar,
			])
		guard case .saved(let receipt) = try #require(review.work.finished.first).result else {
			throw UnexpectedReview(detail: "the first finished change has no Receipt")
		}
		#expect(receipt.event == EventID(rawValue: 201))
		#expect(receipt.answeredAt == Date(timeIntervalSince1970: 897_984_030))
		#expect(review.work.remaining.map(\.position) == [4])
		#expect(review.stage.changes.map(\.id) == [reviewChange(404)])
	}

	@Test func anAddWithNoDurationRoundTripsWithoutOne() throws {
		let fixture = try fixtureText("workout-review-approval")
		let withoutDuration = fixture.replacingOccurrences(of: "\"movingTime\": 3000,\n", with: "")
		#expect(withoutDuration != fixture)
		let review = try WorkoutReviewPayload.decode(Data(withoutDuration.utf8))
		guard case .add(let added) = try #require(review.work.remaining.first).action else {
			throw UnexpectedReview(detail: "the first remaining change is not an add")
		}
		#expect(added.payload.movingTime == nil)
		#expect(added.payload.trainingLoad == 55)
		let stored = try WorkoutReviewPayload.encode(review)
		#expect(try WorkoutReviewPayload.decode(stored) == review)
	}

	@Test func aChangeInTwoPlacesFailsToDecode() throws {
		let fixture = try fixtureText("workout-review-unconfirmed")
		let inFinishedAndRemaining = fixture.replacingOccurrences(
			of: "00T47DW5000000000000000405", with: "00T47DW5000000000000000401")
		let inFlightAndRemaining = fixture.replacingOccurrences(
			of: "00T47DW5000000000000000405", with: "00T47DW5000000000000000404")
		for broken in [inFinishedAndRemaining, inFlightAndRemaining] {
			#expect(broken != fixture)
			#expect(throws: RecordDecodeFailure(reason: "workoutReview")) {
				try WorkoutReviewPayload.decode(Data(broken.utf8))
			}
		}
	}

	@Test func twoChangesAtOnePositionFailToDecode() throws {
		let fixture = try fixtureText("workout-review-unconfirmed")
		let broken = fixture.replacingOccurrences(of: #""position": 4"#, with: #""position": 0"#)
		#expect(broken != fixture)
		#expect(throws: RecordDecodeFailure(reason: "workoutReview")) {
			try WorkoutReviewPayload.decode(Data(broken.utf8))
		}
	}

	@Test func aWorkoutReviewCauseKeepsTheChangeSetString() throws {
		let review = WorkoutReviewID(ulid: reviewULID(100))
		let operation = OperationID.workoutReview(review, ReviewRevision(rawValue: 3))
		let row = try StoredAthleteRecord(
			record: storedRecord(
				device: DeviceID(rawValue: "phone-a"), wall: 897_984_000,
				cause: .operation(operation, AttemptID(ulid: reviewULID(300))),
				body: .synced(.dailyNote(DailyNoteBody(note: "stamped")))))
		#expect(row.operation == "workoutChangeSet:00T47DW5000000000000000100:3")
		row.operation = "workoutChangeSet:00T47DW5000000000000000101:2"
		let decoded = try row.decode().get()
		#expect(
			decoded.cause
				== .operation(
					.workoutReview(
						WorkoutReviewID(ulid: reviewULID(101)), ReviewRevision(rawValue: 2)),
					AttemptID(ulid: reviewULID(300))))
	}

	private func fixtureText(_ name: String) throws -> String {
		String(decoding: try fixtureData(name), as: UTF8.self)
	}
}
