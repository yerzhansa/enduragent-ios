import Foundation
import Network
import Synchronization
import Testing

@testable import EnduragentCoach

extension CreditsClientTests {
	@Test func balanceIsNotServedFromCache() async throws {
		let server = try CacheableCreditsServer()
		defer { server.stop() }
		let base = try await server.start()
		let secrets = FakeSecretStore()
		try secrets.storeCreditsAccount(
			CreditsAccount(appAccountToken: UUID(), key: "sk-or-test-cache"))
		let client = PhoneCreditsClient(
			vault: testVault(secrets), workerBase: base, openRouterBase: base)
		let scale = CreditScale(creditsPerUsd: 100)
		let first = try await client.balance(scale: scale)
		let second = try await client.balance(scale: scale)
		#expect(first == CreditBalance(credits: Credits(units: 200)))
		#expect(second == CreditBalance(credits: Credits(units: 100)))
		let requests = server.requests.withLock { $0 }
		#expect(requests.count == 2)
		for request in requests {
			#expect(request.hasPrefix("GET /key HTTP/1.1\r\n"))
			#expect(request.contains("Authorization: Bearer sk-or-test-cache\r\n"))
		}
	}
}

private final class CacheableCreditsServer: Sendable {
	let requests = Mutex<[String]>([])
	private let listener: NWListener
	private let queue = DispatchQueue(label: "credits-cache-test")

	init() throws {
		let parameters = NWParameters.tcp
		parameters.requiredLocalEndpoint = .hostPort(host: "127.0.0.1", port: .any)
		listener = try NWListener(using: parameters)
	}

	func start() async throws -> URL {
		listener.newConnectionHandler = { [self] connection in
			connection.start(queue: queue)
			receive(connection, data: Data())
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
			return try #require(URL(string: "http://127.0.0.1:\(port.rawValue)"))
		}
		throw URLError(.cannotConnectToHost)
	}

	func stop() {
		listener.stateUpdateHandler = nil
		listener.newConnectionHandler = nil
		listener.cancel()
	}

	private func receive(_ connection: NWConnection, data: Data) {
		connection.receive(minimumIncompleteLength: 1, maximumLength: 65_536) {
			[self] chunk, _, complete, error in
			if let error {
				Issue.record(error)
				connection.cancel()
				return
			}
			let received = data + (chunk ?? Data())
			let request = String(decoding: received, as: UTF8.self)
			guard request.contains("\r\n\r\n") else {
				if complete {
					Issue.record("Incomplete credits request")
					connection.cancel()
				} else {
					receive(connection, data: received)
				}
				return
			}
			let count = requests.withLock {
				$0.append(request)
				return $0.count
			}
			let body = "{\"data\":{\"limit_remaining\":\(count == 1 ? 2 : 1)}}"
			let response = [
				"HTTP/1.1 200 OK",
				"Content-Type: application/json",
				"Cache-Control: public, max-age=3600",
				"Content-Length: \(body.utf8.count)",
				"Connection: close", "", body,
			].joined(separator: "\r\n")
			connection.send(
				content: Data(response.utf8),
				completion: .contentProcessed { error in
					if let error { Issue.record(error) }
					connection.cancel()
				})
		}
	}
}
