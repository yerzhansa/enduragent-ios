import EnduragentCoach
import Foundation

public enum OpenRouterRejectionFixture {
	public static func rejectTwoRequests(coach: Coach, transport: FakeModelTransport) async throws {
		let gate = FakeModelGate(requiredArrivals: 2)
		let previous = transport.respond
		transport.respond = { request in
			guard request.credential == "fixture-openrouter-key" else { return previous(request) }
			return ScriptedReply([.fail(.http(status: 401))], gate: gate)
		}
		let deadline = ContinuousClock.now + TestWaitLimit.hangGuard.duration
		let peer: ChatID = "fixture-openrouter-rejection"
		_ = try await coach.send(Draft(id: DraftID(), text: "Connection recovery"), to: .main)
		_ = try await coach.send(
			Draft(id: DraftID(), text: "Concurrent connection recovery"), to: peer)
		while await gate.arrivals < 2, ContinuousClock.now < deadline {
			try await Task.sleep(for: .milliseconds(20))
		}
		guard await gate.arrivals == 2 else {
			await gate.release()
			throw URLError(.timedOut)
		}
	}
}
