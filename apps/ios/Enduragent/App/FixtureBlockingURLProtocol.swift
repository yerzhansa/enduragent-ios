import Foundation

final class FixtureBlockingURLProtocol: URLProtocol, @unchecked Sendable {
	private static let lock = NSLock()
	private static var count = 0
	private static var isRegistered = false

	static var requestCount: Int {
		lock.lock()
		defer { lock.unlock() }
		return count
	}

	static func register() {
		lock.lock()
		defer { lock.unlock() }
		guard !isRegistered else { return }
		URLProtocol.registerClass(Self.self)
		isRegistered = true
	}

	override class func canInit(with request: URLRequest) -> Bool {
		true
	}

	override class func canonicalRequest(for request: URLRequest) -> URLRequest {
		request
	}

	override func startLoading() {
		Self.lock.lock()
		Self.count += 1
		Self.lock.unlock()
		client?.urlProtocol(self, didFailWithError: URLError(.notConnectedToInternet))
	}

	override func stopLoading() {}
}
