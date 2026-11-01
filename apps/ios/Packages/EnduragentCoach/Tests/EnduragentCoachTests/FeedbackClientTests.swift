import EnduragentCoachFixtures
import Foundation
import Synchronization
import Testing

@testable import EnduragentCoach

@Suite struct FeedbackClientTests {
	struct SendCase: Sendable, CustomTestStringConvertible {
		let script: String
		let outcome: FeedbackOutcome
		let requests: Int

		var testDescription: String { script }
	}

	static let sendCases = [
		SendCase(script: "503,204", outcome: receivedOutcome, requests: 2),
		SendCase(script: "offline,offline", outcome: .notSent(.noConnection), requests: 2),
		SendCase(script: "429", outcome: .notSent(.busy), requests: 1),
		SendCase(script: "400", outcome: .notSent(.refused), requests: 1),
		SendCase(script: "502", outcome: .notConfirmed, requests: 1),
		SendCase(script: "timeout,timeout", outcome: .notConfirmed, requests: 2),
	]

	let note: FeedbackNote

	init() throws {
		note = .first(try FeedbackText(validating: "The Tuesday intervals felt too long."))
	}

	@Test func eachAttemptIsOnePostWithTheBodyAndATenSecondCap() async throws {
		let server = FakeFeedbackServer()
		let answers = await server.client.deliver(note)
		#expect(answers == [AttemptAnswer(status: 204)])
		#expect(server.requestCount == 1)
		let request = try #require(server.requests.first)
		#expect(request.url == FeedbackClient.endpoint)
		#expect(request.method == "POST")
		#expect(request.headers["Content-Type"] == "application/json")
		#expect(!request.headers.keys.contains { $0.lowercased() == "cookie" })
		let body = try #require(request.body)
		#expect(
			try JSONValue.parse(String(decoding: body, as: UTF8.self))
				== .object([
					"channel": .string("ios"), "id": .string(note.id.rawValue),
					"text": .string(note.text.trimmed),
				]))
		let configuration = server.client.session.configuration
		#expect(configuration.timeoutIntervalForRequest == 10)
		#expect(configuration.timeoutIntervalForResource == 10)
		#expect(configuration.httpCookieStorage == nil)
	}

	@Test func aRedirectIsRefusedAndRetriedWithTheSameBody() async throws {
		let server = FakeFeedbackServer(script: try script("302,302"))
		let answers = await server.client.deliver(note)
		#expect(answers == [.redirected(status: 302), .redirected(status: 302)])
		let requests = server.requests
		#expect(requests.map(\.url) == [FeedbackClient.endpoint, FeedbackClient.endpoint])
		#expect(!requests.contains { $0.url == FakeFeedbackServer.redirectLocation })
		let first = try #require(requests.first?.body)
		#expect(requests.last?.body == first)
	}

	@Test func aFollowingDelegateWouldReachTheLocation() async throws {
		let server = FakeFeedbackServer(script: try script("302"))
		var request = URLRequest(url: FeedbackClient.endpoint)
		request.httpMethod = "POST"
		request.httpBody = try FeedbackClient.body(of: note)
		_ = try await server.client.session.data(for: request, delegate: FollowRedirects())
		#expect(
			server.requests.map(\.url) == [
				FeedbackClient.endpoint, FakeFeedbackServer.redirectLocation,
			])
	}

	@Test func theFakeAnswersWhileTheCooperativePoolIsBlocked() async throws {
		let server = FakeFeedbackServer()
		let session = server.client.session
		var request = URLRequest(url: FeedbackClient.endpoint)
		request.httpMethod = "POST"
		request.httpBody = try FeedbackClient.body(of: note)
		let statuses = await withCheckedContinuation { [request] continuation in
			DispatchQueue.global().async {
				let statuses = statusesWithThePoolBlocked(request, to: server, on: session, for: 5)
				continuation.resume(returning: statuses)
			}
		}
		#expect(statuses == [204, 204])
		#expect(server.requestCount == 2)
	}

	@Test(arguments: sendCases)
	func sendEndsWithItsOutcome(_ sendCase: SendCase) async throws {
		let server = FakeFeedbackServer(script: try script(sendCase.script))
		let support = Support(
			log: DiagnosticsLog(clock: HeldClock()),
			service: .inMemory(app: .fixture, server: server),
			census: SupportCensus(
				status: { SupportDiagnosticsTests.facts },
				records: {
					SupportDiagnosticsTests.records
				}))
		#expect(try await support.send(note.text.trimmed) == sendCase.outcome)
		#expect(server.requestCount == sendCase.requests)
		#expect(Set(try server.requests.map { try $0.note().id }).count == 1)
	}
}

let receivedOutcome = FeedbackDelivery.settle(prior: nil, answers: [AttemptAnswer(status: 204)])

func script(_ words: String) throws -> [FakeFeedbackAnswer] {
	try words.split(separator: ",").map { try #require(FakeFeedbackAnswer(word: String($0))) }
}

private func statusesWithThePoolBlocked(
	_ request: URLRequest, to server: FakeFeedbackServer, on session: URLSession,
	for limit: TimeInterval
) -> [Int?] {
	let priorities: [TaskPriority] = [.high, .medium, .low, .background]
	let width = ProcessInfo.processInfo.activeProcessorCount
	let started = DispatchSemaphore(value: 0)
	let gate = DispatchSemaphore(value: 0)
	for priority in priorities {
		for _ in 0..<width {
			Task.detached(priority: priority) {
				holdAThread(started: started, until: gate, for: limit * 4)
			}
		}
	}
	let saturated = DispatchTime.now() + limit
	for _ in 0..<width {
		guard started.wait(timeout: saturated) == .success else { break }
	}
	let free = status(of: request, on: session, within: limit)
	let arrived = DispatchSemaphore(value: 0)
	server.hold { arrived.signal() }
	let held = status(of: request, on: session, within: limit) {
		guard arrived.wait(timeout: .now() + limit) == .success else { return }
		server.release()
	}
	for _ in 0..<(width * priorities.count) { gate.signal() }
	return [free, held]
}

private func status(
	of request: URLRequest, on session: URLSession, within limit: TimeInterval,
	meanwhile: () -> Void = {}
) -> Int? {
	let answered = DispatchSemaphore(value: 0)
	let status = Mutex<Int?>(nil)
	let task = session.dataTask(with: request) { _, response, _ in
		status.withLock { $0 = (response as? HTTPURLResponse)?.statusCode }
		answered.signal()
	}
	task.resume()
	meanwhile()
	let outcome = answered.wait(timeout: .now() + limit)
	task.cancel()
	return outcome == .success ? status.withLock { $0 } : nil
}

private func holdAThread(
	started: DispatchSemaphore, until gate: DispatchSemaphore, for limit: TimeInterval
) {
	started.signal()
	_ = gate.wait(timeout: .now() + limit)
}

private final class FollowRedirects: NSObject, URLSessionTaskDelegate {
	func urlSession(
		_ session: URLSession, task: URLSessionTask,
		willPerformHTTPRedirection response: HTTPURLResponse,
		newRequest request: URLRequest,
		completionHandler: @escaping @Sendable (URLRequest?) -> Void
	) {
		completionHandler(request)
	}
}
