import EnduragentCoachFixtures
import Foundation
import Synchronization

@testable import EnduragentCoach

struct SentRequest: Sendable, Equatable, CustomStringConvertible {
	let method: String
	let path: String
	let query: String?
	let body: String?

	var description: String {
		"\(method) \(path)\(query.map { "?\($0)" } ?? "")\(body.map { " \($0)" } ?? "")"
	}

	var json: JSONValue? {
		get throws { try body.map { try JSONValue.parse($0) } }
	}
}

enum StubAnswer: Sendable, CustomStringConvertible {
	case status(Int, String)
	case failure(URLError.Code)

	var description: String {
		switch self {
		case .status(let status, let body): "\(status) \(body.prefix(40))"
		case .failure(let code): "URLError \(code.rawValue)"
		}
	}
}

enum CalendarWriterLine {
	private static let lines = Mutex<[String: (answer: StubAnswer, sent: [SentRequest])]>([:])

	static func answering<T: Sendable>(
		_ answer: StubAnswer, _ perform: (IntervalsRESTClient) async -> T
	) async -> (result: T, sent: [SentRequest]) {
		let key = UUID().uuidString
		let line = "Basic " + Data("API_KEY:\(key)".utf8).base64EncodedString()
		lines.withLock { $0[line] = (answer, []) }
		let configuration = URLSessionConfiguration.ephemeral
		configuration.protocolClasses = [CalendarWriterURLStub.self]
		let result = await perform(
			IntervalsRESTClient(
				credential: .apiKey(key), session: URLSession(configuration: configuration)))
		let sent = lines.withLock { $0.removeValue(forKey: line)?.sent ?? [] }
		return (result, sent)
	}

	fileprivate static func take(_ request: SentRequest, on line: String) -> StubAnswer? {
		lines.withLock { lines in
			lines[line]?.sent.append(request)
			return lines[line]?.answer
		}
	}
}

final class CalendarWriterURLStub: URLProtocol, @unchecked Sendable {
	override class func canInit(with request: URLRequest) -> Bool { true }
	override class func canonicalRequest(for request: URLRequest) -> URLRequest { request }

	override func startLoading() {
		guard let url = request.url,
			let line = request.value(forHTTPHeaderField: "Authorization")
		else {
			client?.urlProtocol(self, didFailWithError: URLError(.badURL))
			return
		}
		let body = httpBody(from: request).flatMap { $0.isEmpty ? nil : $0 }
		let sent = SentRequest(
			method: request.httpMethod ?? "GET", path: url.path,
			query: URLComponents(url: url, resolvingAgainstBaseURL: false)?.percentEncodedQuery,
			body: body.map { String(decoding: $0, as: UTF8.self) })
		switch CalendarWriterLine.take(sent, on: line) {
		case .status(let status, let text):
			guard
				let response = HTTPURLResponse(
					url: url, statusCode: status, httpVersion: "HTTP/1.1",
					headerFields: ["Content-Type": "application/json"])
			else {
				client?.urlProtocol(self, didFailWithError: URLError(.badServerResponse))
				return
			}
			client?.urlProtocol(self, didReceive: response, cacheStoragePolicy: .notAllowed)
			client?.urlProtocol(self, didLoad: Data(text.utf8))
			client?.urlProtocolDidFinishLoading(self)
		case .failure(let code):
			client?.urlProtocol(self, didFailWithError: URLError(code))
		case nil:
			client?.urlProtocol(self, didFailWithError: URLError(.notConnectedToInternet))
		}
	}

	override func stopLoading() {}
}
