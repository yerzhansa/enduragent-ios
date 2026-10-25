import EnduragentCoachFixtures
import Foundation
import Testing

@testable import EnduragentCoach

extension SwiftDataSuites {
	@Suite(.timeLimit(.minutes(2))) struct PlanSaveCrashTests {
		@Test(arguments: PlanCrashPoint.allCases)
		func everyCrashPointConvergesAfterTheRelaunchAndAgainOnTheSecondBecameActive(
			point: PlanCrashPoint
		) async throws {
			let rig = try PlanCrashRig()
			let crash = try await rig.stop(point)
			let relaunch = try await rig.relaunch()

			let beforeRecovery = try await relaunch.reading(of: crash)
			await relaunch.coach.lifecycle(.becameActive)
			let afterFirst = try await relaunch.reading(of: crash)
			await relaunch.coach.lifecycle(.becameActive)
			let afterSecond = try await relaunch.reading(of: crash)

			let expected = point.expected
			#expect(beforeRecovery == expected.beforeRecovery)
			#expect(afterFirst == expected.afterRecovery)
			#expect(afterSecond == afterFirst)
		}

		@Test func aClaimLeftUnfinishedBesideALaterSaveLandsBehindItAfterTheRelaunch()
			async throws
		{
			let rig = try PlanCrashRig()
			let crash = try await rig.stop(.s6)
			let claim = try #require(crash.claim)
			let relaunch = try await rig.relaunch()
			#expect(try await SavedPlanRows.stored(claim.savedPlan, in: relaunch.log).isEmpty)

			await relaunch.coach.lifecycle(.becameActive)

			#expect(try await SavedPlanRows.stored(claim.savedPlan, in: relaunch.log).count == 1)
			#expect(try await SavedPlanRows.stored(in: relaunch.log).count == 3)
			#expect(try await relaunch.turns.planLoad(on: relaunch.coach) == PlanTurns.baseBuild)
			#expect(
				try await relaunch.turns.planHistory(on: relaunch.coach) == [
					"Winter Base", "Threshold Block", "Base Build",
				])
		}
	}
}

extension PlanCrashPoint {
	var expected: (beforeRecovery: PlanCrashReading, afterRecovery: PlanCrashReading) {
		switch self {
		case .s0:
			let nothing = PlanCrashReading(cards: [], offersTryAgain: true, claimRows: 0, steps: 0)
			return (nothing, nothing)
		case .s1, .s2, .c1:
			let waiting = PlanCrashReading(
				cards: [.waiting(.unarmed)], offersTryAgain: false, claimRows: 0, steps: 1)
			return (waiting, waiting)
		case .s3:
			return (
				PlanCrashReading(cards: [.saving], offersTryAgain: false, claimRows: 0, steps: 2),
				PlanCrashReading(cards: [.saved], offersTryAgain: false, claimRows: 1, steps: 3)
			)
		case .s4, .s4a:
			return (
				PlanCrashReading(cards: [.saving], offersTryAgain: false, claimRows: 1, steps: 2),
				PlanCrashReading(cards: [.saved], offersTryAgain: false, claimRows: 1, steps: 3)
			)
		case .s5:
			let saved = PlanCrashReading(
				cards: [.saved], offersTryAgain: false, claimRows: 1, steps: 3)
			return (saved, saved)
		case .s6:
			return (
				PlanCrashReading(
					cards: [.saved, .saving, .saved], offersTryAgain: false, claimRows: 0,
					steps: 8),
				PlanCrashReading(
					cards: [.saved, .saved, .saved], offersTryAgain: false, claimRows: 1, steps: 9)
			)
		case .e1:
			let expired = PlanCrashReading(
				cards: [.expired], offersTryAgain: false, claimRows: 0, steps: 1)
			return (expired, expired)
		case .c2:
			let canceled = PlanCrashReading(
				cards: [.canceled], offersTryAgain: false, claimRows: 0, steps: 2)
			return (canceled, canceled)
		}
	}
}

extension PlanTurns {
	func planHistory(on coach: Coach) async throws -> [String] {
		let history = try await tools(
			[
				.toolCall(
					name: "memory_query", arguments: #"{"from":"1998-06-13","to":"1998-06-13"}"#)
			], on: coach)
		let lines = try #require(history.first?.stringValue).split(separator: "\n")
		return try lines.filter { $0.hasPrefix("history: \(PlanHistoryLine.label) — was: ") }.map {
			line in
			let now = try #require(line.components(separatedBy: " / now: ").last)
			return try #require(
				[PlanCrashRig.earlier, PlanTurns.threshold, PlanTurns.baseBuild].lazy.compactMap {
					$0.objectFields["name"]?.stringValue
				}.first { now.contains(#""name": "\#($0)""#) })
		}
	}
}
