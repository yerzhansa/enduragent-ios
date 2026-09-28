import Foundation
import Synchronization
import Testing

struct PerformanceSamples {
	enum Quantile: Int {
		case median = 50
		case p95 = 95
	}

	enum Scope {
		case bestBatch
		case allAttempts
	}

	static let batchCount = 32
	private static let outputLock = Mutex(())
	var expectedBatchCount = Self.batchCount
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
		try #require(batches.count == expectedBatchCount)
		try #require(batches.allSatisfy { !$0.isEmpty })
		return try #require(
			batches.map { $0.sorted()[$0.count * quantile.rawValue / 100] }.min())
	}

	func pooled(_ quantile: Quantile) throws -> Duration {
		try #require(batches.count == expectedBatchCount)
		try #require(batches.allSatisfy { !$0.isEmpty })
		let samples = batches.joined().sorted()
		return samples[samples.count * quantile.rawValue / 100]
	}

	func check(
		budget: Duration, quantile: Quantile = .median, across scope: Scope = .bestBatch,
		name: String
	) throws {
		let elapsed = try scope == .bestBatch ? minimum(quantile) : pooled(quantile)
		let result =
			"\(name) quantile=\(quantile) scope=\(scope) elapsed_ms=\(Self.milliseconds(elapsed))"
			+ " budget_ms=\(Self.milliseconds(budget)) samples_ms=\(description)\n"
		try Self.record(result, name: name)
		#expect(elapsed < budget, "\(result)")
	}

	func check(relativeTo baseline: Self, limit: Double, name: String) throws {
		let ratio = try medianRatio(relativeTo: baseline)
		let result =
			"\(name) ratio=\(String(format: "%.3f", ratio)) limit=\(limit)"
			+ " statistic=median-paired-ratio"
			+ " baseline_samples_ms=\(baseline.description) measured_samples_ms=\(description)\n"
		try Self.record(result, name: name)
		#expect(ratio < limit, "\(result)")
	}

	func medianRatio(relativeTo baseline: Self) throws -> Double {
		try #require(batches.count == expectedBatchCount)
		try #require(baseline.batches.count == baseline.expectedBatchCount)
		try #require(batches.count == baseline.batches.count)
		let ratios = try zip(batches, baseline.batches).flatMap { measured, reference in
			try #require(!measured.isEmpty && measured.count == reference.count)
			return try zip(measured, reference).map { elapsed, duration in
				try #require(duration > .zero)
				return elapsed / duration
			}
		}.sorted()
		try #require(!ratios.isEmpty)
		return ratios[ratios.count / 2]
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
