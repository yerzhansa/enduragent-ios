import EnduragentCoachFixtures
import Foundation

@testable import EnduragentCoach

struct GatedProfileIntervals: ForwardingIntervals {
	let base: FakeIntervalsClient
	let gate: Gate

	func profile() async throws -> AthleteProfile {
		await gate.wait()
		return try await base.profile()
	}
}
