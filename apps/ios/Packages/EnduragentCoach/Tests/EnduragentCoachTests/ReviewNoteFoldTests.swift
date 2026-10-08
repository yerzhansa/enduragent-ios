import Foundation
import Testing

@testable import EnduragentCoach

@Suite struct ReviewNoteFoldTests {
	let device = DeviceID(rawValue: "phone-a")

	@Test func resetPartitionsReviewNotesLikeARelaunch() {
		let notes = [note(1), note(4)]
		let before = ConversationFold.fold(chat: .main, synced: notes, device: device)
		var applied = before
		applied.apply([boundary], device: device)
		let relaunched = ConversationFold.fold(
			chat: .main, synced: notes + [boundary], device: device)
		#expect(applied.segments.map(\.notes) == relaunched.segments.map(\.notes))
	}

	@Test func lateReviewNoteStaysInItsArchivedConversation() {
		let before = ConversationFold.fold(chat: .main, synced: [boundary], device: device)
		var applied = before
		applied.apply([note(1)], device: device)
		#expect(applied.current.notes.isEmpty)
		#expect(applied.segments.first?.notes.map(\.ulid) == [fixedUlid(1)])
	}

	@Test func refreshedReviewNotesKeepTheirOrderAndAreNotDuplicated() {
		let before = ConversationFold.fold(chat: .main, synced: [note(4)], device: device)
		var applied = before
		applied.apply([note(4), note(1)], device: device)
		#expect(applied.current.notes.map(\.ulid) == [fixedUlid(1), fixedUlid(4)])
	}

	@Test func cancellationAnchorsToItsOriginalTurnAcrossResetAndRepeatedImports() throws {
		let turn = TurnID(ulid: fixedUlid(1))
		let cause = RecordCause.operation(.turn(turn), AttemptID(ulid: fixedUlid(2)))
		let user = storedRecord(
			device: device, wall: 1, ulid: turn.ulid,
			body: .synced(sampleUser(chatId: .main, text: "Workout", turn: turn)))
		let write = storedRecord(
			device: device, wall: 2, ulid: fixedUlid(2), cause: cause,
			body: .synced(
				.reviewWrite(
					ReviewWriteBody(
						chatId: .main, review: ChangeSetID(ulid: fixedUlid(1)), writeID: nil,
						target: nil, evidence: .unknown(.dispatched)))))
		let body = try ReviewCancelledUnknownBody.cancelling(
			CalendarWriteIntent(record: write, body: try #require(writeBody(write)), proposal: nil),
			on: device)
		let marker = storedRecord(
			device: device, wall: 6, ulid: fixedUlid(6), cause: cause,
			body: .synced(.reviewCancelledUnknown(body)))
		var conversation = ConversationFold.fold(
			chat: .main, synced: [user, write], device: device)
		conversation.apply([boundary, marker], device: device)
		conversation.apply([marker], device: device)
		let reopened = ConversationFold.fold(
			chat: .main, synced: [marker, boundary, write, user], device: device)
		#expect(conversation.segments.map(\.notes) == reopened.segments.map(\.notes))
		#expect(conversation.current.notes.isEmpty)
		#expect(conversation.segments.first?.notes.count == 1)
		#expect(conversation.segments.first?.notes.first?.after == turn)
	}

	@Test func aCancellationWithoutItsOwnerWrittenUnknownIntentIsIgnored() throws {
		let decoded = try RecordCodec.decode(
			kind: "reviewCancelledUnknown", version: 2,
			data: Data(try fixture("review-cancelled-unknown", ext: "json").utf8),
			civilDate: "1998-06-14", ulid: fixedUlid(2).rawValue
		).get()
		let marker = storedRecord(
			device: device, wall: 3, ulid: fixedUlid(3),
			cause: .operation(.turn(TurnID(ulid: fixedUlid(1))), AttemptID(ulid: fixedUlid(2))),
			body: decoded)
		#expect(
			ConversationFold.fold(chat: .main, synced: [marker], device: device).current.notes
				.isEmpty)
	}

	private func writeBody(_ record: AthleteRecord) -> ReviewWriteBody? {
		if case .synced(.reviewWrite(let body)) = record.body { return body }
		return nil
	}

	private var boundary: AthleteRecord {
		storedRecord(
			device: device, wall: 5, ulid: fixedUlid(5),
			body: .synced(
				.windowStart(
					WindowStartBody(
						chatId: .main, firstIncludedUlid: fixedUlid(3),
						reason: .reset(ResetID(ulid: fixedUlid(3)))))))
	}

	private func note(_ index: Int) -> AthleteRecord {
		storedRecord(
			device: device, wall: Int64(index), ulid: fixedUlid(index),
			body: .synced(
				.reviewApplied(
					ReviewAppliedBody(chatId: .main, summary: .deleteWorkout))))
	}
}
