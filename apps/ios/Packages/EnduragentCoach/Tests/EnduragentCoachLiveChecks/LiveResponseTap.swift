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

	var answered: Bool { (200..<300).contains(status) }

	var request: String { "\(method) \(path)\(query.map { "?\($0)" } ?? "")" }

	var excerpt: String {
		let text =
			json.map { LiveRedaction.blanked($0).canonicalDigestInput() }
			?? String(decoding: body, as: UTF8.self)
		return text.count > 300 ? String(text.prefix(300)) + "…" : text
	}

	func redactedBody() throws -> Data {
		guard let json else { return body }
		let blanked = LiveRedaction.blanked(json)
		return blanked == json ? body : try prettyJSON(blanked)
	}
}

enum LiveRedaction {
	static let markers = ["token", "secret", "password", "apikey"]

	static func isCredential(_ field: String, holding value: JSONValue) -> Bool {
		let name = field.lowercased().replacingOccurrences(of: "_", with: "")
		switch value {
		case .null, .bool: return false
		case .number, .string, .array, .object: return markers.contains { name.contains($0) }
		}
	}

	static func blanked(_ value: JSONValue) -> JSONValue {
		switch value {
		case .object(let fields):
			.object(
				fields.reduce(into: [:]) { result, field in
					result[field.key] =
						isCredential(field.key, holding: field.value)
						? .string("") : blanked(field.value)
				})
		case .array(let entries): .array(entries.map(blanked))
		case .null, .bool, .number, .string: value
		}
	}
}

final class LiveResponseTap: URLProtocol, @unchecked Sendable {
	private static let taken = Mutex<[TappedResponse]>([])
	private static let nextBody = Mutex<(@Sendable (Data) -> Data)?>(nil)
	private static let dropsNextAnswer = Mutex(false)
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

	static func rewriteNextBody(_ rewrite: @escaping @Sendable (Data) -> Data) {
		nextBody.withLock { $0 = rewrite }
	}

	static func dropNextAnswer() {
		dropsNextAnswer.withLock { $0 = true }
	}

	static func record(_ response: TappedResponse) {
		taken.withLock { $0.append(response) }
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
		let request = Self.outgoing(self.request)
		let drops = Self.dropsNextAnswer.withLock { drops in
			defer { drops = false }
			return drops
		}
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
			guard !drops else {
				client?.urlProtocol(self, didFailWithError: URLError(.networkConnectionLost))
				return
			}
			client?.urlProtocol(self, didReceive: response, cacheStoragePolicy: .notAllowed)
			client?.urlProtocol(self, didLoad: data)
			client?.urlProtocolDidFinishLoading(self)
		}
		forwarding.withLock { $0 = task }
		task.resume()
	}

	private static func outgoing(_ request: URLRequest) -> URLRequest {
		let rewrite = nextBody.withLock { slot in
			defer { slot = nil }
			return slot
		}
		guard let rewrite else { return request }
		var rewritten = request
		rewritten.httpBodyStream = nil
		rewritten.httpBody = rewrite(body(of: request))
		return rewritten
	}

	private static func body(of request: URLRequest) -> Data {
		if let body = request.httpBody { return body }
		guard let stream = request.httpBodyStream else { return Data() }
		stream.open()
		defer { stream.close() }
		var body = Data()
		var buffer = [UInt8](repeating: 0, count: 16_384)
		while case let count = stream.read(&buffer, maxLength: buffer.count), count > 0 {
			body.append(buffer, count: count)
		}
		return body
	}

	override func stopLoading() {
		forwarding.withLock { $0?.cancel() }
	}
}
