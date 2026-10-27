import Foundation
import Testing

@testable import EnduragentCoach

@Suite
struct SerializerRefusalTests {
	@Test(arguments: [
		(
			PowerTarget(kind: .watts, value: 2001, low: nil, high: nil),
			"steps[0].power.value: 2001w exceeds sanity bound 1500w"
		),
		(
			PowerTarget(kind: .watts, value: 1500.5, low: nil, high: nil),
			"steps[0].power.value: 1500.5w exceeds sanity bound 1500w"
		),
		(
			PowerTarget(kind: .watts, value: 1e16, low: nil, high: nil),
			"steps[0].power.value: 10000000000000000w exceeds sanity bound 1500w"
		),
		(
			PowerTarget(kind: .percentFtp, value: 250, low: nil, high: nil),
			"steps[0].power.value: 250% exceeds sanity bound 200%"
		),
		(
			PowerTarget(kind: .watts, value: nil, low: 300, high: 250),
			"steps[0]: power.low (300) > power.high (250)"
		),
		(
			PowerTarget(kind: .watts, value: nil, low: 250.5, high: 200),
			"steps[0]: power.low (250.5) > power.high (200)"
		),
		(
			PowerTarget(kind: .zone, value: 2.5, low: nil, high: nil),
			"steps[0].power.value: zone must be an integer 1-7, got 2.5"
		),
		(
			PowerTarget(kind: .zone, value: 8, low: nil, high: nil),
			"steps[0].power.value: zone must be an integer 1-7, got 8"
		),
		(
			PowerTarget(kind: .zone, value: 1e-7, low: nil, high: nil),
			"steps[0].power.value: zone must be an integer 1-7, got 1e-7"
		),
	])
	func refusalMessagePrintsNumbersAsJavaScriptDoes(power: PowerTarget, message: String) {
		let refusal = #expect(throws: InvalidWorkout.self) {
			_ = try IntervalsSerializer.serialize(
				IntervalsWorkoutInput(
					name: "Refused",
					steps: [
						.simple(
							SimpleStep(
								type: .steady, duration: DurationInput(value: 5, unit: .minutes),
								power: power, cadence: nil, label: nil))
					])
			)
		}
		#expect(refusal?.message == message)
	}
}
