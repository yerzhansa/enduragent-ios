import EnduragentCoachFixtures
import Foundation
import Testing

@testable import EnduragentCoach

final class CensusGate: Sendable {
	private let gate: Gate
	let census: SupportCensus

	init(facts: StatusFacts, records: RecordCensus) {
		let gate = Gate()
		self.gate = gate
		census = SupportCensus(
			status: {
				await gate.wait()
				return facts
			},
			records: { records })
	}

	func waitUntilHeld() async throws {
		let held: Void? = try await beforeDeadline(within: .hangGuard) {
			await self.gate.waitUntilParked()
		}
		try #require(held != nil, "The census was never read")
	}

	func release() {
		gate.release()
	}
}
