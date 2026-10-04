import EnduragentCoach
import EnduragentCoachFixtures
import Foundation
import Network
import Synchronization
import Testing

@testable import Enduragent

extension FixtureLaunchTests {
	@Test(.timeLimit(.minutes(1)))
	func fixtureBlockerDoesNotCountARequestFromTheLiveCreditsClient() async throws {
		let services = try services()
		let fakes = try #require(services.fixture)
		let host = try #require(fakes.host)
		let worker = try LocalCreditsWorker(answering: #"{"kind":"grantToppedUp","added":1}"#)
		let base = try await worker.start()
		defer { worker.stop() }
		let miswired = fixture.own(
			AppServices(
				coach: Coach(
					sport: .cycling,
					ports: CoachPorts(
						records: fixture.records, secrets: fakes.secrets,
						models: .scripted(fakes.transport),
						training: .fake { credential, _ in
							fakes.trainingPeer.client(for: credential)
						},
						credits: .worker(base), host: host, clock: services.clock),
					builtInModel: AppServices.builtInModel, displayLocale: testLocaleResolver()),
				deviceCheck: FakeDeviceCheckTokenProvider(), clock: services.clock,
				leases: { host.leases }, packPrices: { _ in [:] }))
		let countedBefore = FixtureBlockingURLProtocol.requestCount

		let notice = await miswired.coach.claimStarter(deviceCheck: Data())

		let counted = FixtureBlockingURLProtocol.requestCount - countedBefore
		#expect(
			counted == 0,
			"The blocker counted \(counted) of 1 live request; Debug would read \(FixtureBlockingURLProtocol.requestCount) requests"
		)
		#expect(
			worker.requestCount == 1,
			"The local worker received \(worker.requestCount) requests, so the probe decides nothing unless the blocker counted one"
		)
		#expect(worker.failures.isEmpty, "\(worker.failures)")
		#expect(notice.key == Catalog.onboardingStarterAdded)
	}
}

private final class LocalCreditsWorker: Sendable {
	private struct State: Sendable {
		var requests = 0
		var failures: [String] = []
	}

	private static let headerEnd = Data("\r\n\r\n".utf8)

	private let state = Mutex(State())
	private let listener: NWListener
	private let queue = DispatchQueue(label: "fixture-network-probe")
	private let body: String

	var requestCount: Int { state.withLock { $0.requests } }
	var failures: [String] { state.withLock { $0.failures } }

	init(answering body: String) throws {
		self.body = body
		let parameters = NWParameters.tcp
		parameters.requiredLocalEndpoint = .hostPort(host: "127.0.0.1", port: .any)
		listener = try NWListener(using: parameters)
	}

	func start() async throws -> URL {
		listener.newConnectionHandler = { [self] connection in
			connection.start(queue: queue)
			receive(connection, received: Data())
		}
		let ports = AsyncThrowingStream<NWEndpoint.Port, Error> { continuation in
			listener.stateUpdateHandler = { [listener] state in
				switch state {
				case .ready:
					if let port = listener.port { continuation.yield(port) }
					continuation.finish()
				case .failed(let error):
					continuation.finish(throwing: error)
				default:
					break
				}
			}
			listener.start(queue: queue)
		}
		for try await port in ports {
			guard let url = URL(string: "http://127.0.0.1:\(port.rawValue)") else {
				throw URLError(.badURL)
			}
			return url
		}
		throw URLError(.cannotConnectToHost)
	}

	func stop() {
		listener.stateUpdateHandler = nil
		listener.newConnectionHandler = nil
		listener.cancel()
	}

	private func receive(_ connection: NWConnection, received: Data) {
		connection.receive(minimumIncompleteLength: 1, maximumLength: 65_536) {
			[self] chunk, _, complete, error in
			if let error {
				fail("\(error)", closing: connection)
				return
			}
			let request = received + (chunk ?? Data())
			guard isWhole(request) else {
				if complete {
					fail("The request ended early", closing: connection)
				} else {
					receive(connection, received: request)
				}
				return
			}
			state.withLock { $0.requests += 1 }
			answer(connection)
		}
	}

	private func isWhole(_ request: Data) -> Bool {
		guard let head = request.range(of: Self.headerEnd) else { return false }
		let lines = String(decoding: request[..<head.lowerBound], as: UTF8.self)
			.components(separatedBy: "\r\n")
		let length =
			lines.compactMap { line -> Int? in
				let field = line.split(separator: ":", maxSplits: 1)
				guard field.count == 2, field[0].lowercased() == "content-length" else {
					return nil
				}
				return Int(field[1].trimmingCharacters(in: .whitespaces))
			}.first ?? 0
		return request.distance(from: head.upperBound, to: request.endIndex) >= length
	}

	private func answer(_ connection: NWConnection) {
		let response = [
			"HTTP/1.1 200 OK",
			"Content-Type: application/json",
			"Content-Length: \(body.utf8.count)",
			"Connection: close",
			"",
			body,
		].joined(separator: "\r\n")
		connection.send(
			content: Data(response.utf8),
			completion: .contentProcessed { [self] error in
				if let error { state.withLock { $0.failures.append("\(error)") } }
				connection.cancel()
			})
	}

	private func fail(_ failure: String, closing connection: NWConnection) {
		state.withLock { $0.failures.append(failure) }
		connection.cancel()
	}
}
