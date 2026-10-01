import Foundation
import Network
import Synchronization
import Testing

final class CacheableHTTPServer: Sendable {
	let requests = Mutex<[String]>([])
	private let listener: NWListener
	private let queue = DispatchQueue(label: "http-cache-test")

	private let responseBody: @Sendable (Int) -> String
	private let responseHeaders: @Sendable (Int) -> [String]

	init(
		responseHeaders: @escaping @Sendable (Int) -> [String] = { _ in [] },
		responseBody: @escaping @Sendable (Int) -> String
	) throws {
		self.responseBody = responseBody
		self.responseHeaders = responseHeaders
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
					Issue.record("Incomplete HTTP request")
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
			let body = responseBody(count)
			let headers =
				[
					"HTTP/1.1 200 OK",
					"Content-Type: application/json",
					"Cache-Control: public, max-age=3600",
					"Content-Length: \(body.utf8.count)",
					"Connection: close",
				] + responseHeaders(count)
			let response = (headers + ["", body]).joined(separator: "\r\n")
			connection.send(
				content: Data(response.utf8),
				completion: .contentProcessed { error in
					if let error { Issue.record(error) }
					connection.cancel()
				})
		}
	}
}
