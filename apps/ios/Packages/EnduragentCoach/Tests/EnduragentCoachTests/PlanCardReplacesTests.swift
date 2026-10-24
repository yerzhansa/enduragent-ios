import EnduragentCoachFixtures
import Foundation
import Testing

@testable import EnduragentCoach

extension PlanConfirmationTests {
	static let raceWeek: JSONValue = .object([
		"name": .string("Race Week"), "totalWeeks": .number(1),
	])

	@Test func eachSavedCardNamesThePlanThatWasNewestBeforeItsSave() async throws {
		let coach = await turns.coach()
		let first = try await turns.prepareAndArm(PlanTurns.threshold, on: coach)
		#expect(try await replaces(on: coach) == [nil])
		#expect(await coach.decide(.save(first), in: .main) == .saved)
		#expect(try await replaces(on: coach) == [nil])

		let second = try await turns.prepareAndArm(PlanTurns.baseBuild, on: coach)
		#expect(try await replaces(on: coach) == [nil, "Threshold Block"])
		#expect(await coach.decide(.save(second), in: .main) == .saved)

		#expect(try await turns.cards(on: coach).map(\.state) == [.saved, .saved])
		#expect(try await replaces(on: coach) == [nil, "Threshold Block"])
	}

	enum Ending: String, CaseIterable, Sendable, CustomTestStringConvertible {
		case canceled
		case replaced
		case replacedThenExpired
		case expired

		var testDescription: String { rawValue }
	}

	@Test(arguments: Ending.allCases)
	func anEndedCardKeepsThePlanThatWasNewestWhenItEnded(_ ending: Ending) async throws {
		let coach = await turns.coach()
		let first = try await turns.prepareAndArm(PlanTurns.threshold, on: coach)
		#expect(await coach.decide(.save(first), in: .main) == .saved)
		let ended = try await turns.prepareAndArm(PlanTurns.baseBuild, on: coach)
		switch ending {
		case .canceled:
			#expect(await coach.decide(.cancel(ended), in: .main) == .canceled)
		case .expired:
			try await turns.clock.waitUntilHeld(.seconds(600))
			turns.clock.advance(by: .seconds(601))
			#expect(
				try await turns.waitForCards(on: coach) {
					$0.map(\.state) == [.saved, .expired]
				} != nil)
		case .replaced, .replacedThenExpired:
			break
		}

		let later = try await turns.prepareAndArm(Self.raceWeek, on: coach)
		#expect(await coach.decide(.save(later), in: .main) == .saved)
		let reader: Coach
		if ending == .replacedThenExpired {
			turns.clock.advance(by: .seconds(601))
			reader = await turns.coach()
		} else {
			reader = coach
		}

		let cards = try await turns.cards(on: reader)
		#expect(cards.map(\.state) == [.saved, ending == .canceled ? .canceled : .expired, .saved])
		#expect(cards.map(\.summary.replaces) == [nil, "Threshold Block", "Threshold Block"])
	}

	@Test func anExpiredCardIgnoresAPlanSavedAfterItReadExpired() async throws {
		let log = InterleavingChainLog(turns.store)
		let clock = turns.clock
		let store = turns.store
		log.interleave(on: .planChain(of: .main), times: 1) {
			clock.advance(by: .seconds(2))
			try await PlanTurns.moveHead(of: store, foreign: 7)
		}
		let coach = await turns.coach(over: log)
		_ = try await turns.reply(after: [[turns.save(PlanTurns.baseBuild)]], on: coach)
		let prepared = try #require(try await turns.prepared(in: turns.store).first)
		let step = try #require(
			try await turns.steps(in: turns.store).first { record in
				if case .prepared = record.body.step { return true }
				return false
			})
		#expect(step.hlc.wallTime > prepared.expiresAt.addingTimeInterval(-600))

		clock.advance(by: .seconds(598))
		#expect(clock.now == prepared.expiresAt)
		let expired = try await turns.cards(on: await turns.coach())
		#expect(expired.map(\.state) == [.expired])
		#expect(expired.map(\.summary.replaces) == [nil])

		let pad = DeviceID(rawValue: "plan-pad")
		let decided = HybridLogicalClock.tick(
			now: prepared.expiresAt.addingTimeInterval(1), deviceId: pad, last: nil)
		try await turns.store.append(
			[
				storedRecord(
					device: pad, wall: decided.wallMs, ulid: fixedUlid(3),
					account: testConnection.account,
					body: try SavedPlanRows.body(PlanTurns.threshold, decided: decided))
			], locality: .synced)
		clock.advance(by: .seconds(5))

		let later = try await turns.cards(on: await turns.coach())
		#expect(later.map(\.state) == [.expired])
		#expect(later.map(\.summary.replaces) == [nil])
	}

	@Test func aCarriedWaitingCardNamesAPlanSavedAfterTheReset() async throws {
		let coach = await turns.coach()
		_ = try await turns.prepareAndArm(PlanTurns.baseBuild, on: coach)
		_ = await coach.resetAndSettle(in: .main)
		#expect(try await replaces(on: coach) == [nil])

		turns.clock.advance(by: .seconds(60))
		let pad = DeviceID(rawValue: "plan-pad")
		let decided = HybridLogicalClock.tick(now: turns.clock.now, deviceId: pad, last: nil)
		try await turns.store.append(
			[
				storedRecord(
					device: pad, wall: decided.wallMs, ulid: fixedUlid(3),
					account: testConnection.account,
					body: try SavedPlanRows.body(PlanTurns.threshold, decided: decided))
			], locality: .synced)
		let reopened = await turns.coach()

		let carried = try await turns.cards(on: reopened)
		#expect(carried.map(\.placement) == [.preparedEarlier])
		#expect(carried.map(\.state) == [.waiting(.unarmed)])
		#expect(carried.map(\.summary.replaces) == ["Threshold Block"])
	}

	private func replaces(on coach: Coach) async throws -> [String?] {
		try await turns.cards(on: coach).map(\.summary.replaces)
	}
}
