import Foundation

public actor FakeModelGate {
	public private(set) var arrivals = 0
	private let requiredArrivals: Int?
	private var released = false
	private var waiters: [UUID: AsyncStream<Void>.Continuation] = [:]

	public init(requiredArrivals: Int? = nil) {
		self.requiredArrivals = requiredArrivals
	}

	package func enter() async throws {
		arrivals += 1
		if let requiredArrivals, arrivals >= requiredArrivals { release() }
		guard !released else { return }
		let id = UUID()
		let (stream, continuation) = AsyncStream<Void>.makeStream()
		waiters[id] = continuation
		defer { waiters.removeValue(forKey: id) }
		guard await stream.first(where: { _ in true }) != nil else { throw CancellationError() }
	}

	public func release() {
		released = true
		for continuation in waiters.values {
			continuation.yield()
			continuation.finish()
		}
		waiters.removeAll()
	}
}
