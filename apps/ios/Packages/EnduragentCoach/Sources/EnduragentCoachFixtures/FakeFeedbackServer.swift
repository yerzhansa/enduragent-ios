import EnduragentCoach
import Foundation
import Synchronization

public final class FakeFeedbackServer: Sendable {
	private struct State {
		var script: [FakeFeedbackAnswer]
		var requests: [FakeFeedbackRequest] = []
		var stored: [String: String] = [:]
		var held = false
		var waiting: [CheckedContinuation<Void, Never>] = []
	}

	package static let redirectLocation: URL = {
		guard let url = URL(string: "https://elsewhere.example/v1/feedback") else {
			fatalError("The fake redirect location is invalid")
		}
		return url
	}()

	private let state: Mutex<State>

	public init(script: [FakeFeedbackAnswer] = []) {
		state = Mutex(State(script: script))
	}

	package var client: FeedbackClient {
		let client = FeedbackClient(protocolClasses: [FakeFeedbackProtocol.self])
		FakeFeedbackRoutes.add(self, answering: client.session)
		return client
	}

	package var requests: [FakeFeedbackRequest] {
		state.withLock { $0.requests }
	}

	public var requestCount: Int {
		state.withLock { $0.requests.count }
	}

	public var storedCount: Int {
		state.withLock { $0.stored.count }
	}

	public func hold() {
		state.withLock { $0.held = true }
	}

	public func release() {
		let waiting = state.withLock { state in
			state.held = false
			defer { state.waiting = [] }
			return state.waiting
		}
		for continuation in waiting {
			continuation.resume()
		}
	}

	fileprivate func answer(_ request: FakeFeedbackRequest) async -> FakeFeedbackAnswer {
		state.withLock { $0.requests.append(request) }
		await withCheckedContinuation { continuation in
			let held = state.withLock { state in
				if state.held { state.waiting.append(continuation) }
				return state.held
			}
			if !held { continuation.resume() }
		}
		let note: FakeFeedbackRequest.Note
		do {
			note = try request.note()
		} catch {
			return .status(400)
		}
		return state.withLock { state in
			let answer = state.script.isEmpty ? .status(204) : state.script.removeFirst()
			if answer.stores {
				state.stored[note.id] = state.stored[note.id] ?? note.text
			}
			return answer
		}
	}
}

public enum FakeFeedbackAnswer: Sendable, Equatable {
	case status(Int)
	case offline
	case timeout
	case lostAnswer
	case redirect(Int)

	public init?(word: String) {
		switch word {
		case "offline": self = .offline
		case "timeout": self = .timeout
		case "lost": self = .lostAnswer
		default:
			guard let status = Int(word), (100...599).contains(status) else { return nil }
			self = (300...399).contains(status) ? .redirect(status) : .status(status)
		}
	}

	fileprivate var stores: Bool {
		switch self {
		case .status(204), .lostAnswer: true
		case .status, .offline, .timeout, .redirect: false
		}
	}
}

package struct FakeFeedbackRequest: Sendable, Equatable {
	package struct Note: Sendable, Equatable, Decodable {
		package let channel: String
		package let id: String
		package let text: String
	}

	package let url: URL?
	package let method: String?
	package let headers: [String: String]
	package let body: Data?

	package func note() throws -> Note {
		try JSONDecoder().decode(Note.self, from: body ?? Data())
	}
}

private enum FakeFeedbackRoutes {
	private struct Route: Sendable {
		weak var session: URLSession?
		let server: FakeFeedbackServer
	}

	private static let routes = Mutex<[Route]>([])

	static func add(_ server: FakeFeedbackServer, answering session: URLSession) {
		routes.withLock { routes in
			routes.removeAll { $0.session == nil }
			routes.append(Route(session: session, server: server))
		}
	}

	static func server(running task: URLSessionTask?) async -> FakeFeedbackServer? {
		guard let task else { return nil }
		for route in routes.withLock({ $0 }) {
			guard let session = route.session else { continue }
			if await session.allTasks.contains(where: { $0 === task }) { return route.server }
		}
		return nil
	}
}

final class FakeFeedbackProtocol: URLProtocol, @unchecked Sendable {
	private let answering = Mutex<Task<Void, Never>?>(nil)

	override class func canInit(with request: URLRequest) -> Bool { true }

	override class func canonicalRequest(for request: URLRequest) -> URLRequest { request }

	override func startLoading() {
		let seen = FakeFeedbackRequest(
			url: request.url, method: request.httpMethod,
			headers: request.allHTTPHeaderFields ?? [:], body: httpBody(from: request))
		let task = self.task
		let reply = Task {
			guard let server = await FakeFeedbackRoutes.server(running: task) else {
				client?.urlProtocol(self, didFailWithError: URLError(.cannotFindHost))
				return
			}
			let answer = await server.answer(seen)
			guard !Task.isCancelled else { return }
			self.reply(answer, to: seen.url)
		}
		answering.withLock { $0 = reply }
	}

	override func stopLoading() {
		answering.withLock { $0?.cancel() }
	}

	private func reply(_ answer: FakeFeedbackAnswer, to url: URL?) {
		switch answer {
		case .status(let status):
			respond(status, headers: [:], to: url)
		case .offline:
			client?.urlProtocol(self, didFailWithError: URLError(.notConnectedToInternet))
		case .timeout:
			client?.urlProtocol(self, didFailWithError: URLError(.timedOut))
		case .lostAnswer:
			client?.urlProtocol(self, didFailWithError: URLError(.networkConnectionLost))
		case .redirect(let status):
			redirect(status, to: url)
		}
	}

	private func redirect(_ status: Int, to url: URL?) {
		guard let url,
			let response = HTTPURLResponse(
				url: url, statusCode: status, httpVersion: "HTTP/1.1",
				headerFields: ["Location": FakeFeedbackServer.redirectLocation.absoluteString])
		else {
			client?.urlProtocol(self, didFailWithError: URLError(.badURL))
			return
		}
		client?.urlProtocol(
			self, wasRedirectedTo: URLRequest(url: FakeFeedbackServer.redirectLocation),
			redirectResponse: response)
		client?.urlProtocol(self, didReceive: response, cacheStoragePolicy: .notAllowed)
		client?.urlProtocolDidFinishLoading(self)
	}

	private func respond(_ status: Int, headers: [String: String], to url: URL?) {
		guard let url,
			let response = HTTPURLResponse(
				url: url, statusCode: status, httpVersion: "HTTP/1.1", headerFields: headers)
		else {
			client?.urlProtocol(self, didFailWithError: URLError(.badURL))
			return
		}
		client?.urlProtocol(self, didReceive: response, cacheStoragePolicy: .notAllowed)
		client?.urlProtocolDidFinishLoading(self)
	}
}
