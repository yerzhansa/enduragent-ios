import EnduragentCoachFixtures
import Foundation
import Testing

@testable import EnduragentCoach

@Suite struct ReviewOutcomeNotesTests {
	enum GoneDelete: String, CaseIterable, CustomTestStringConvertible {
		case answered404, settledAfterLostAnswer

		var testDescription: String { rawValue }
	}

	static let english = displayLocale()
	static let editOnly =
		#"{"kind":"complete","changes":[{"kind":"edit","eventId":201,"patch":{"structure":\#(ReviewTurns.authoredSteps)}}]}"#

	let turns = ReviewTurns()
	let calendar: ScriptedCalendar

	init() {
		calendar = ScriptedCalendar(turns.intervals)
	}

	@Test func aCompletedReviewsNoteShowsEveryChangeAfterRefreshReopenNewConversationAndRelaunch()
		async throws
	{
		let coach = await coach()
		let review = try await turns.committed(ReviewTurns.fourChanges, on: coach)
		let turn = review.origin.turn
		let token = try await token(on: coach.desk)
		turns.script([.text("Thursday stays easy."), .finish(reason: .stop)])
		let later = try #require(
			try await coach.send(draft("Is Thursday still easy?"), to: .main).acceptedTurn)
		_ = try #require(await coach.settledState(of: later, in: .main))
		guard case .completed = await coach.desk.decide(.approve(token)) else {
			Issue.record("the review did not complete")
			return
		}
		let note = Self.note([
			(.saved, "Threshold 2x2", "1998-09-09"), (.saved, "Core", "1998-09-10"),
			(.saved, "Endurance", "1998-09-10"), (.saved, "Endurance", "1998-09-11"),
		])

		try await coach.mailbox(for: .main).refreshImports()
		let refreshed = try #require(await coach.currentSnapshot(.main))
		#expect(Self.sentences(refreshed.notes[turn]) == [note])
		#expect(refreshed.notes[later] == nil)
		#expect(refreshed.review == nil)
		#expect(try await coach.desk.snapshot(chat: .main) == nil)
		try await coach.mailbox(for: .main).refreshImports()
		#expect(Self.sentences(await coach.currentSnapshot(.main)?.notes[turn]) == [note])
		#expect(Self.sentences(try await coach.ledger.conversation(.main).current.notes) == [note])

		guard case .started = await coach.resetAndSettle(in: .main) else {
			Issue.record("New conversation did not start")
			return
		}
		#expect(await coach.currentSnapshot(.main)?.notes.isEmpty == true)
		let archived = try await coach.newestArchive()
		#expect(archived.notes.map { $0.sentence(in: Self.english) } == [note])
		#expect(archived.notes.first?.after == turn)

		let relaunched = await self.coach()
		await relaunched.lifecycle(.becameActive)
		let reopened = try await relaunched.newestArchive()
		#expect(reopened.notes.map { $0.sentence(in: Self.english) } == [note])
		#expect(try await relaunched.desk.snapshot(chat: .main) == nil)
		#expect(calendar.writes.count == 4)
	}

	@Test func aCancelAfterPartialWorkKeepsTheSavedAndMayHaveBeenSavedLinesAndNeverReadsAgain()
		async throws
	{
		let rig = DeskRig()
		try await rig.save(try rig.mixed())
		rig.calendar.answer { [rig] index, _ in
			guard index == 1 else { return nil }
			rig.calendar.failReads()
			return .lost(.transport)
		}
		let desk = try rig.desk()
		guard case .unconfirmed = await desk.decide(.approve(try await rig.token(on: desk))) else {
			Issue.record("the lost answer did not leave an unconfirmed change")
			return
		}
		rig.calendar.restoreReads()

		guard case .canceled = await desk.decide(.cancel(try await rig.token(on: desk))) else {
			Issue.record("the unconfirmed review was not canceled")
			return
		}
		let calls = rig.calendar.calls
		await desk.recover()
		await (try rig.desk()).recover()

		#expect(rig.calendar.calls == calls)
		let conversation = try await rig.ledger().conversation(.main)
		#expect(
			Self.sentences(conversation.current.notes) == [
				Self.note([
					(.saved, "Tempo ride", "1998-09-09"),
					(.mayHaveBeenSaved, "Strength", "1998-09-10"),
					(.givenUp, "Endurance", "1998-09-10"), (.givenUp, "Recovery", "1998-09-11"),
				])
			])
		#expect(try await rig.desk().snapshot(chat: .main) == nil)
	}

	@Test func aSecondDeviceShowsTheNoteWithNoControlAndNoCard() async throws {
		let coach = await coach()
		let review = try await turns.committed(ReviewTurns.oneRide, on: coach)
		let token = try await token(on: coach.desk)
		guard case .completed = await coach.desk.decide(.approve(token)) else {
			Issue.record("the review did not complete")
			return
		}
		let other = InMemoryRecordLog(deviceId: DeviceID(rawValue: "phone-b"))
		try await other.append(
			try await turns.store.fetch(RecordQuery(scope: .everySynced)).records, locality: .synced
		)
		let otherCalendar = ScriptedCalendar(turns.intervals)
		let second = await makeCoach(
			transport: turns.transport, intervals: otherCalendar, store: other, clock: turns.clock,
			tools: .workoutReview)

		let shown = try #require(await second.currentSnapshot(.main))

		#expect(
			Self.sentences(shown.notes[review.origin.turn]) == [
				Self.note([(.saved, "Threshold 2x2", "1998-09-09")])
			])
		#expect(shown.review == nil)
		#expect(try await second.desk.snapshot(chat: .main) == nil)
		#expect(try await second.desk.holdsBoundWork() == false)
		#expect(await second.desk.decide(.approve(token)) == .staleControl(newer: nil))
		#expect(otherCalendar.calls.isEmpty)
	}

	@Test func theFirstOutcomeOfAReviewWinsFromAnyDeviceInAnyOrder() throws {
		let review = WorkoutReviewID(ulid: fixedUlid(1))
		let first = outcome(
			of: review, on: DeviceID(rawValue: "phone-b"), wall: 2, ulid: fixedUlid(2),
			result: .saved)
		let later = outcome(
			of: review, on: DeviceID(rawValue: "phone-a"), wall: 3, ulid: fixedUlid(3),
			result: .mayHaveBeenSaved)
		var applied = ConversationFold.fold(
			chat: .main, synced: [later], device: DeviceID(rawValue: "phone-a"))
		applied.apply([first], device: DeviceID(rawValue: "phone-a"))
		let folded = ConversationFold.fold(
			chat: .main, synced: [later, first], device: DeviceID(rawValue: "phone-c"))

		let expected = [Self.note([(.saved, "Tempo ride", "1998-09-09")])]
		#expect(Self.sentences(applied.current.notes) == expected)
		#expect(Self.sentences(folded.current.notes) == expected)
	}

	@Test(arguments: GoneDelete.allCases)
	func aDeleteWhoseTargetWasAlreadyGoneReadsNoLongerOnTheCalendar(_ gone: GoneDelete)
		async throws
	{
		let rig = DeskRig()
		try await rig.save(
			try PreflightFixture.review([try PreflightFixture.delete(try rig.event(202))]))
		rig.calendar.answer { [rig] _, _ in
			switch gone {
			case .answered404:
				return .httpStatus(404)
			case .settledAfterLostAnswer:
				rig.base.events.removeAll { $0.id == EventID(rawValue: 202) }
				return .lost(.transport)
			}
		}
		let desk = try rig.desk()

		let outcome = await desk.decide(.approve(try await rig.token(on: desk)))

		#expect(outcome == .completed([ReviewReceipt(index: 0, progress: .noLongerOnCalendar)]))
		#expect(try await rig.outcomes().first?.lines.map(\.result) == [.noLongerOnCalendar])
		let shown = Self.sentences(try await rig.ledger().conversation(.main).current.notes)
		#expect(shown == [Self.note([(.noLongerOnCalendar, "Recovery", "1998-09-11")])])
		#expect(shown.first?.hasSuffix(": no longer on the calendar.") == true)
		#expect(shown.first?.contains("saved") == false)
	}

	@Test func aNewReviewAfterCancelingAnUnconfirmedChangeStartsAtRevisionOne() async throws {
		let coach = await coach()
		let canceled = try await turns.committed(Self.editOnly, on: coach)
		calendar.answer { [calendar] _, _ in
			calendar.failReads()
			return .lost(.transport)
		}
		guard case .unconfirmed = await coach.desk.decide(.approve(try await token(on: coach.desk)))
		else {
			Issue.record("the lost edit did not leave an unconfirmed change")
			return
		}
		calendar.restoreReads()
		guard case .canceled = await coach.desk.decide(.cancel(try await token(on: coach.desk)))
		else {
			Issue.record("the unconfirmed review was not canceled")
			return
		}
		let targetReads = turns.intervals.count(of: .event)

		let next = try await turns.committed(ReviewTurns.oneRide, on: coach)
		await coach.desk.recover()
		await coach.lifecycle(.becameActive)

		#expect(next.id != canceled.id)
		#expect(next.revision == ReviewRevision(rawValue: 1))
		#expect(next.stage == .waiting(.approval(.prepared)))
		#expect(turns.intervals.count(of: .event) == targetReads)
		#expect(calendar.writes.count == 1)
		try await coach.mailbox(for: .main).refreshImports()
		let shown = try #require(await coach.currentSnapshot(.main))
		#expect(
			Self.sentences(shown.notes[canceled.origin.turn]) == [
				Self.note([(.mayHaveBeenSaved, "Endurance", "1998-09-10")])
			])
		#expect(
			try await coach.desk.snapshot(chat: .main)?.ref.review == next.id)
	}

	@Test func aCompletedReviewsNoteReadsInTheChosenLanguage() async throws {
		let coach = await coach()
		let review = try await turns.committed(ReviewTurns.oneRide, on: coach)
		guard case .completed = await coach.desk.decide(.approve(try await token(on: coach.desk)))
		else {
			Issue.record("the review did not complete")
			return
		}

		try await coach.mailbox(for: .main).refreshImports()

		let notes = try #require(await coach.currentSnapshot(.main)?.notes[review.origin.turn])
		let french = displayLocale(.fr, region: "fr_FR")
		#expect(
			notes.map { $0.sentence(in: french) } == [
				"Threshold 2x2, 09/09/1998 : modification enregistrée."
			])
	}

	private func coach() async -> Coach {
		await makeCoach(
			transport: turns.transport, intervals: calendar, store: turns.store, clock: turns.clock,
			tools: .workoutReview)
	}

	private func token(on desk: WorkoutReviewDesk) async throws -> ReviewControlToken {
		let shown = try #require(try await desk.snapshot(chat: .main))
		#expect(await desk.decide(.presented(shown.ref)) == .presentationRecorded)
		guard
			case .armed(_, let token) = try #require(try await desk.snapshot(chat: .main)).controls
		else {
			throw UnexpectedReview(detail: "the review never armed its controls")
		}
		return token
	}

	private func outcome(
		of review: WorkoutReviewID, on device: DeviceID, wall: Int64, ulid: ULID,
		result: OutcomeLine.Result
	) -> AthleteRecord {
		storedRecord(
			device: device, wall: wall, ulid: ulid,
			body: .synced(
				.reviewOutcome(
					ReviewOutcomeBody(
						chatId: .main, review: review, revision: ReviewRevision(rawValue: 1),
						after: nil, ending: .completed,
						lines: [
							OutcomeLine(
								position: 0, action: .add, name: "Tempo ride", date: "1998-09-09",
								result: result)
						]))))
	}

	static func note(_ lines: [(OutcomeLine.Result, String, CivilDate)]) -> String {
		lines.map { result, name, date in
			english.say(key(of: result), ["workout": .text(name), "date": .day(date)])
		}.joined(separator: "\n")
	}

	static func sentences(_ notes: [TranscriptNote]?) -> [String] {
		(notes ?? []).map { $0.sentence(in: english) }
	}

	static func sentences(_ notes: [ReviewNote]) -> [String] {
		notes.map { TranscriptNote(id: $0.ulid, after: $0.after, content: $0.content) }
			.map { $0.sentence(in: english) }
	}

	private static func key(of result: OutcomeLine.Result) -> CatalogKey {
		switch result {
		case .saved: Catalog.workoutsOutcomeSaved
		case .seenOnCalendar: Catalog.workoutsOutcomeSeenOnCalendar
		case .noLongerOnCalendar: Catalog.workoutsOutcomeNoLongerOnCalendar
		case .givenUp: Catalog.workoutsOutcomeGivenUp
		case .mayHaveBeenSaved: Catalog.workoutsOutcomeMayHaveBeenSaved
		}
	}
}

extension Coach {
	func newestArchive() async throws -> ArchivedConversation {
		let newest = try #require(try await history().first)
		return try #require(try await archivedConversation(newest.id))
	}
}
