import XCTest

enum ProofTimeout: TimeInterval {
	case interface = 10
	case turn = 40
	case watchdog = 75
	case longRateLimit = 330
	case beforeRetry = 5
	case transition = 2
}

enum ProofCondition {
	case exists
	case absent
	case hittable
	case enabled
	case foreground
	case value(String)

	var predicate: NSPredicate {
		switch self {
		case .exists: NSPredicate(format: "exists == true")
		case .absent: NSPredicate(format: "exists == false")
		case .hittable: NSPredicate(format: "exists == true AND hittable == true")
		case .enabled: NSPredicate(format: "exists == true AND enabled == true")
		case .foreground:
			NSPredicate(format: "state == %d", XCUIApplication.State.runningForeground.rawValue)
		case .value(let value): NSPredicate(format: "exists == true AND value == %@", value)
		}
	}
}

extension TutorialHarness {
	@discardableResult
	static func wait(
		_ element: XCUIElement, until condition: ProofCondition = .exists,
		within timeout: ProofTimeout = .interface, required: Bool = true,
		file: StaticString = #filePath, line: UInt = #line
	) -> Bool {
		let expectation = XCTNSPredicateExpectation(predicate: condition.predicate, object: element)
		let completed = XCTWaiter.wait(for: [expectation], timeout: timeout.rawValue) == .completed
		if required {
			XCTAssertTrue(
				completed, "\(element) never matched \(condition)", file: file, line: line)
		}
		return completed
	}
}
