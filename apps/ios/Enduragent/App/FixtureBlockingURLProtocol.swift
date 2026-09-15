import Foundation
import Synchronization

final class FixtureBlockingURLProtocol: URLProtocol, @unchecked Sendable {
	private struct State: Sendable {
		var count = 0
		var isRegistered = false
	}

	private static let state = Mutex(State())

	static var requestCount: Int {
		state.withLock { $0.count }
	}

	static func register() {
		let shouldRegister = state.withLock { current -> Bool in
			if current.isRegistered { return false }
			current.isRegistered = true
			return true
		}
		if shouldRegister {
			URLProtocol.registerClass(Self.self)
		}
	}

	override class func canInit(with request: URLRequest) -> Bool {
		true
	}

	override class func canonicalRequest(for request: URLRequest) -> URLRequest {
		request
	}

	override func startLoading() {
		Self.state.withLock { $0.count += 1 }
		client?.urlProtocol(self, didFailWithError: URLError(.notConnectedToInternet))
	}

	override func stopLoading() {}
}
