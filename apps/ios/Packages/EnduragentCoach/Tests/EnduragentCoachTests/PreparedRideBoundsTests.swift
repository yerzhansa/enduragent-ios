import EnduragentCoachFixtures
import Foundation
import Testing

@testable import EnduragentCoach

@Suite struct PreparedRideBoundsTests {
	let turns = ReviewTurns()

	enum PastBound: String, CaseIterable, Sendable {
		case steps41, repeats21, name121, label121, watts1501, percentFtp201, rampLowOnly,
			rampHighOnly

		static let steady = #"{"type":"steady","duration":{"value":1,"unit":"minutes"}}"#

		var preparation: String {
			let steady = Self.steady
			switch self {
			case .steps41:
				return PreparedRideBoundsTests.oneRide(steps: Array(repeating: steady, count: 41))
			case .repeats21:
				return PreparedRideBoundsTests.oneRide(steps: [
					#"{"type":"set","repeat":21,"interval":\#(steady),"recovery":\#(steady)}"#
				])
			case .name121:
				return PreparedRideBoundsTests.oneRide(
					name: String(repeating: "n", count: 121), steps: [steady])
			case .label121:
				let label = String(repeating: "l", count: 121)
				return PreparedRideBoundsTests.oneRide(steps: [
					#"{"type":"steady","duration":{"value":1,"unit":"minutes"},"label":"\#(label)"}"#
				])
			case .watts1501:
				return PreparedRideBoundsTests.oneRide(steps: [
					#"{"type":"steady","duration":{"value":1,"unit":"minutes"},"power":{"kind":"watts","value":1501}}"#
				])
			case .percentFtp201:
				return PreparedRideBoundsTests.oneRide(steps: [
					#"{"type":"interval","duration":{"value":1,"unit":"minutes"},"power":{"kind":"percent_ftp","value":201}}"#
				])
			case .rampLowOnly:
				return PreparedRideBoundsTests.oneRide(steps: [
					#"{"type":"ramp","duration":{"value":5,"unit":"minutes"},"power":{"kind":"percent_ftp","low":60}}"#
				])
			case .rampHighOnly:
				return PreparedRideBoundsTests.oneRide(steps: [
					#"{"type":"ramp","duration":{"value":5,"unit":"minutes"},"power":{"kind":"watts","high":250}}"#
				])
			}
		}
	}

	static func oneRide(name: String = "Ride", steps: [String]) -> String {
		#"{"kind":"complete","changes":[{"kind":"add-cycling","date":"1998-09-09","workout":{"name":"\#(name)","steps":[\#(steps.joined(separator: ","))]}}]}"#
	}

	@Test(arguments: PastBound.allCases)
	func eachRideBoundRefusesOnePastItsLimitAndPreparesNothing(_ bound: PastBound) async throws {
		let coach = await turns.coach()

		_ = try await turns.reply(after: [turns.prepare(bound.preparation)], on: coach)

		#expect(
			try turns.toolData().map { $0.objectFields["error"] } == [.string("invalid_workout")])
		try await expectNothingPrepared(on: coach)
	}

	@Test(arguments: [
		#"{"type":"steady","duration":{"value":1.5e17,"unit":"minutes"}}"#,
		#"{"type":"steady","duration":{"value":86401,"unit":"seconds"}}"#,
		#"{"type":"steady","duration":{"value":1441,"unit":"minutes"}}"#,
		#"{"type":"steady","duration":{"value":1e20,"unit":"seconds"}}"#,
		#"{"type":"steady","duration":{"value":1e308,"unit":"minutes"}}"#,
		#"{"type":"steady","duration":{"value":5e18,"unit":"seconds"}},{"type":"steady","duration":{"value":5e18,"unit":"seconds"}}"#,
		#"{"type":"set","repeat":20,"interval":{"type":"steady","duration":{"value":5e17,"unit":"seconds"}},"recovery":{"type":"rest","duration":{"value":30,"unit":"seconds"}}}"#,
	])
	func anOversizedRideIsRefusedAsAnInvalidWorkout(_ steps: String) async throws {
		let coach = await turns.coach()

		_ = try await turns.reply(after: [turns.prepare(Self.oneRide(steps: [steps]))], on: coach)

		#expect(
			try turns.toolData().map { $0.objectFields["error"] } == [.string("invalid_workout")])
		try await expectNothingPrepared(on: coach)
	}

	@Test(arguments: [
		#"{"value":86400,"unit":"seconds"}"#,
		#"{"value":1440,"unit":"minutes"}"#,
	])
	func aRideOfExactlyOneDayIsPrepared(_ duration: String) async throws {
		let coach = await turns.coach()
		let steps = [#"{"type":"steady","duration":\#(duration)}"#]

		_ = try await turns.reply(after: [turns.prepare(Self.oneRide(steps: steps))], on: coach)

		#expect(try turns.toolData().map { $0.objectFields["kind"] } == [.string("prepared")])
		let review = try #require(try await turns.head(of: coach).1)
		#expect(review.work.remaining.count == 1)
		#expect(turns.intervals.calls.allSatisfy { !$0.isWrite })
	}

	private func expectNothingPrepared(on coach: Coach) async throws {
		#expect(try await turns.head(of: coach).1 == nil)
		#expect(try await coach.desk.snapshot(chat: .main) == nil)
		#expect(turns.intervals.calls.allSatisfy { !$0.isWrite })
	}
}
