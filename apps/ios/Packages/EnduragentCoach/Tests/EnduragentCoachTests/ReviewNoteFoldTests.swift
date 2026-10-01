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
