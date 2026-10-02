import Foundation
import Network
import Synchronization
import Testing

@testable import EnduragentCoach

final class CalendarWriteServer: Sendable {
	struct Request: Sendable {
		let target: String
		let method: String
		let body: JSONValue
		let bodyBytes: Data
	}

	enum Response: Sendable {
		case success
		case status(Int)
		case malformed
		case body(String)
		case disconnected
		case heldBeforeCommit
		case heldAfterCommit
	}

	struct State: Sendable {
		var requests: [Request] = []
		var events: [[String: JSONValue]] = []
		var response = Response.success
		var readResponse = Response.success
		var held: [(NWConnection, Request, Bool)] = []
		var failures: [String] = []
	}

	let state = Mutex(State())
	private let listener: NWListener
	private let queue = DispatchQueue(label: "calendar-write-test")

	init() throws {
		let parameters = NWParameters.tcp
		parameters.requiredLocalEndpoint = .hostPort(host: "127.0.0.1", port: .any)
		listener = try NWListener(using: parameters)
	}

	var posts: [Request] { state.withLock { $0.requests.filter { $0.method == "POST" } } }
	var writes: [Request] { state.withLock { $0.requests.filter { $0.method != "GET" } } }
	var events: [[String: JSONValue]] { state.withLock { $0.events } }

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
				case .failed(let error): continuation.finish(throwing: error)
				default: break
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
		release()
		listener.stateUpdateHandler = nil
		listener.newConnectionHandler = nil
		listener.cancel()
	}

	func release() {
		let held = state.withLock { state in
			defer { state.held = [] }
			return state.held
		}
		for (connection, request, needsCommit) in held {
			let event = state.withLock { state in
				needsCommit ? commit(request, state: &state) : .null
			}
			send(connection, status: 200, body: event.canonicalDigestInput())
		}
	}

	private func receive(_ connection: NWConnection, data: Data) {
		connection.receive(minimumIncompleteLength: 1, maximumLength: 65_536) {
			[self] chunk, _, complete, error in
			if let error {
				state.withLock { $0.failures.append(String(describing: error)) }
				connection.cancel()
				return
			}
			let received = data + (chunk ?? Data())
			guard let boundary = received.range(of: Data("\r\n\r\n".utf8)) else {
				if complete { connection.cancel() } else { receive(connection, data: received) }
				return
			}
			let header = String(decoding: received[..<boundary.lowerBound], as: UTF8.self)
			let bytes = received[boundary.upperBound...]
			let length =
				header.components(separatedBy: "\r\n").first {
					$0.lowercased().hasPrefix("content-length:")
				}.flatMap { Int($0.dropFirst(15).trimmingCharacters(in: .whitespaces)) } ?? 0
			guard bytes.count >= length else {
				receive(connection, data: received)
				return
			}
			do {
				let parts = header.components(separatedBy: "\r\n")[0].split(separator: " ")
				let bodyBytes = Data(bytes.prefix(length))
				let request = Request(
					target: String(parts[1]), method: String(parts[0]),
					body: bodyBytes.isEmpty
						? .null : try JSONValue.parse(String(decoding: bodyBytes, as: UTF8.self)),
					bodyBytes: bodyBytes)
				respond(connection, to: request)
			} catch {
				Issue.record(error)
				connection.cancel()
			}
		}
	}

	private func respond(_ connection: NWConnection, to request: Request) {
		let result: (Response, JSONValue) = state.withLock { state in
			state.requests.append(request)
			if request.method != "GET" {
				let response = state.response
				if case .heldBeforeCommit = response {
					state.held.append((connection, request, true))
					return (response, .null)
				}
				let event = commit(request, state: &state)
				if case .heldAfterCommit = response {
					state.held.append((connection, request, false))
				}
				return (response, event)
			}
			if request.target.contains("/events") {
				if let id = request.target.split(separator: "/").last.flatMap({ Int($0) }) {
					guard let event = state.events.first(where: { $0["id"]?.intValue() == id })
					else {
						return (.status(404), .null)
					}
					return (state.readResponse, .object(event))
				}
				return (state.readResponse, .array(state.events.map(JSONValue.object)))
			}
			if request.target.contains("/wellness") || request.target.contains("/activities") {
				return (.success, .array([]))
			}
			return (.success, .object(["id": .string("i1001"), "name": .string("Ada")]))
		}
		switch result.0 {
		case .success: send(connection, status: 200, body: result.1.canonicalDigestInput())
		case .status(let status): send(connection, status: status, body: "{}")
		case .malformed: send(connection, status: 200, body: "{\"invalid\":true}")
		case .body(let body): send(connection, status: 200, body: body)
		case .disconnected: connection.cancel()
		case .heldBeforeCommit, .heldAfterCommit: break
		}
	}

	private func commit(_ request: Request, state: inout State) -> JSONValue {
		if request.method == "PUT" || request.method == "DELETE" {
			guard let id = request.target.split(separator: "/").last.flatMap({ Int($0) }),
				let index = state.events.firstIndex(where: { $0["id"]?.intValue() == id })
			else {
				Issue.record("write did not target an existing controlled event")
				return .null
			}
			if request.method == "DELETE" {
				state.events.remove(at: index)
				return .null
			}
			state.events[index].merge(request.body.objectFields) { _, approved in approved }
			return .object(state.events[index])
		}
		var fields = request.body.objectFields
		if request.target.contains("upsertOnUid=true"), let uid = fields["uid"],
			let index = state.events.firstIndex(where: { $0["uid"] == uid })
		{
			fields["id"] = state.events[index]["id"]
			state.events[index] = fields
		} else {
			fields["id"] = .number(Double(state.events.count + 1))
			state.events.append(fields)
		}
		return .object(fields)
	}

	private func send(_ connection: NWConnection, status: Int, body: String) {
		let response = [
			"HTTP/1.1 \(status) Response", "Content-Type: application/json",
			"Content-Length: \(body.utf8.count)", "Connection: close", "", body,
		].joined(separator: "\r\n")
		connection.send(
			content: Data(response.utf8),
			completion: .contentProcessed { [self] error in
				if let error { state.withLock { $0.failures.append(String(describing: error)) } }
				connection.cancel()
			})
	}
}
