import Foundation
import Synchronization
import Testing

struct PerformanceSamples {
	enum Quantile: Int {
		case median = 50
		case p95 = 95
	}

	static let batchCount = 32
	private static let outputLock = Mutex(())
	var batches: [[Duration]] = []

	mutating func measure<Value>(
		count: Int = 3, operation: () async throws -> Value, validate: (Value) -> Void
	) async rethrows {
		var batch: [Duration] = []
		for _ in 0..<count {
			let started = ContinuousClock.now
			let value = try await operation()
			batch.append(ContinuousClock.now - started)
			validate(value)
		}
		batches.append(batch)
	}

	func minimum(_ quantile: Quantile = .median) throws -> Duration {
		try #require(batches.count == Self.batchCount)
		try #require(batches.allSatisfy { !$0.isEmpty })
		return try #require(
			batches.map { $0.sorted()[$0.count * quantile.rawValue / 100] }.min())
	}

	func check(budget: Duration, quantile: Quantile = .median, name: String) throws {
		let elapsed = try minimum(quantile)
		let result =
			"\(name) quantile=\(quantile) minimum_ms=\(Self.milliseconds(elapsed))"
			+ " budget_ms=\(Self.milliseconds(budget)) samples_ms=\(description)\n"
		try Self.record(result, name: name)
		#expect(elapsed < budget, "\(result)")
	}

	func check(relativeTo baseline: Self, limit: Double, name: String) throws {
		let reference = try baseline.minimum()
		try #require(reference > .zero)
		let elapsed = try minimum()
		let ratio = elapsed / reference
		let result =
			"\(name) ratio=\(String(format: "%.3f", ratio)) limit=\(limit)"
			+ " baseline_minimum_ms=\(Self.milliseconds(reference))"
			+ " measured_minimum_ms=\(Self.milliseconds(elapsed))"
			+ " baseline_samples_ms=\(baseline.description) measured_samples_ms=\(description)\n"
		try Self.record(result, name: name)
		#expect(ratio < limit, "\(result)")
	}

	private var description: String {
		batches.map { $0.map(Self.milliseconds).joined(separator: ",") }.joined(separator: ";")
	}

	private static func milliseconds(_ duration: Duration) -> String {
		String(format: "%.3f", duration / .milliseconds(1))
	}

	private static func record(_ result: String, name: String) throws {
		Attachment.record(result, named: "\(name)-cost.txt")
		if let path = ProcessInfo.processInfo.environment["FLUSH_COST_OUT"] {
			try outputLock.withLock { _ in
				let handle = try FileHandle(forWritingTo: URL(fileURLWithPath: path))
				try handle.seekToEnd()
				try handle.write(contentsOf: Data(result.utf8))
				try handle.close()
			}
		}
	}
}
