import XCTest

final class TutorialWaitProof: XCTestCase {
	func testSatisfiedElementConditionsReturnWithoutAOneSecondFloor() {
		let app = XCUIApplication()
		TutorialHarness.launch(app)
		TutorialHarness.completeOnboarding(app)
		let composer = TutorialHarness.named(app, "chat.composer")
		let absent = TutorialHarness.named(app, "wait-proof.absent")
		let reply = TutorialHarness.rememberReply
		TutorialHarness.exchange(app, TutorialHarness.remember)
		TutorialHarness.waitForLabel(app, reply)
		let checks: [() -> Void] = [
			{ TutorialHarness.wait(composer) },
			{ TutorialHarness.wait(absent, until: .absent) },
			{ TutorialHarness.waitForLabel(app, reply) },
			{ TutorialHarness.wait(app, until: .foreground) },
		]
		for check in checks {
			let started = ProcessInfo.processInfo.systemUptime
			check()
			XCTAssertLessThan(ProcessInfo.processInfo.systemUptime - started, 1)
		}
	}

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
