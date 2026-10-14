import Foundation
import Synchronization

@testable import EnduragentCoach

enum SpendBasis: String, Sendable {
	case reported
	case tokens
	case bound
}

enum LiveSpendEstimate {
	static let inputDollarsPerToken = 5.0 / 1_000_000
	static let outputDollarsPerToken = 25.0 / 1_000_000
	static let outputTokenBound = 16_384.0
	static let charactersPerToken = 3.0

	static func bound(for request: CompletionRequest) -> Double {
		let messages = request.messages.map { message in
			message.content + message.toolCalls.map { $0.name + $0.arguments }.joined()
		}
		let tools = request.tools.map { tool in
			tool.name.rawValue + tool.description + canonicalJSON(tool.parameters)
		}
		let characters = (messages + tools).reduce(0) { $0 + $1.utf16.count }
		return Double(characters) / charactersPerToken * inputDollarsPerToken
			+ outputTokenBound * outputDollarsPerToken
	}

	static func cost(of usage: Usage) -> (dollars: Double, basis: SpendBasis) {
		if let reported = usage.cost { return (reported, .reported) }
		return (
			Double(usage.inputTokens) * inputDollarsPerToken + Double(usage.outputTokens)
				* outputDollarsPerToken, .tokens
		)
	}
}

final class LiveSpendLedger: Sendable {
	static let unitLimit = 10.0
	static let header =
		"stamp\tscenario\tmodel\tinput_tokens\toutput_tokens\tcost_usd\tbasis\ttotal_usd"

	private struct State {
		var total: Double
		var scenario = "setup"
		var capReached = false
	}

	let file: URL
	let limit: Double
	private let state: Mutex<State>

	init(file: URL, limit: Double) throws {
		self.file = file
		self.limit = limit
		let manager = FileManager.default
		if !manager.fileExists(atPath: file.path) {
			try manager.createDirectory(
				at: file.deletingLastPathComponent(), withIntermediateDirectories: true)
			try Data((Self.header + "\n").utf8).write(to: file)
		}
		let rows = try String(contentsOf: file, encoding: .utf8).split(separator: "\n").dropFirst()
		let total = try rows.reduce(0.0) { sum, row in
			let columns = row.split(separator: "\t", omittingEmptySubsequences: false)
			guard columns.count == 8, let cost = Double(columns[5]) else {
				throw LiveCheckStop(
					description: "\(file.path) has a row that is not a spend row: \(row)")
			}
			return sum + cost
		}
		self.state = Mutex(State(total: total))
	}

	var total: Double { state.withLock { $0.total } }
	var capReached: Bool { state.withLock { $0.capReached } }

	func label(_ scenario: String) {
		state.withLock { $0.scenario = scenario }
	}

	func admit(_ estimate: Double) throws(ProviderFailure) {
		try state.withLock { (state: inout State) throws(ProviderFailure) in
			guard !state.capReached, state.total + estimate <= limit else {
				state.capReached = true
				throw ProviderFailure.accessExhausted
			}
		}
	}

	func charge(model: ModelID, usage: Usage?, bound: Double, at stamp: Date) throws {
		let (dollars, basis) = usage.map(LiveSpendEstimate.cost(of:)) ?? (bound, .bound)
		try state.withLock { state in
			state.total += dollars
			let row = [
				ISO8601DateFormatter().string(from: stamp), state.scenario, model.rawValue,
				String(usage?.inputTokens ?? 0), String(usage?.outputTokens ?? 0),
				String(format: "%.6f", dollars), basis.rawValue,
				String(format: "%.6f", state.total),
			].joined(separator: "\t")
			do {
				let handle = try FileHandle(forWritingTo: file)
				try handle.seekToEnd()
				try handle.write(contentsOf: Data((row + "\n").utf8))
				try handle.close()
			} catch {
				state.capReached = true
				throw error
			}
		}
	}
}

struct LiveExchange: Sendable {
	let request: CompletionRequest
	let events: [TransportEvent]
	let failure: String?

	var usage: Usage? {
		events.lazy.compactMap { event -> Usage? in
			guard case .finished(_, let usage) = event else { return nil }
			return usage
		}.first
	}
}

final class LiveExchangeLog: Sendable {
	private let exchanges = Mutex<[LiveExchange]>([])

	func append(_ exchange: LiveExchange) {
		exchanges.withLock { $0.append(exchange) }
	}

	func drain() -> [LiveExchange] {
		exchanges.withLock { taken in
			defer { taken.removeAll() }
			return taken
		}
	}
}

struct LiveMeteredTransport: ModelTransport {
	let inner: any ModelTransport
	let ledger: LiveSpendLedger
	let log: LiveExchangeLog

	func stream(_ request: CompletionRequest) -> AsyncThrowingStream<TransportEvent, Error> {
		AsyncThrowingStream { continuation in
			let task = Task { [inner, ledger, log] in
				let bound = LiveSpendEstimate.bound(for: request)
				var events: [TransportEvent] = []
				do {
					try ledger.admit(bound)
				} catch {
					log.append(
						LiveExchange(request: request, events: [], failure: "spend cap reached"))
					continuation.finish(throwing: error)
					return
				}
				var failure: (any Error)?
				do {
					for try await event in inner.stream(request) {
						events.append(event)
						continuation.yield(event)
					}
				} catch {
					failure = error
				}
				let exchange = LiveExchange(
					request: request, events: events,
					failure: failure.map { String(describing: $0) })
				do {
					try ledger.charge(
						model: request.model, usage: exchange.usage, bound: bound, at: Date())
				} catch {
					failure = error
				}
				log.append(exchange)
				continuation.finish(throwing: failure)
			}
			continuation.onTermination = { _ in task.cancel() }
		}
	}
}
