import EnduragentCoach

struct FakeIntervalsDisplayReads {
	var profile: (result: Result<AthleteProfile, any Error>, once: Bool)?
	var wellness: (result: Result<[WellnessDay], any Error>, once: Bool)?
	var profileGate: FakeIntervalsReadGate?
	var wellnessGate: FakeIntervalsReadGate?
	var profileCount = 0
	var wellnessCount = 0
}

public actor FakeIntervalsReadGate {
	private let arrivals: AsyncStream<Void>
	private let arrived: AsyncStream<Void>.Continuation
	private var blocked: CheckedContinuation<Void, Never>?
	private var released = false

	init() {
		(arrivals, arrived) = AsyncStream.makeStream(bufferingPolicy: .bufferingNewest(1))
	}

	public func waitUntilEntered() async {
		await arrivals.first { _ in true }
	}

	func enter() async {
		arrived.yield()
		guard !released else { return }
		await withCheckedContinuation { blocked = $0 }
	}

	public func release() {
		released = true
		blocked?.resume()
		blocked = nil
	}
}
