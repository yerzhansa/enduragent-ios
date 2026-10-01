import XCTest

extension TutorialHarness {
	static func recordCount(
		_ app: XCUIApplication, _ kind: String, file: StaticString = #filePath, line: UInt = #line
	) -> String? {
		let element = named(app, "records.count.\(kind)")
		if element.exists { return element.label }
		let list = named(app, "records.list")
		let deadline = ContinuousClock.now + .seconds(15)
		while !named(app, "records.device").isHittable {
			guard ContinuousClock.now < deadline else {
				XCTFail(
					"Could not reach the top of Records to find \(kind)", file: file, line: line)
				return nil
			}
			list.swipeDown()
		}
		while !element.exists {
			if named(app, "records.entries").isHittable { return nil }
			guard ContinuousClock.now < deadline else {
				XCTFail("Could not finish searching Records for \(kind)", file: file, line: line)
				return nil
			}
			list.swipeUp()
		}
		return element.label
	}

	static func waitForRecordCount(
		_ app: XCUIApplication, _ kind: String, _ expected: String, timeout: TimeInterval = 10
	) {
		let deadline = Date().addingTimeInterval(timeout)
		while recordCount(app, kind) != expected, Date() < deadline {
			app.navigationBars.buttons["records.refresh"].tap()
		}
		XCTAssertEqual(recordCount(app, kind), expected)
	}

	static func settlementRows(_ app: XCUIApplication) -> [String] {
		recordRowLabels(app).filter { $0.hasPrefix("turnSettled") }
	}

	static func recordRowLabels(_ app: XCUIApplication) -> [String] {
		var seen: [String] = []
		var labels: [String] = []
		for _ in 0..<8 {
			let rows = app.descendants(matching: .any).matching(
				NSPredicate(format: "identifier BEGINSWITH %@", "records.row.")
			).allElementsBoundByIndex
			var added = false
			for row in rows where !seen.contains(row.identifier) {
				seen.append(row.identifier)
				labels.append(row.label)
				added = true
			}
			if !added, !labels.isEmpty {
				break
			}
			app.swipeUp()
		}
		return labels
	}

}
