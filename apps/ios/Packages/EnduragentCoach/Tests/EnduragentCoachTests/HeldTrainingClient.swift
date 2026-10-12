import EnduragentCoachFixtures
import Foundation

@testable import EnduragentCoach

struct GatedProfileIntervals: ForwardingIntervals {
	let base: FakeIntervalsClient
	let gate: Gate

	func fetchAthlete() async throws -> AthleteProfile {
		await gate.wait()
		return try await base.fetchAthlete()
	}
}
