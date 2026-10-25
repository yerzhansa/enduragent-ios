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

	static func cost(of usage: Usage?, bound: Double) -> (dollars: Double, basis: SpendBasis) {
		guard let usage, usage.cost != nil || usage.inputTokens > 0 || usage.outputTokens > 0
		else { return (bound, .bound) }
		if let reported = usage.cost { return (reported, .reported) }
		return (
			Double(usage.inputTokens) * inputDollarsPerToken + Double(usage.outputTokens)
				* outputDollarsPerToken, .tokens
		)
	}
}

enum LiveMilestone: String, Sendable {
	case m4
	case m5
}

final class LiveSpendLedger: Sendable {
	static let earlierHeader =
		"stamp\tscenario\tmodel\tinput_tokens\toutput_tokens\tcost_usd\tbasis\ttotal_usd"
	static let header = earlierHeader + "\tmilestone"
	static let earlierMilestone = LiveMilestone.m4
	static let backupSuffix = ".before-m5"

	private struct State {
		var total: Double
		var scenario = "setup"
		var capReached = false
	}

	let file: URL
	let milestone: LiveMilestone
	let limit: Double
	private let state: Mutex<State>

	init(file: URL, milestone: LiveMilestone, limit: Double) throws {
		self.file = file
		self.milestone = milestone
		self.limit = limit
		let manager = FileManager.default
		if !manager.fileExists(atPath: file.path) {
			try manager.createDirectory(
				at: file.deletingLastPathComponent(), withIntermediateDirectories: true)
			try Data((Self.header + "\n").utf8).write(to: file)
		}
		let total = try Self.rows(of: file).reduce(0.0) { sum, row in
			row.milestone == milestone ? sum + row.cost : sum
		}
		self.state = Mutex(State(total: total))
	}

	static func backup(of file: URL) -> URL {
		file.deletingLastPathComponent().appending(path: file.lastPathComponent + backupSuffix)
	}

	private static func rows(of file: URL) throws -> [(cost: Double, milestone: LiveMilestone)] {
		var lines = try String(contentsOf: file, encoding: .utf8).split(
			separator: "\n", omittingEmptySubsequences: false)
		if lines.last?.isEmpty == true { lines.removeLast() }
		switch lines.first {
		case header?:
			return try spendRows(lines, of: file, width: 9) { columns in
				LiveMilestone(rawValue: String(columns[8]))
			}
		case earlierHeader?:
			let rows = try spendRows(lines, of: file, width: 8) { _ in earlierMilestone }
			try migrate(file, lines: lines)
			return rows
		default:
			throw LiveCheckStop(
				description:
					"\(file.path) line 1 is not a spend header: \(lines.first.map(String.init) ?? "")"
			)
		}
	}

	private static func spendRows(
		_ lines: [Substring], of file: URL, width: Int,
		milestone: ([Substring]) -> LiveMilestone?
	) throws -> [(cost: Double, milestone: LiveMilestone)] {
		try lines.enumerated().dropFirst().map { number, row in
			let columns = row.split(separator: "\t", omittingEmptySubsequences: false)
			guard columns.count == width, let cost = Double(columns[5]),
				let milestone = milestone(columns)
			else {
				throw LiveCheckStop(
					description: "\(file.path) line \(number + 1) is not a spend row: \(row)")
			}
			return (cost, milestone)
		}
	}

	private static func migrate(_ file: URL, lines: [Substring]) throws {
		let manager = FileManager.default
		let copy = backup(of: file)
		if manager.fileExists(atPath: copy.path) {
			guard try Data(contentsOf: copy) == Data(contentsOf: file) else {
				throw LiveCheckStop(
					description:
						"\(copy.path) exists and differs from \(file.path), so \(file.path) was not migrated."
				)
			}
		} else {
			try manager.copyItem(at: file, to: copy)
		}
		let migrated =
			[header] + lines.dropFirst().map { String($0) + "\t" + earlierMilestone.rawValue }
		let staged = file.deletingLastPathComponent().appending(
			path: file.lastPathComponent + ".migrating")
		try Data((migrated.joined(separator: "\n") + "\n").utf8).write(to: staged)
		_ = try manager.replaceItemAt(file, withItemAt: staged)
	}

	var total: Double { state.withLock { $0.total } }
	var capReached: Bool { state.withLock { $0.capReached } }

	var statement: String {
		let (total, capReached) = state.withLock { ($0.total, $0.capReached) }
		return "Model spend total for \(milestone.rawValue): "
			+ String(format: "$%.6f of $%.2f", total, limit)
			+ (capReached ? "; the cap stopped the suite." : ".")
	}

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
		let (dollars, basis) = LiveSpendEstimate.cost(of: usage, bound: bound)
		try state.withLock { state in
			state.total += dollars
			let row = [
				ISO8601DateFormatter().string(from: stamp), state.scenario, model.rawValue,
				String(usage?.inputTokens ?? 0), String(usage?.outputTokens ?? 0),
				String(format: "%.6f", dollars), basis.rawValue,
				String(format: "%.6f", state.total), milestone.rawValue,
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
