import XCTest

final class TutorialWaitProof: XCTestCase {
	func testAnAlreadySatisfiedConditionReturnsImmediately() {
		let started = ProcessInfo.processInfo.systemUptime
		let completed = TutorialHarness.wait(until: { true }, message: "condition is already true")
		XCTAssertTrue(completed)
		XCTAssertLessThan(ProcessInfo.processInfo.systemUptime - started, 0.5)
	}

	func testAConditionIsSampledAgainWithoutAOneSecondDelay() {
		var samples = 0
		let started = ProcessInfo.processInfo.systemUptime
		let completed = TutorialHarness.wait(
			until: {
				samples += 1
				return samples == 2
			}, message: "condition becomes true on the second sample")
		XCTAssertTrue(completed)
		XCTAssertEqual(samples, 2)
		XCTAssertLessThan(ProcessInfo.processInfo.systemUptime - started, 0.5)
	}
}
