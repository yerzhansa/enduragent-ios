import EnduragentCoach

public enum FakeTrainingRead: Hashable, Sendable, CaseIterable {
	case profile
	case wellness
	case activities
	case activity
	case streams
}

struct FakeReadFaults {
	private var failures: [FakeTrainingRead: (error: any Error, once: Bool)] = [:]
	private var gates: [FakeTrainingRead: FakeIntervalsReadGate] = [:]
	private var delays: [FakeTrainingRead: Duration] = [:]

	mutating func fail(_ read: FakeTrainingRead, with error: any Error, once: Bool) {
		failures[read] = (error, once)
	}

	mutating func restore(_ read: FakeTrainingRead) {
		failures[read] = nil
	}

	mutating func hold(_ read: FakeTrainingRead) -> FakeIntervalsReadGate {
		let gate = FakeIntervalsReadGate()
		gates[read] = gate
		return gate
	}

	mutating func delay(_ read: FakeTrainingRead, by duration: Duration) {
		delays[read] = duration > .zero ? duration : nil
	}

	mutating func begin(_ read: FakeTrainingRead) -> (
		failure: (any Error)?, gate: FakeIntervalsReadGate?, delay: Duration?
	) {
		let failure = failures[read]
		if failure?.once == true { failures[read] = nil }
		return (failure?.error, gates.removeValue(forKey: read), delays.removeValue(forKey: read))
	}
}

public actor FakeIntervalsReadGate {
	private let arrivals: AsyncStream<Void>
	private let arrived: AsyncStream<Void>.Continuation
	private let endings: AsyncStream<Void>
	private let ended: AsyncStream<Void>.Continuation
	private var blocked: CheckedContinuation<Void, any Error>?
	private var released = false

	init() {
		(arrivals, arrived) = AsyncStream.makeStream(bufferingPolicy: .bufferingNewest(1))
		(endings, ended) = AsyncStream.makeStream(bufferingPolicy: .bufferingNewest(1))
	}

	public func waitUntilEntered() async {
		await arrivals.first { _ in true }
	}

	public func waitUntilEnded() async {
		await endings.first { _ in true }
	}

	func enter() async throws {
		arrived.yield()
		defer { ended.yield() }
		guard !released else { return }
		try await withTaskCancellationHandler {
			try await withCheckedThrowingContinuation {
				(continuation: CheckedContinuation<Void, any Error>) in
				if Task.isCancelled {
					continuation.resume(throwing: CancellationError())
				} else {
					blocked = continuation
				}
			}
		} onCancel: {
			Task { await self.abandon() }
		}
	}

	public func release() {
		released = true
		blocked?.resume()
		blocked = nil
	}

	private func abandon() {
		blocked?.resume(throwing: CancellationError())
		blocked = nil
	}
}
