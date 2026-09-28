import Testing

@Suite struct PerformanceSamplesTests {
	@Test func schedulingOutliersDoNotChangeTheUncontendedCost() throws {
		var batches = Array(
			repeating: [Duration.milliseconds(90)], count: PerformanceSamples.batchCount)
		batches[4] = [.milliseconds(12), .milliseconds(10), .milliseconds(11)]
		#expect(try PerformanceSamples(batches: batches).minimum() == .milliseconds(11))
	}

	@Test func consistentlyExpensiveWorkStillExceedsTheBudget() throws {
		let samples = PerformanceSamples(
			batches: Array(
				repeating: [.milliseconds(51), .milliseconds(80), .milliseconds(52)],
				count: PerformanceSamples.batchCount))
		#expect(try samples.minimum() > .milliseconds(50))
	}

	@Test func recurringSlowAttemptsRemainInTheCredentialTail() throws {
		let batches = (0..<PerformanceSamples.batchCount).map { index in
			let slow = index.isMultiple(of: 2) ? 30 : 0
			return Array(repeating: Duration.milliseconds(1), count: 200 - slow)
				+ Array(repeating: Duration.milliseconds(60), count: slow)
		}
		let samples = PerformanceSamples(batches: batches)
		#expect(try samples.minimum() == .milliseconds(1))
		#expect(try samples.pooled(.p95) == .milliseconds(60))
	}

	@Test func aStalledReferenceCannotHideARegression() throws {
		var baseline = Array(
			repeating: [Duration.milliseconds(10)], count: 9)
		baseline[4] = [.milliseconds(100)]
		let measured = PerformanceSamples(
			expectedBatchCount: 9, batches: Array(repeating: [.milliseconds(40)], count: 9))
		#expect(
			try measured.medianRatio(
				relativeTo: PerformanceSamples(expectedBatchCount: 9, batches: baseline)) == 4)
	}

	@Test func ratiosCompareAttemptsUnderTheSameLoad() throws {
		let baseline = PerformanceSamples(
			expectedBatchCount: 9,
			batches: [10, 100, 200, 100, 200, 100, 200, 100, 200].map { [.milliseconds($0)] })
		let measured = PerformanceSamples(
			expectedBatchCount: 9,
			batches: [40, 150, 300, 150, 300, 150, 300, 150, 300].map { [.milliseconds($0)] })
		#expect(try measured.medianRatio(relativeTo: baseline) == 1.5)
	}
}
