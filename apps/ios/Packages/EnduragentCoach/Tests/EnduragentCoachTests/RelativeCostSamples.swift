import Foundation
import Testing

struct RelativeCostSamples {
	var baseline: [Duration] = []
	var measured: [Duration] = []

	func check(limit: Double, name: String) throws {
		try #require(baseline.count == 3 && measured.count == 3)
		let baselineMedian = baseline.sorted()[1]
		let measuredMedian = measured.sorted()[1]
		let ratio = measuredMedian / baselineMedian
		let milliseconds = { (duration: Duration) in
			String(format: "%.3f", duration / .milliseconds(1))
		}
		let result =
			"\(name) ratio=\(String(format: "%.3f", ratio)) limit=\(limit)"
			+ " baseline_median_ms=\(milliseconds(baselineMedian))"
			+ " measured_median_ms=\(milliseconds(measuredMedian))"
			+ " baseline_samples_ms=\(baseline.map(milliseconds).joined(separator: ","))"
			+ " measured_samples_ms=\(measured.map(milliseconds).joined(separator: ","))\n"
		Attachment.record(result, named: "\(name)-cost.txt")
		if let path = ProcessInfo.processInfo.environment["FLUSH_COST_OUT"] {
			let handle = try FileHandle(forWritingTo: URL(fileURLWithPath: path))
			try handle.seekToEnd()
			try handle.write(contentsOf: Data(result.utf8))
			try handle.close()
		}
		#expect(ratio < limit, "\(result)")
	}
}
