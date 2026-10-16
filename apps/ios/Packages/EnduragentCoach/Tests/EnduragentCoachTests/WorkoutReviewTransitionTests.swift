import Foundation
import Testing

@testable import EnduragentCoach

enum Landing: Equatable, Sendable {
	case approval(ApprovalReason)
	case tryAgain(TryAgainReason)
	case unconfirmed
	case blocked(ReviewBlock)
	case checking
	case sending
	case completed
	case canceled
	case readFirst
	case unchanged
	case refused(TransitionRefusal)

	init(_ outcome: Outcome) {
		self =
			switch outcome {
			case .moved(let review):
				switch review.stage {
				case .waiting(.approval(let reason)): .approval(reason)
				case .waiting(.tryAgain(let reason)): .tryAgain(reason)
				case .waiting(.unconfirmed): .unconfirmed
				case .waiting(.blocked(let block)): .blocked(block)
				case .running(let run): run.sending == nil ? .checking : .sending
				case .completed: .completed
				case .canceled: .canceled
				}
			case .stayed: .unchanged
			case .readFirst: .readFirst
			}
	}
}

enum Outcome: Sendable {
	case moved(WorkoutReview)
	case stayed
	case readFirst(SendAttempt)
}

struct Transition: Sendable, CustomTestStringConvertible {
	let name: String
	let settles: Bool
	let lands: [ReviewStage: Landing]
	let apply: @Sendable (WorkoutReview) throws -> Outcome

	var testDescription: String { name }

	static func moving(
		_ name: String, _ lands: [ReviewStage: Landing],
		_ move: @escaping @Sendable (WorkoutReview) throws -> WorkoutReview
	) -> Transition {
		Transition(name: name, settles: false, lands: lands) { review in
			.moved(try move(review))
		}
	}

	static func settling(_ read: SettleRead, _ lands: [ReviewStage: Landing]) -> Transition {
		Transition(name: "settled(\(read))", settles: true, lands: lands) {
			review in
			try review.settled(read).map(Outcome.moved) ?? .stayed
		}
	}

	static func answering(_ answer: SendAnswer, _ lands: [ReviewStage: Landing]) -> Transition {
		Transition(name: "answered(\(answer))", settles: false, lands: lands) {
			review in
			switch try review.answered(answer, at: reviewClock) {
			case .next(let next): .moved(next)
			case .readFirst(let attempt): .readFirst(attempt)
			}
		}
	}
}

struct WorkoutReviewTransitionTests {
	static let edit = reviewChange(402)
	static let differences = [TargetDifference(change: edit, fields: [.duration])]
	static let current = WorkoutSnapshot(
		date: "1998-06-17", name: "Endurance", durationSeconds: 5400, description: "Steady ride",
		load: 50, structure: nil)
	static let found: [ReviewStage: Landing] = [
		.sending: .tryAgain(.settled), .sendingLast: .completed, .unconfirmed: .tryAgain(.settled),
		.unconfirmedUpgraded: .tryAgain(.settled),
	]
	static let checks: [ReviewStage] = [.checking, .checkingAfterWork]
	static let waits: [ReviewStage] = [
		.approval, .tryAgain, .unconfirmed, .blocked, .unconfirmedUpgraded,
	]

	static let transitions: [Transition] = [
		.moving("claimed(approve)", [.approval: .checking, .tryAgain: .refused(.wrongAction)]) {
			try $0.claimed(Claim(id: claimID(9), action: .approve))
		},
		.moving("claimed(tryAgain)", [.tryAgain: .checking, .approval: .refused(.wrongAction)]) {
			try $0.claimed(Claim(id: claimID(9), action: .tryAgain))
		},
		.moving("refreshed", landing(checks, .approval(.refreshed(differences)))) {
			try $0.refreshed([edit: current], kept: [], differences: differences)
		},
		.moving("blocked", landing(checks, .blocked(.cannotVerify))) {
			try $0.blocked(.cannotVerify)
		},
		.moving(
			"pausedUnchecked",
			[.checking: .approval(.couldNotCheck), .checkingAfterWork: .tryAgain(.couldNotCheck)]
		) { try $0.pausedUnchecked() },
		.moving("sending", landing(checks, .sending)) {
			try $0.sending(at: reviewClock, seen: [:])
		},
		.moving(
			"restoredAfterInterruption",
			[
				.checking: .approval(.interruptedBeforeWriting),
				.checkingAfterWork: .tryAgain(.interrupted),
			]
		) { try $0.restoredAfterInterruption() },
		.moving("canceled", landing(waits, .canceled)) { try $0.canceled() },
		.answering(
			.refused(.rateLimited),
			[
				.sending: .tryAgain(.refused(reviewChange(401), .rateLimited)),
				.sendingLast: .tryAgain(.refused(reviewChange(405), .rateLimited)),
			]),
		.answering(.lost(.transport), [.sending: .readFirst, .sendingLast: .readFirst]),
		.answering(.gone, [.sending: .readFirst, .sendingLast: .readFirst]),
		.settling(.seen(EventID(rawValue: 301)), found),
		.settling(.gone, found),
		.settling(
			.notSaved,
			[
				.sending: .approval(.interruptedBeforeWriting),
				.unconfirmed: .approval(.interruptedBeforeWriting),
				.sendingLast: .tryAgain(.notSaved(reviewChange(405))),
				.unconfirmedUpgraded: .blocked(.reviewedBeforeUpgrade),
			]),
		.settling(
			.readFailed,
			[
				.sending: .unconfirmed, .sendingLast: .unconfirmed, .unconfirmed: .unchanged,
				.unconfirmedUpgraded: .unchanged,
			]),
	]

	static func landing(_ stages: [ReviewStage], _ landing: Landing) -> [ReviewStage: Landing] {
		Dictionary(uniqueKeysWithValues: stages.map { ($0, landing) })
	}

	@Test(arguments: transitions)
	func everyStageLandsWhereTheTransitionSays(_ transition: Transition) throws {
		let stages = try ReviewStages()
		for stage in ReviewStage.allCases {
			let before = try stages[stage]
			let landing: Landing
			do {
				let outcome = try transition.apply(before)
				landing = Landing(outcome)
				if case .moved(let after) = outcome {
					expectEveryChangeInOnePlace(before: before, after: after)
				}
			} catch let refusal as TransitionRefusal {
				landing = .refused(refusal)
			}
			#expect(
				landing == transition.lands[stage] ?? .refused(.wrongStage),
				"\(transition.name) from \(stage)")
			if transition.settles {
				#expect(![.checking, .sending].contains(landing), "a settle from \(stage) runs on")
			}
		}
	}

	@Test(arguments: ReviewStage.allCases)
	func everyStageAndDriveStartPlanTheDocumentedStep(_ stage: ReviewStage) throws {
		let review = try ReviewStages()[stage]
		let attempt: SendAttempt? =
			switch review.stage {
			case .running(let run): run.sending
			case .waiting(.unconfirmed(let attempt)): attempt
			case .waiting, .completed, .canceled: nil
			}
		for summarySaved in [false, true] {
			let expected: (claimed: NextStep, resume: NextStep)
			switch stage {
			case .checking, .checkingAfterWork:
				expected = (.preflight, .restore)
			case .sending, .sendingLast:
				expected = (.send(try #require(attempt)), .settle(try #require(attempt)))
			case .unconfirmed, .unconfirmedUpgraded:
				expected = (.idle, .settle(try #require(attempt)))
			case .approval, .tryAgain, .blocked:
				expected = (.idle, .idle)
			case .completed, .canceled:
				expected = summarySaved ? (.idle, .idle) : (.publish, .publish)
			}
			#expect(review.nextStep(.claimed, summarySaved: summarySaved) == expected.claimed)
			#expect(review.nextStep(.resume, summarySaved: summarySaved) == expected.resume)
		}
		let controls: [ReviewStage: ControlSet] = [
			.approval: .approveOrCancel, .tryAgain: .tryAgainOrCancel,
			.unconfirmed: .checkAgainOrCancel, .unconfirmedUpgraded: .checkAgainOrCancel,
			.blocked: .cancelOnly,
		]
		#expect(review.allowedControls == controls[stage])
	}

	private func expectEveryChangeInOnePlace(before: WorkoutReview, after: WorkoutReview) {
		let placed = placedChanges(after)
		#expect(Set(placed).count == placed.count)
		#expect(Set(placed) == Set(placedChanges(before)))
		#expect(
			Array(after.work.finished.prefix(before.work.finished.count)) == before.work.finished)
		let finished = Set(after.work.finished.map(\.change.id))
		#expect(finished.isDisjoint(with: after.work.remaining.map(\.id)))
		#expect(finished.isDisjoint(with: after.stage.changes.map(\.id)))
	}
}
