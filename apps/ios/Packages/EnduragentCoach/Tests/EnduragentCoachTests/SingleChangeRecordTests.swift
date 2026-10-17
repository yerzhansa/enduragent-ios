import EnduragentCoachFixtures
import Foundation
import Testing

@testable import EnduragentCoach

extension UnionMergeTests {
	@Test func proposalClearedThenAbsent() {
		let nonce = Nonce()
		let now = Date(timeIntervalSince1970: 899_164_800)
		let live = record(
			device: phoneA,
			wall: 1,
			ulid: ulid(1),
			body: .deviceLocal(
				.pendingProposal(
					sampleProposal(
						chatId: .main, nonce: nonce, expiresAt: now.addingTimeInterval(600))))
		)
		#expect(UnionMerge.pendingProposal([live], chatId: .main, now: now)?.nonce == nonce)
		let cleared = record(
			device: phoneA,
			wall: 2,
			ulid: ulid(2),
			body: .deviceLocal(
				.proposalCleared(
					ProposalClearedBody(chatId: .main, nonce: nonce, reason: .executed)))
		)
		#expect(UnionMerge.pendingProposal([live, cleared], chatId: .main, now: now) == nil)
		let expired = record(
			device: phoneA,
			wall: 3,
			ulid: ulid(3),
			body: .deviceLocal(
				.pendingProposal(sampleProposal(chatId: .main, nonce: Nonce(), expiresAt: now)))
		)
		#expect(UnionMerge.pendingProposal([expired], chatId: .main, now: now) == nil)
	}

	@Test func canceledClearHidesTheProposalAndTheLiveRecordKeepsItsIdentity() {
		let nonce = Nonce()
		let now = Date(timeIntervalSince1970: 899_164_800)
		let live = record(
			device: phoneA,
			wall: 1,
			ulid: ulid(1),
			body: .deviceLocal(
				.pendingProposal(
					sampleProposal(
						chatId: .main, nonce: nonce, expiresAt: now.addingTimeInterval(600))))
		)
		let found = UnionMerge.pendingProposalRecord([live], chatId: .main, now: now)
		#expect(found?.ulid == live.ulid)
		#expect(found?.account == live.account)
		let canceled = record(
			device: phoneA,
			wall: 2,
			ulid: ulid(2),
			body: .deviceLocal(
				.proposalCleared(
					ProposalClearedBody(chatId: .main, nonce: nonce, reason: .canceled)))
		)
		#expect(UnionMerge.pendingProposalRecord([live, canceled], chatId: .main, now: now) == nil)
	}
}

extension SwiftDataSuites.UpgradeStoreTests {
	@Test func pendingV1ReviewIsReadOnly() async throws {
		let log = try open("review")
		let transport = FakeModelTransport()
		let coach = await makeCoach(transport: transport, store: log)
		let review = try #require(await coach.currentSnapshot(.main)?.review)
		#expect(review.authority == .readOnly)
		#expect(review.controls == .none)
		#expect(review.notice?.key == Catalog.reviewEarlierVersion)
		#expect(transport.requests.isEmpty)
		let page = try await log.fetch(
			RecordQuery(
				scope: .deviceLocal([.pendingProposal, .proposalCleared])))
		#expect(page.skipped.isEmpty)
		#expect(kinds(page.records) == ["pendingProposal"])
	}
}

extension RetryLadderTests {
	@Test func committedCalendarWriteSettlesWritesSaved() {
		let calendar = situation(
			committed: [
				CommittedWrite(tool: .memoryWrite), CommittedWrite(tool: .intervalsCreateWorkout),
			])
		#expect(
			RetryLadder.npm.decide(
				.provider(.serverError(status: 500, retryAfter: nil)), situation: calendar,
				counters: .zero) == .settleSavedWork(.writesSaved))
		#expect(
			RetryLadder.npm.decide(.windowExceededFinish, situation: calendar, counters: .zero)
				== .settleSavedWork(.writesSaved))
		let notice = AthleteNotices.notice(for: .writesSaved)
		#expect(notice.key == Catalog.coachFallbackWritesSaved)
		#expect(notice.actions.isEmpty)
	}
}

extension ReviewNoticeMappingTests {
	static let oldPath: [Row] = [
		Row(name: "completed", outcome: .completed(saved), notice: nil),
		Row(name: "canceled", outcome: .canceled([]), notice: nil),
		Row(name: "presentationRecorded", outcome: .presentationRecorded, notice: nil),
		Row(
			name: "unconfirmed pending", outcome: .unconfirmed([], pending),
			notice: AthleteNotice(key: Catalog.reviewWritePending, actions: [])),
		Row(
			name: "unconfirmed read failed", outcome: .unconfirmed([], readFailed),
			notice: AthleteNotice(key: Catalog.reviewWriteReadFailed, actions: [])),
		Row(
			name: "blocked accountChanged", outcome: .blocked(.accountChanged),
			notice: AthleteNotice(key: Catalog.reviewAccountChanged, vars: intervals, actions: [])),
		Row(
			name: "blocked trainingNotConnected", outcome: .blocked(.trainingNotConnected),
			notice: AthleteNotice(key: Catalog.connectMissing, actions: [.connectTraining])),
		Row(
			name: "blocked cannotVerify", outcome: .blocked(.cannotVerify),
			notice: AthleteNotice(key: Catalog.reviewCannotVerify, vars: intervals, actions: [])),
		Row(
			name: "blocked turnStopping", outcome: .blocked(.turnStopping),
			notice: AthleteNotice(key: Catalog.reviewTurnStopping, actions: [])),
		Row(
			name: "staleControl", outcome: .staleControl(newer: nil),
			notice: AthleteNotice(key: Catalog.coachConfirmationExpired, actions: [])),
		Row(
			name: "storageUnavailable", outcome: .storageUnavailable,
			notice: AthleteNotice(key: Catalog.reviewSaveFailed, actions: [])),
	]

	@Test(arguments: oldPath)
	func eachOutcomeTheOldPathGivesKeepsItsNotice(_ row: Row) {
		#expect(row.outcome.notice == row.notice)
	}
}

extension ToolOfferTests {
	@Test func everyToolIsDefinedUnderTheNameItsEffectCarriesAndOnlyGatedToolsPropose() {
		let defined = ToolName.allCases.compactMap { name in
			CoachTools.definition(of: name).map { (name: name, effect: $0.effect) }
		}

		#expect(defined.map(\.name) == ToolName.allCases.filter { $0 != .planSave })
		for (name, effect) in defined {
			#expect(effect.name == name)
			let proposes = if case .proposal = effect { true } else { false }
			#expect(proposes == (GatedToolName(rawValue: name.rawValue) != nil), "\(name)")
		}
	}
}

extension IntervalsRESTClientTests {
	enum IneligibleTarget: Sendable {
		case race, athleteOwned, past, movedIntoThePast

		var event: CalendarEvent {
			let owned = self == .past || self == .movedIntoThePast
			return CalendarEvent(
				id: EventID(rawValue: 43),
				startDateLocal: self == .past ? "1998-06-12T00:00:00" : "1998-06-20T00:00:00",
				name: "Endurance", category: self == .race ? "RACE_A" : "WORKOUT",
				externalId: nil, uid: nil, tags: owned ? [IntervalsPolicy.coachTag] : [],
				coachCreated: owned)
		}

		var code: String {
			switch self {
			case .race: "not_a_workout"
			case .athleteOwned: "not_coach_created"
			case .past: "past_workout_protected"
			case .movedIntoThePast: "past_workout_destination"
			}
		}
	}

	@Test(arguments: [
		(IneligibleTarget.race, false), (.race, true), (.athleteOwned, false),
		(.athleteOwned, true), (.past, false), (.past, true), (.movedIntoThePast, false),
	])
	func theOldPathRefusesAnIneligibleTargetWithTodaysCodeBeforeItWrites(
		target: IneligibleTarget, deleting: Bool
	) async throws {
		let client = FakeIntervalsClient(athleteName: "Ada", ftp: 250)
		client.events = [target.event]
		let id = target.event.id
		let input: GatedToolInput =
			deleting
			? .deleteWorkout(eventId: id)
			: .updateWorkout(
				UpdateWorkoutInput(
					eventId: id, date: target == .movedIntoThePast ? "1998-06-12" : nil,
					name: "Endurance", description: nil))
		do {
			_ = try await CalendarWriteOperation.prepare(
				try oldPathProposal(input, writeID: nil), client: client, today: "1998-06-13")
			Issue.record("expected \(target.code)")
		} catch let error as IntervalsError {
			#expect(error.code == target.code)
		}
		#expect(client.calls.allSatisfy { !$0.isWrite })
	}
}
