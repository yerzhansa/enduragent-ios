import Foundation
import Synchronization

@testable import EnduragentCoach

struct TappedResponse: Sendable {
	let method: String
	let path: String
	let query: String?
	let status: Int
	let body: Data

	var parsed: Result<JSONValue, any Error> {
		Result { try JSONValue.parse(String(decoding: body, as: UTF8.self)) }
	}

	var json: JSONValue? {
		guard case .success(let json) = parsed else { return nil }
		return json
	}
}

final class LiveResponseTap: URLProtocol, @unchecked Sendable {
	private static let taken = Mutex<[TappedResponse]>([])
	private static let upstream = ephemeralSession(
		requestTimeout: IntervalsPolicy.requestTimeout,
		resourceTimeout: IntervalsPolicy.requestTimeout)

	private let forwarding = Mutex<URLSessionDataTask?>(nil)

	static func session() -> URLSession {
		ephemeralSession(
			requestTimeout: IntervalsPolicy.requestTimeout,
			resourceTimeout: IntervalsPolicy.requestTimeout, protocolClasses: [LiveResponseTap.self]
		)
	}

	static func drain() -> [TappedResponse] {
		taken.withLock { responses in
			defer { responses.removeAll() }
			return responses
		}
	}

	override class func canInit(with request: URLRequest) -> Bool { true }
	override class func canonicalRequest(for request: URLRequest) -> URLRequest { request }

	override func startLoading() {
		let request = self.request
		let task = Self.upstream.dataTask(with: request) { [self] data, response, error in
			guard let data, let response else {
				client?.urlProtocol(self, didFailWithError: error ?? URLError(.badServerResponse))
				return
			}
			if let http = response as? HTTPURLResponse, let url = request.url {
				let parts = URLComponents(url: url, resolvingAgainstBaseURL: false)
				Self.taken.withLock {
					$0.append(
						TappedResponse(
							method: request.httpMethod ?? "GET", path: url.path,
							query: parts?.percentEncodedQuery, status: http.statusCode, body: data))
				}
			}
			client?.urlProtocol(self, didReceive: response, cacheStoragePolicy: .notAllowed)
			client?.urlProtocol(self, didLoad: data)
			client?.urlProtocolDidFinishLoading(self)
		}
		forwarding.withLock { $0 = task }
		task.resume()
	}

	override func stopLoading() {
		forwarding.withLock { $0?.cancel() }
	}
}
