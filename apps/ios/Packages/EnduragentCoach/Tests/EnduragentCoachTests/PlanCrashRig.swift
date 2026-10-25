import EnduragentCoachFixtures
import Foundation
import Testing

@testable import EnduragentCoach

enum PlanCrashPoint: String, CaseIterable, Sendable {
	case s0
	case s1
	case s2
	case s3
	case s4
	case s4a
	case s5
	case s6
	case e1
	case c1
	case c2
}

struct PlanCrash: Sendable {
	let turn: TurnID
	let token: PlanSaveToken?
	let claim: SaveClaim?
}

struct PlanCrashReading: Sendable, Equatable {
	let cards: [PlanCardState]
	let offersTryAgain: Bool
	let claimRows: Int
	let steps: Int
}

struct PlanRelaunch {
	let coach: Coach
	let turns: PlanTurns
	let log: SwiftDataRecordLog

	func reading(of crash: PlanCrash) async throws -> PlanCrashReading {
		let rows =
			if let claim = crash.claim {
				try await SavedPlanRows.stored(claim.savedPlan, in: log)
			} else {
				try await SavedPlanRows.stored(in: log)
			}
		return PlanCrashReading(
			cards: try await turns.cards(on: coach).map(\.state),
			offersTryAgain: Self.offersTryAgain(await coach.state(of: crash.turn), crash.turn),
			claimRows: rows.count, steps: try await turns.steps(in: log).count)
	}

	private static func offersTryAgain(_ state: TurnState?, _ turn: TurnID) -> Bool {
		let notice: AthleteNotice?
		switch state {
		case .savedWork(let saved)?: notice = saved.notice
		case .failed(let failed)?: notice = failed.notice
		case .interrupted(let interrupted)?: notice = interrupted.notice
		case .unrecovered(let unrecovered)?: notice = unrecovered.notice
		case .accepted?, .processing?, .completed?, nil: notice = nil
		}
		return notice?.actions.contains { action in
			action == .tryAgain(turn) || action == .wait(thenTryAgain: turn)
		} == true
	}
}

struct PlanCrashRig {
	static let device = DeviceID(rawValue: "plan-crash-phone")
	static let earlier: JSONValue = .object([
		"name": .string("Winter Base"), "totalWeeks": .number(8),
	])

	let clock = HeldClock()
	let folder: URL
	let secrets = keyedSecrets()

	init() throws {
		folder = try TestTemporaryFolders.make()
	}

	func relaunch() async throws -> PlanRelaunch {
		let turns = PlanTurns(clock: clock)
		let log = try SwiftDataSuites.makeSwiftDataLog(deviceId: Self.device, directory: folder)
		return PlanRelaunch(
			coach: await turns.coach(over: log, secrets: secrets), turns: turns, log: log)
	}

	func stop(_ point: PlanCrashPoint) async throws -> PlanCrash {
		let store = try SwiftDataSuites.makeSwiftDataLog(deviceId: Self.device, directory: folder)
		let dying = FaultInjectingRecordLog(wrapping: store)
		let turns = PlanTurns(clock: clock)
		let old = PlanCrashProcess(
			store: store, dying: dying, turns: turns,
			coach: await turns.coach(over: dying, secrets: secrets))
		let coach = old.coach
		let crash: PlanCrash
		switch point {
		case .s0:
			turns.script([turns.save(PlanTurns.baseBuild), .finish(reason: .toolCalls), .hang])
			let turn = try #require(
				try await coach.send(draft("Save my plan"), to: .main).acceptedTurn)
			try await waitUntil { turns.transport.requests.count >= 2 }
			crash = PlanCrash(turn: turn, token: nil, claim: nil)
		case .s1:
			for kind in ["turnSettled", "pendingSettlement"] {
				try dying.failAppends(ofKind: kind)
			}
			let turn = try await turns.reply(after: [[turns.save(PlanTurns.baseBuild)]], on: coach)
			crash = PlanCrash(turn: turn, token: try await turns.armedToken(on: coach), claim: nil)
		case .e1:
			let turn = try await turns.reply(after: [[turns.save(PlanTurns.baseBuild)]], on: coach)
			let token = try await turns.armedToken(on: coach)
			try await clock.waitUntilHeld(Plans.lifetime)
			clock.advance(by: Plans.lifetime)
			let expired = try await turns.waitForCards(on: coach) { $0.map(\.state) == [.expired] }
			try #require(expired != nil)
			crash = PlanCrash(turn: turn, token: token, claim: nil)
		case .s6:
			let saved = try await turns.prepareAndArm(Self.earlier, on: coach)
			#expect(await coach.decide(.save(saved), in: .main) == .saved)
			let turn = try await turns.reply(after: [[turns.save(PlanTurns.threshold)]], on: coach)
			let token = try await turns.armedToken(on: coach)
			try dying.failAppend(ofKind: SavedPlans.kind.rawValue, skipping: 0)
			#expect(await coach.decide(.save(token), in: .main) == .storageUnavailable)
			let later = try await turns.prepareAndArm(PlanTurns.baseBuild, on: coach)
			#expect(await coach.decide(.save(later), in: .main) == .saved)
			crash = PlanCrash(turn: turn, token: token, claim: try await claim(of: token, in: old))
		case .s2:
			crash = try await tapped(.save, allowing: 0, .storageUnavailable, on: old)
		case .s3:
			crash = try await tapped(.save, allowing: 1, .storageUnavailable, on: old)
		case .s4:
			crash = try await tapped(.save, allowing: 2, .storageUnavailable, on: old)
		case .s4a:
			crash = try await tapped(
				.saveLosingItsAnswer, allowing: nil, .storageUnavailable, on: old)
		case .s5:
			crash = try await tapped(.save, allowing: nil, .saved, on: old)
		case .c1:
			crash = try await tapped(.cancel, allowing: 0, .storageUnavailable, on: old)
		case .c2:
			crash = try await tapped(.cancel, allowing: 1, .canceled, on: old)
		}
		dying.refuseEveryAppend(after: 0)
		dying.failFetches = true
		return crash
	}

	private func tapped(
		_ tap: PlanCrashTap, allowing appends: Int?, _ answer: PlanDecisionOutcome,
		on old: PlanCrashProcess
	) async throws -> PlanCrash {
		let turn = try await old.turns.reply(
			after: [[old.turns.save(PlanTurns.baseBuild)]], on: old.coach)
		let token = try await old.turns.armedToken(on: old.coach)
		if let appends { old.dying.refuseEveryAppend(after: appends) }
		let decision: PlanDecision =
			switch tap {
			case .save, .saveLosingItsAnswer: .save(token)
			case .cancel: .cancel(token)
			}
		if tap == .saveLosingItsAnswer { old.dying.failSyncedAcknowledgments = true }
		#expect(await old.coach.decide(decision, in: .main) == answer)
		return PlanCrash(
			turn: turn, token: token, claim: try await claim(of: token, in: old))
	}

	private func claim(of token: PlanSaveToken, in old: PlanCrashProcess) async throws
		-> SaveClaim?
	{
		try await old.turns.claims(in: old.store).first {
			$0.0.body.confirmation == token.ref.confirmation
		}?.1
	}
}

private enum PlanCrashTap {
	case save
	case saveLosingItsAnswer
	case cancel
}

private struct PlanCrashProcess {
	let store: SwiftDataRecordLog
	let dying: FaultInjectingRecordLog
	let turns: PlanTurns
	let coach: Coach
}
