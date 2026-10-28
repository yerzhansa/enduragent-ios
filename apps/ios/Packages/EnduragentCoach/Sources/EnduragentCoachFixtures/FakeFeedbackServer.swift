import EnduragentCoach
import Foundation
import Synchronization

public final class FakeFeedbackServer: Sendable {
	private struct State {
		var script: [FakeFeedbackAnswer]
		var requests: [FakeFeedbackRequest] = []
		var stored: [String: String] = [:]
		var held = false
		var waiting: [@Sendable () -> Void] = []
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
		for reply in waiting {
			reply()
		}
	}

	fileprivate func answer(
		_ request: FakeFeedbackRequest, reply: @escaping @Sendable (FakeFeedbackAnswer) -> Void
	) {
		let note = Result { try request.note() }
		let ready = state.withLock { state -> FakeFeedbackAnswer? in
			state.requests.append(request)
			guard state.held else { return Self.next(for: note, in: &state) }
			state.waiting.append { reply(self.state.withLock { Self.next(for: note, in: &$0) }) }
			return nil
		}
		if let ready { reply(ready) }
	}

	private static func next(
		for note: Result<FakeFeedbackRequest.Note, any Error>, in state: inout State
	) -> FakeFeedbackAnswer {
		guard case .success(let note) = note else { return .status(400) }
		let answer = state.script.isEmpty ? .status(204) : state.script.removeFirst()
		if answer.stores {
			state.stored[note.id] = state.stored[note.id] ?? note.text
		}
		return answer
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

	static func server(
		running task: URLSessionTask, found: @escaping @Sendable (FakeFeedbackServer?) -> Void
	) {
		let live = routes.withLock { routes in
			routes.compactMap { route in route.session.map { ($0, route.server) } }
		}
		search(live[...], for: task, found: found)
	}

	private static func search(
		_ live: ArraySlice<(URLSession, FakeFeedbackServer)>, for task: URLSessionTask,
		found: @escaping @Sendable (FakeFeedbackServer?) -> Void
	) {
		guard let (session, server) = live.first else {
			found(nil)
			return
		}
		session.getAllTasks { tasks in
			guard tasks.contains(where: { $0 === task }) else {
				search(live.dropFirst(), for: task, found: found)
				return
			}
			found(server)
		}
	}
}

final class FakeFeedbackProtocol: URLProtocol, @unchecked Sendable {
	private let stopped = Mutex(false)

	override class func canInit(with request: URLRequest) -> Bool { true }

	override class func canonicalRequest(for request: URLRequest) -> URLRequest { request }

	override func startLoading() {
		let seen = FakeFeedbackRequest(
			url: request.url, method: request.httpMethod,
			headers: request.allHTTPHeaderFields ?? [:], body: httpBody(from: request))
		guard let task else {
			client?.urlProtocol(self, didFailWithError: URLError(.cannotFindHost))
			return
		}
		FakeFeedbackRoutes.server(running: task) { server in
			guard let server else {
				self.client?.urlProtocol(self, didFailWithError: URLError(.cannotFindHost))
				return
			}
			server.answer(seen) { answer in self.reply(answer, to: seen.url) }
		}
	}

	override func stopLoading() {
		stopped.withLock { $0 = true }
	}

	private func reply(_ answer: FakeFeedbackAnswer, to url: URL?) {
		guard !stopped.withLock({ $0 }) else { return }
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
