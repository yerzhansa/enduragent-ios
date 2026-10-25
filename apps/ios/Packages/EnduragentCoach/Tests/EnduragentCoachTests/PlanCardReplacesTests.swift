import EnduragentCoachFixtures
import Foundation
import Testing

@testable import EnduragentCoach

extension PlanConfirmationTests {
	static let raceWeek: JSONValue = .object([
		"name": .string("Race Week"), "totalWeeks": .number(1),
	])
	static let peakWeek: JSONValue = .object([
		"name": .string("Peak Week"), "totalWeeks": .number(1),
	])
	static let taper: JSONValue = .object([
		"name": .string("Taper"), "totalWeeks": .number(1),
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
		case replacedByACardThatWasReplacedLater
		case replacedByACardThatWasSavedAfterItExpired
		case expired

		var testDescription: String { rawValue }
	}

	@Test(arguments: Ending.allCases)
	func anEndedCardKeepsThePlanThatWasNewestWhenItEnded(_ ending: Ending) async throws {
		let coach = await turns.coach()
		let first = try await turns.prepareAndArm(PlanTurns.threshold, on: coach)
		#expect(await coach.decide(.save(first), in: .main) == .saved)
		let ended = try await turns.prepareAndArm(PlanTurns.baseBuild, on: coach)
		var next = coach
		var newestBeforeLater = "Threshold Block"
		var onTheWay: [(state: PlanCardState, replaces: String?)] = []
		switch ending {
		case .canceled:
			#expect(await coach.decide(.cancel(ended), in: .main) == .canceled)
			next = try await savedElsewhereAfterTheEnd()
			newestBeforeLater = "Peak Week"
		case .expired:
			try await turns.clock.waitUntilHeld(.seconds(600))
			turns.clock.advance(by: .seconds(601))
			#expect(
				try await turns.waitForCards(on: coach) {
					$0.map(\.state) == [.saved, .expired]
				} != nil)
			next = try await savedElsewhereAfterTheEnd()
			newestBeforeLater = "Peak Week"
		case .replacedByACardThatWasReplacedLater:
			_ = try await turns.prepareAndArm(Self.taper, on: coach)
			next = try await savedElsewhereAfterTheEnd()
			newestBeforeLater = "Peak Week"
			onTheWay = [(.expired, "Peak Week")]
		case .replacedByACardThatWasSavedAfterItExpired:
			let expiresAt = try #require(try await turns.prepared(in: turns.store).last).expiresAt
			turns.clock.advance(by: .seconds(60))
			let replacing = try await turns.prepareAndArm(Self.taper, on: coach)
			turns.clock.advance(by: .seconds(1))
			let peakWeek = Self.decidedElsewhere(at: turns.clock.now)
			try await saveElsewhere(Self.peakWeek, decided: peakWeek)
			turns.clock.advance(by: .seconds(559))
			#expect(await coach.decide(.save(replacing), in: .main) == .saved)
			let steps = try await turns.steps(in: turns.store)
			let prepared = try #require(
				steps.last { record in
					if case .prepared = record.body.step { return true }
					return false
				})
			let claimed = try #require(
				steps.last { record in
					if case .claimed = record.body.step { return true }
					return false
				})
			#expect(prepared.hlc < peakWeek)
			#expect(peakWeek.wallTime < expiresAt)
			#expect(expiresAt < claimed.hlc.wallTime)
			#expect(claimed.hlc.wallTime < prepared.hlc.wallTime.addingTimeInterval(600))
			next = await turns.coach()
			newestBeforeLater = "Taper"
			onTheWay = [(.saved, "Peak Week")]
		case .replaced, .replacedThenExpired:
			break
		}

		let later = try await turns.prepareAndArm(Self.raceWeek, on: next)
		#expect(await next.decide(.save(later), in: .main) == .saved)
		let reader: Coach
		if ending == .replacedThenExpired {
			turns.clock.advance(by: .seconds(601))
			reader = await turns.coach()
		} else {
			reader = next
		}

		let cards = try await turns.cards(on: reader)
		let endedState: PlanCardState = ending == .canceled ? .canceled : .expired
		#expect(
			cards.map(\.state)
				== [.saved, endedState] + onTheWay.map(\.state) + [.saved])
		#expect(
			cards.map(\.summary.replaces)
				== [nil, "Threshold Block"] + onTheWay.map(\.replaces) + [newestBeforeLater])
	}

	enum LateRecord: String, CaseIterable, Sendable, CustomTestStringConvertible {
		case decidedAfterTheSaveHere
		case decidedBeforeTheSaveHere

		var testDescription: String { rawValue }

		var replaces: [String?] {
			switch self {
			case .decidedAfterTheSaveHere: [nil, "Peak Week"]
			case .decidedBeforeTheSaveHere: ["Peak Week", "Threshold Block"]
			}
		}
	}

	@Test(arguments: LateRecord.allCases)
	func aCardComparesWhenAPlanWasDecidedNotWhenItsRecordArrived(_ late: LateRecord) async throws {
		let coach = await turns.coach()
		let first = try await turns.prepareAndArm(PlanTurns.threshold, on: coach)
		turns.clock.advance(by: .seconds(1))
		let decidedBeforeTheSave = Self.decidedElsewhere(at: turns.clock.now)
		turns.clock.advance(by: .seconds(1))
		#expect(await coach.decide(.save(first), in: .main) == .saved)
		let ended = try await turns.prepareAndArm(PlanTurns.baseBuild, on: coach)
		turns.clock.advance(by: .seconds(1))
		let decided =
			late == .decidedBeforeTheSaveHere
			? decidedBeforeTheSave : Self.decidedElsewhere(at: turns.clock.now)
		turns.clock.advance(by: .seconds(1))
		#expect(await coach.decide(.cancel(ended), in: .main) == .canceled)
		turns.clock.advance(by: .seconds(1))
		let cancel = try #require(try await turns.steps(in: turns.store).last)
		#expect(cancel.body.step == .canceled)
		#expect(decided < cancel.hlc)
		#expect(cancel.hlc < Self.decidedElsewhere(at: turns.clock.now))
		try await saveElsewhere(Self.peakWeek, decided: decided, writtenAt: turns.clock.now)

		let cards = try await turns.cards(on: await turns.coach())
		#expect(cards.map(\.state) == [.saved, .canceled])
		#expect(cards.map(\.summary.replaces) == late.replaces)
	}

	@Test func aWaitingCardNamesThePlanSavedOnADeviceWhoseClockRunsAhead() async throws {
		let coach = await turns.coach()
		let first = try await turns.prepareAndArm(PlanTurns.threshold, on: coach)
		#expect(await coach.decide(.save(first), in: .main) == .saved)
		_ = try await turns.prepareAndArm(PlanTurns.baseBuild, on: coach)
		let expiresAt = try #require(try await turns.prepared(in: turns.store).last).expiresAt
		try await saveElsewhere(
			Self.peakWeek, decided: Self.decidedElsewhere(at: expiresAt.addingTimeInterval(60)))

		let cards = try await turns.cards(on: await turns.coach())
		#expect(cards.map(\.state) == [.saved, .waiting(.unarmed)])
		#expect(cards.map(\.summary.replaces) == [nil, "Peak Week"])
	}

	enum ExpiryEdge: String, CaseIterable, Sendable, CustomTestStringConvertible {
		case decidedJustBefore
		case decidedAtTheInstant
		case decidedAtTheInstantAndReplacedAtIt
		case decidedEarlierInTheMillisecondItExpires

		var testDescription: String { rawValue }

		var preparedPastAMillisecond: Duration {
			self == .decidedEarlierInTheMillisecondItExpires ? .microseconds(500) : .zero
		}
		var decidedAfterExpiryMs: Int64 { self == .decidedJustBefore ? -1 : 0 }
		var replaces: String {
			switch self {
			case .decidedJustBefore, .decidedEarlierInTheMillisecondItExpires: "Peak Week"
			case .decidedAtTheInstant, .decidedAtTheInstantAndReplacedAtIt: "Threshold Block"
			}
		}
	}

	@Test(arguments: ExpiryEdge.allCases)
	func anExpiredCardsLineEndsAtTheInstantItReadsExpired(_ edge: ExpiryEdge) async throws {
		let coach = await turns.coach()
		let first = try await turns.prepareAndArm(PlanTurns.threshold, on: coach)
		#expect(await coach.decide(.save(first), in: .main) == .saved)
		turns.clock.advance(by: edge.preparedPastAMillisecond)
		_ = try await turns.prepareAndArm(PlanTurns.baseBuild, on: coach)
		let expiresAt = try #require(try await turns.prepared(in: turns.store).last).expiresAt
		try await turns.clock.waitUntilHeld(.seconds(600))
		turns.clock.advance(by: .seconds(600))
		#expect(turns.clock.now == expiresAt)

		let atExpiry = Self.decidedElsewhere(at: expiresAt)
		let pastTheMillisecond = expiresAt.timeIntervalSince(atExpiry.wallTime)
		#expect(pastTheMillisecond >= 0 && pastTheMillisecond < 0.001)
		#expect((pastTheMillisecond > 0) == (edge.preparedPastAMillisecond > .zero))
		let decided = HybridLogicalClock(
			wallMs: atExpiry.wallMs + edge.decidedAfterExpiryMs, logical: 0,
			deviceId: atExpiry.deviceId
		)
		try await saveElsewhere(Self.peakWeek, decided: decided)
		let reader = await turns.coach()
		if edge == .decidedAtTheInstantAndReplacedAtIt {
			_ = try await turns.prepareAndArm(Self.raceWeek, on: reader)
			let replacing = try #require(
				try await turns.steps(in: turns.store).last { record in
					if case .prepared = record.body.step { return true }
					return false
				})
			#expect(replacing.hlc.wallTime == expiresAt)
			#expect(decided < replacing.hlc)
		}

		let cards = try await turns.cards(on: reader)
		#expect(cards.prefix(2).map(\.state) == [.saved, .expired])
		#expect(cards.prefix(2).map(\.summary.replaces) == [nil, edge.replaces])
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

		try await saveElsewhere(
			PlanTurns.threshold,
			decided: Self.decidedElsewhere(at: prepared.expiresAt.addingTimeInterval(1)))
		clock.advance(by: .milliseconds(1500))
		let reader = await turns.coach()
		let next = try await turns.prepareAndArm(Self.raceWeek, on: reader)
		let replacing = try #require(try await turns.steps(in: turns.store).last)
		#expect(replacing.hlc.wallTime < step.hlc.wallTime.addingTimeInterval(600))

		let later = try await turns.cards(on: reader)
		#expect(later.map(\.state) == [.expired, .waiting(.armed(next))])
		#expect(later.map(\.summary.replaces) == [nil, "Threshold Block"])
	}

	@Test func aCarriedWaitingCardNamesAPlanSavedAfterTheReset() async throws {
		let coach = await turns.coach()
		_ = try await turns.prepareAndArm(PlanTurns.baseBuild, on: coach)
		_ = await coach.resetAndSettle(in: .main)
		#expect(try await replaces(on: coach) == [nil])

		turns.clock.advance(by: .seconds(60))
		try await saveElsewhere(
			PlanTurns.threshold, decided: Self.decidedElsewhere(at: turns.clock.now))
		let reopened = await turns.coach()

		let carried = try await turns.cards(on: reopened)
		#expect(carried.map(\.placement) == [.preparedEarlier])
		#expect(carried.map(\.state) == [.waiting(.unarmed)])
		#expect(carried.map(\.summary.replaces) == ["Threshold Block"])
	}

	private func replaces(on coach: Coach) async throws -> [String?] {
		try await turns.cards(on: coach).map(\.summary.replaces)
	}

	private func savedElsewhereAfterTheEnd() async throws -> Coach {
		turns.clock.advance(by: .seconds(1))
		try await saveElsewhere(Self.peakWeek, decided: Self.decidedElsewhere(at: turns.clock.now))
		turns.clock.advance(by: .seconds(1))
		return await turns.coach()
	}

	private static func decidedElsewhere(at instant: Date) -> HybridLogicalClock {
		HybridLogicalClock.tick(now: instant, deviceId: DeviceID(rawValue: "plan-pad"), last: nil)
	}

	private func saveElsewhere(
		_ plan: JSONValue, decided: HybridLogicalClock, writtenAt: Date? = nil
	) async throws {
		let written = writtenAt.map { Self.decidedElsewhere(at: $0) } ?? decided
		try await turns.store.append(
			[
				storedRecord(
					device: decided.deviceId, wall: written.wallMs, ulid: fixedUlid(3),
					account: testConnection.account,
					body: try SavedPlanRows.body(plan, decided: decided))
			], locality: .synced)
	}
}
