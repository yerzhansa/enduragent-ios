import EnduragentCoachFixtures
import Foundation
import Testing

@testable import EnduragentCoach

struct ReviewStageScreen {
	enum Shown {
		case review(ReviewSnapshot)
		case note(TranscriptNote)
	}

	let name: String
	let shown: Shown

	func lines(in display: DisplayLocale) -> [String] {
		switch shown {
		case .review(let review):
			let finished = review.cards.compactMap { $0.finishedLine(in: display) }
			return (review.notice?.sentences(in: display) ?? [])
				+ (finished.isEmpty ? [] : [display.say(Catalog.workoutsFinishedTitle)])
				+ finished + review.cards.compactMap { $0.status(in: display) }
		case .note(let note):
			return note.sentence(in: display).components(separatedBy: "\n")
				+ [note.closing(in: display)].compactMap { $0 }
		}
	}
}

enum ReviewStageScreens {
	static let names = [
		"partial", "retried", "unconfirmed", "seen", "sending", "could-not-check", "refreshed",
		"blocked", "canceled", "storage",
	]

	static func reached() async throws -> [ReviewStageScreen] {
		try await refusedThenRetried() + lostThenSeen() + [try await sending()]
			+ [try await couldNotCheck(), try await refreshed()] + blockedThenCanceled()
			+ [try await storage()]
	}

	private static func refusedThenRetried() async throws -> [ReviewStageScreen] {
		let rig = DeskRig()
		try await rig.save(try rig.mixed())
		rig.calendar.answer { index, write in
			if index == 2 { return .httpStatus(400) }
			if case .delete = write { return .httpStatus(404) }
			return nil
		}
		let desk = try rig.desk()
		_ = await desk.decide(.approve(try await rig.token(on: desk)))
		let partial = try await screen("partial", of: desk)
		_ = await desk.decide(.tryAgain(try await rig.token(on: desk)))
		return [partial, try await note("retried", of: rig)]
	}

	private static func lostThenSeen() async throws -> [ReviewStageScreen] {
		let rig = DeskRig()
		try await rig.save(try rig.mixed())
		rig.calendar.answer { [rig] index, write in
			guard index == 0 else { return nil }
			_ = await rig.keep(write)
			rig.calendar.failReads()
			return .lost(.transport)
		}
		let desk = try rig.desk()
		_ = await desk.decide(.approve(try await rig.token(on: desk)))
		let unconfirmed = try await screen("unconfirmed", of: desk)
		rig.calendar.restoreReads()
		_ = await desk.decide(.checkAgain(try await rig.token(on: desk)))
		return [unconfirmed, try await screen("seen", of: desk)]
	}

	private static func sending() async throws -> ReviewStageScreen {
		let rig = DeskRig()
		try await rig.save(try rig.mixed())
		let reader = try rig.desk()
		let seen = SeenSnapshot()
		rig.calendar.observe { touch in
			guard case .write(.create(let payload, _)) = touch, payload.name == "Strength" else {
				return
			}
			do {
				seen.record(try await reader.snapshot(chat: .main))
			} catch {
				Issue.record(error, "the review could not be read while it was sending")
			}
		}
		let desk = try rig.desk()
		_ = await desk.decide(.approve(try await rig.token(on: desk)))
		return ReviewStageScreen(name: "sending", shown: .review(try #require(seen.shown)))
	}

	private static func couldNotCheck() async throws -> ReviewStageScreen {
		let rig = DeskRig()
		try await rig.save(try rig.mixed())
		let desk = try rig.desk()
		let token = try await rig.token(on: desk)
		rig.calendar.failReads()
		_ = await desk.decide(.approve(token))
		return try await screen("could-not-check", of: desk)
	}

	private static func refreshed() async throws -> ReviewStageScreen {
		let rig = DeskRig()
		try await rig.save(try rig.mixed())
		rig.base.events[0].movingTime = 90 * 60
		let desk = try rig.desk()
		_ = await desk.decide(.approve(try await rig.token(on: desk)))
		return try await screen("refreshed", of: desk)
	}

	private static func blockedThenCanceled() async throws -> [ReviewStageScreen] {
		let rig = DeskRig()
		try await rig.save(try rig.mixed())
		rig.base.events.removeAll { $0.id == EventID(rawValue: 202) }
		let desk = try rig.desk()
		_ = await desk.decide(.approve(try await rig.token(on: desk)))
		let blocked = try await screen("blocked", of: desk)
		_ = await desk.decide(.cancel(try await rig.token(on: desk)))
		return [blocked, try await note("canceled", of: rig)]
	}

	private static func storage() async throws -> ReviewStageScreen {
		let rig = DeskRig()
		try await rig.save(try rig.mixed())
		let dying = FaultInjectingRecordLog(wrapping: rig.store)
		let desk = try rig.desk(over: dying)
		let token = try await rig.token(on: desk)
		try dying.failAppend(ofKind: DeviceLocalKind.workoutReview.rawValue, skipping: 2)
		_ = await desk.decide(.approve(token))
		return try await screen("storage", of: desk)
	}

	private static func screen(_ name: String, of desk: WorkoutReviewDesk) async throws
		-> ReviewStageScreen
	{
		ReviewStageScreen(
			name: name, shown: .review(try #require(try await desk.snapshot(chat: .main))))
	}

	private static func note(_ name: String, of rig: DeskRig) async throws -> ReviewStageScreen {
		ReviewStageScreen(
			name: name,
			shown: .note(try #require(try await ReviewProjectionStateTests.notes(rig).last)))
	}
}
