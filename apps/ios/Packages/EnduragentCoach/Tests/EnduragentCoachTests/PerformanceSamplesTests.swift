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
		let batch =
			Array(repeating: Duration.milliseconds(1), count: 180)
			+ Array(repeating: Duration.milliseconds(60), count: 20)
		let samples = PerformanceSamples(
			batches: Array(repeating: batch, count: PerformanceSamples.batchCount))
		#expect(try samples.minimum() == .milliseconds(1))
		#expect(try samples.minimum(.p95) == .milliseconds(60))
	}

	@Test func aStalledReferenceCannotHideARegression() throws {
		var baseline = Array(
			repeating: [Duration.milliseconds(10)], count: PerformanceSamples.batchCount)
		baseline[4] = [.milliseconds(100)]
		let measured = PerformanceSamples(
			batches: Array(repeating: [.milliseconds(40)], count: PerformanceSamples.batchCount))
		#expect(try measured.minimum() / PerformanceSamples(batches: baseline).minimum() == 4)
	}
}
