import EnduragentCoachFixtures
import Foundation
import Testing

@testable import EnduragentCoach

@Suite struct SerializerBoundsTests {
	let transport = FakeModelTransport()
	let intervals = FakeIntervalsClient(athleteName: "Ada", ftp: 250)
	let store = InMemoryRecordLog()

	enum PastBound: String, CaseIterable {
		case steps41, repeats21, name121, label121, watts1501, percentFtp201, rampLowOnly,
			rampHighOnly

		var workout: String {
			let steady = #"{"type":"steady","duration":{"value":1,"unit":"minutes"}}"#
			switch self {
			case .steps41:
				return workout(steps: Array(repeating: steady, count: 41))
			case .repeats21:
				return workout(steps: [
					#"{"type":"set","repeat":21,"interval":\#(steady),"recovery":\#(steady)}"#
				])
			case .name121:
				return workout(name: String(repeating: "n", count: 121), steps: [steady])
			case .label121:
				let label = String(repeating: "l", count: 121)
				return workout(steps: [
					#"{"type":"steady","duration":{"value":1,"unit":"minutes"},"label":"\#(label)"}"#
				])
			case .watts1501:
				return workout(steps: [
					#"{"type":"steady","duration":{"value":1,"unit":"minutes"},"power":{"kind":"watts","value":1501}}"#
				])
			case .percentFtp201:
				return workout(steps: [
					#"{"type":"interval","duration":{"value":1,"unit":"minutes"},"power":{"kind":"percent_ftp","value":201}}"#
				])
			case .rampLowOnly:
				return workout(steps: [
					#"{"type":"ramp","duration":{"value":5,"unit":"minutes"},"power":{"kind":"percent_ftp","low":60}}"#
				])
			case .rampHighOnly:
				return workout(steps: [
					#"{"type":"ramp","duration":{"value":5,"unit":"minutes"},"power":{"kind":"watts","high":250}}"#
				])
			}
		}

		private func workout(name: String = "Ride", steps: [String]) -> String {
			#"{"name":"\#(name)","steps":[\#(steps.joined(separator: ","))]}"#
		}
	}

	@Test(arguments: PastBound.allCases)
	func eachBoundRefusesOnePastItsLimitWithNoWrite(_ bound: PastBound) async throws {
		transport.respond = ScriptedReply.sequence(
			[
				.toolCall(
					name: "intervals_create_workout",
					arguments: #"{"date":"1998-06-14","workout":\#(bound.workout)}"#),
				.finish(reason: .toolCalls),
				.text("Please correct the workout."), .finish(reason: .stop),
			], otherwise: transport.respond)
		let coach = await makeCoach(transport: transport, intervals: intervals, store: store)
		let settled = try await coach.sendAndSettle("Add this ride")
		#expect(replyText(settled) == "Please correct the workout.")
		let next = try #require(transport.requests.last)
		let result = try #require(next.messages.last { $0.role == .tool })
		let json = try JSONValue.parse(result.content)
		#expect(
			(json.objectFields["data"] ?? json).objectFields["error"] == .string("invalid_workout"))
		#expect(await coach.currentSnapshot(.main)?.review == nil)
		#expect(
			try await store.fetch(RecordQuery(scope: .deviceLocal([.pendingProposal]))).records
				.isEmpty)
		#expect(intervals.calls.allSatisfy { !$0.isWrite })
	}
}
