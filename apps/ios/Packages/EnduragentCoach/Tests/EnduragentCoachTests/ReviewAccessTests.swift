import EnduragentCoachFixtures
import Foundation
import Synchronization
import Testing

@testable import EnduragentCoach

final class SwitchedTraining: Sendable {
	private let current: Mutex<Result<TrainingConnection, AccessUnavailable>>

	init(_ connection: TrainingConnection) {
		current = Mutex(.success(connection))
	}

	func answer(_ next: Result<TrainingConnection, AccessUnavailable>) {
		current.withLock { $0 = next }
	}

	func connection() throws(AccessUnavailable) -> TrainingConnection {
		try current.withLock { $0 }.get()
	}
}

extension DeskRig {
	static let rotated = TrainingAccount.intervals(
		connection: ConnectionID(), athlete: IntervalsAthleteID(rawValue: "i1001"))

	func connected(as account: TrainingAccount, to calendar: ScriptedCalendar? = nil)
		-> TrainingConnection
	{
		guard case .intervals(let connection, let athlete?) = account else { return .unconnected }
		return .connected(
			ConnectedTraining(
				connection: connection, athlete: athlete, client: calendar ?? self.calendar))
	}

	func desk(training: SwitchedTraining) -> WorkoutReviewDesk {
		WorkoutReviewDesk(
			ledger: ledger(), clock: clock, diagnostics: DiagnosticsLog(clock: clock),
			training: { _ throws(AccessUnavailable) in try training.connection() }, host: host)
	}
}

@Suite struct ReviewAccessTests {
	struct Authority: Sendable, CustomTestStringConvertible {
		let testDescription: String
		let reviewed: TrainingAccount
		let current: TrainingAccount
		let block: ReviewBlock
	}

	struct SameAthlete: Sendable, CustomTestStringConvertible {
		let testDescription: String
		let reviewed: TrainingAccount
		let current: TrainingAccount
	}

	enum Unreachable: String, CaseIterable, Sendable, CustomTestStringConvertible {
		case locked, unverified, otherAthlete

		var testDescription: String { rawValue }
	}

	static let unreadable: [AccessUnavailable] = [
		.secureStorageLocked, .trainingIdentityUnverified(.temporarilyUnavailable),
		.trainingIdentityUnverified(.credentialRejected),
	]

	static let unresolved = TrainingAccount.intervals(
		connection: PreflightFixture.connection, athlete: nil)

	static let authorities = [
		Authority(
			testDescription: "unconnected then and now", reviewed: .unconnected,
			current: .unconnected, block: .trainingNotConnected),
		Authority(
			testDescription: "disconnected since the review", reviewed: PreflightFixture.account,
			current: .unconnected, block: .accountChanged),
		Authority(
			testDescription: "another athlete's key", reviewed: PreflightFixture.account,
			current: PreflightFixture.otherAthlete, block: .accountChanged),
		Authority(
			testDescription: "an unresolved review under a replacement connection",
			reviewed: unresolved, current: DeskRig.rotated, block: .accountChanged),
	]

	static let sameAthlete = [
		SameAthlete(
			testDescription: "same athlete under a rotated key",
			reviewed: PreflightFixture.account, current: DeskRig.rotated),
		SameAthlete(
			testDescription: "the same connection resolved after the review",
			reviewed: unresolved, current: PreflightFixture.account),
	]

	@Test(arguments: unreadable)
	func aLookupThatCannotReadTheAccountAtApprovalPausesTheReviewAndSendsNothing(
		_ failure: AccessUnavailable
	) async throws {
		let rig = DeskRig()
		let review = try rig.mixed()
		try await rig.save(review)
		let training = SwitchedTraining(rig.connected(as: PreflightFixture.account))
		training.answer(.failure(failure))
		let desk = rig.desk(training: training)

		let outcome = await desk.decide(.approve(try await rig.token(on: desk)))

		guard case .stopped(let receipts, let notice) = outcome else {
			Issue.record("an unreadable account at approval ended \(outcome)")
			return
		}
		#expect(receipts.isEmpty)
		#expect(notice.key == Catalog.reviewCannotVerify)
		#expect(rig.calendar.calls.isEmpty)
		#expect(try await rig.head().1?.stage == .waiting(.approval(.couldNotCheck)))
		training.answer(.success(rig.connected(as: PreflightFixture.account)))

		guard
			case .completed(let saved) = await desk.decide(.approve(try await rig.token(on: desk)))
		else {
			Issue.record("the paused review did not run once the account could be read")
			return
		}
		#expect(saved.count == review.work.remaining.count)
		#expect(rig.calendar.writes == review.work.remaining.map(DeskRig.request))
	}

	@Test(arguments: authorities)
	func anAccountThatNoLongerOwnsTheReviewBlocksItBeforeAnyCalendarCall(_ scenario: Authority)
		async throws
	{
		let rig = DeskRig()
		try await rig.save(
			try PreflightFixture.review(
				[PreflightFixture.ride(on: "1998-09-09", identity: CalendarWriteID())],
				account: scenario.reviewed))
		let desk = rig.desk(training: SwitchedTraining(rig.connected(as: scenario.current)))
		let shown = try #require(try await desk.snapshot(chat: .main))

		#expect(
			await desk.decide(.approve(try await rig.token(on: desk))) == .blocked(scenario.block))

		#expect(rig.calendar.calls.isEmpty)
		#expect(try await rig.head().1?.stage == .waiting(.blocked(scenario.block)))
		let blocked = try #require(try await desk.snapshot(chat: .main))
		#expect(blocked.cards == shown.cards)
		#expect(blocked.attribution == shown.attribution)
		let reopened = try #require(
			try await rig.desk(training: SwitchedTraining(rig.connected(as: scenario.current)))
				.snapshot(chat: .main))
		#expect(reopened.cards == shown.cards)
		#expect(reopened.attribution == shown.attribution)
	}

	@Test(arguments: sameAthlete)
	func theSameAthleteUnderAnotherOrAResolvedConnectionStillRunsTheReview(_ scenario: SameAthlete)
		async throws
	{
		let rig = DeskRig()
		let review = try PreflightFixture.review(
			[
				PreflightFixture.ride(on: "1998-09-09", identity: CalendarWriteID()),
				rig.strength(on: "1998-09-12"),
			], account: scenario.reviewed)
		try await rig.save(review)
		let desk = rig.desk(training: SwitchedTraining(rig.connected(as: scenario.current)))

		let outcome = await desk.decide(.approve(try await rig.token(on: desk)))

		guard case .completed(let receipts) = outcome else {
			Issue.record("the same athlete's review ended \(outcome)")
			return
		}
		#expect(receipts.count == 2)
		#expect(rig.calendar.writes == review.work.remaining.map(DeskRig.request))
	}

	@Test(arguments: Unreachable.allCases)
	func checkAgainUnderAnAccountItCannotUseReadsNothingAndKeepsTheToken(_ cause: Unreachable)
		async throws
	{
		let unconfirmed = try await CheckAgainTests.Unconfirmed(.add)
		let rig = unconfirmed.rig
		let calendar = unconfirmed.calendar
		let account = rig.connected(as: PreflightFixture.account, to: calendar)
		let training = SwitchedTraining(account)
		let desk = rig.desk(training: training)
		let token = try await rig.token(on: desk)
		let records = try await rig.records()
		switch cause {
		case .locked: training.answer(.failure(.secureStorageLocked))
		case .unverified:
			training.answer(.failure(.trainingIdentityUnverified(.temporarilyUnavailable)))
		case .otherAthlete:
			training.answer(
				.success(rig.connected(as: PreflightFixture.otherAthlete, to: calendar)))
		}

		guard case .unconfirmed = await desk.decide(.checkAgain(token)) else {
			Issue.record("Check again under an unusable account settled the change")
			return
		}

		#expect(calendar.calls.isEmpty)
		#expect(try await rig.records() == records)
		try await unconfirmed.expectStillUnconfirmed()
		training.answer(.success(account))

		guard case .stopped = await desk.decide(.checkAgain(token)) else {
			Issue.record("the kept token did not read the change once the account was usable")
			return
		}
		#expect(calendar.calls == [.read])
		#expect(calendar.writes.isEmpty)
		#expect(
			try await rig.head().1?.work.finished.map(FinishedTag.init) == unconfirmed.settled(.add)
		)
	}

	@Test func aCancelWhoseSaveFailsKeepsTheReviewSendsNothingAndSaysSoInTheChosenLanguage()
		async throws
	{
		let faults = FaultInjectingRecordLog(wrapping: InMemoryRecordLog())
		let rig = DeskRig(store: faults)
		let review = try rig.mixed()
		try await rig.save(review)
		let desk = try rig.desk()
		let token = try await rig.token(on: desk)
		try faults.failAppend(ofKind: "workoutReview", skipping: 0)

		let outcome = await desk.decide(.cancel(token))

		#expect(outcome == .storageUnavailable)
		let notice = try #require(outcome.notice)
		#expect(
			notice.sentence(in: displayLocale())
				== "Couldn't save your choice on this iPhone, so nothing was changed. Try again.")
		#expect(
			notice.sentence(in: displayLocale(.fr, region: "fr_FR"))
				== "Impossible d’enregistrer votre choix sur cet iPhone. Rien n’a donc été modifié. Réessayez."
		)
		#expect(rig.calendar.calls.isEmpty)
		#expect(try await rig.chain() == [review])
		let stalled = try #require(try await desk.snapshot(chat: .main))
		#expect(stalled.notice?.kind == .storageUnavailable)
		#expect(stalled.cards.count == review.work.remaining.count)

		await desk.recover()

		#expect(await desk.decide(.cancel(token)) == .canceled([]))
		#expect(rig.calendar.calls.isEmpty)
		#expect(
			try await rig.head().1?.stage
				== .canceled(Cancellation(givenUp: review.work.remaining, unconfirmed: nil)))
	}

	@Test func aReviewThatCannotBeReadRefusesEveryDecisionUntilReadsReturn() async throws {
		let faults = FaultInjectingRecordLog(wrapping: InMemoryRecordLog())
		let rig = DeskRig(store: faults)
		let review = try rig.mixed()
		try await rig.save(review)
		let desk = try rig.desk()
		let token = try await rig.token(on: desk)
		faults.failFetches = true

		#expect(await desk.decide(.approve(token)) == .storageUnavailable)
		#expect(await desk.decide(.cancel(token)) == .storageUnavailable)
		#expect(await desk.decide(.checkAgain(token)) == .storageUnavailable)

		#expect(rig.calendar.calls.isEmpty)
		faults.failFetches = false
		#expect(try await rig.chain() == [review])
		guard case .completed(let receipts) = await desk.decide(.approve(token)) else {
			Issue.record("the kept token did not run the review once reads returned")
			return
		}
		#expect(receipts.count == review.work.remaining.count)
		#expect(rig.calendar.writes == review.work.remaining.map(DeskRig.request))
	}
}
