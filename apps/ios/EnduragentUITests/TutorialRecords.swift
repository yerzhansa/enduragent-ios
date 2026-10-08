import XCTest

extension TutorialHarness {
	static func recordCount(
		_ app: XCUIApplication, _ kind: String, file: StaticString = #filePath, line: UInt = #line
	) -> String? {
		let element = named(app, "records.count.\(kind)")
		if element.exists { return element.label }
		let list = named(app, "records.list")
		guard
			wait(
				until: {
					if named(app, "records.device").isHittable { return true }
					list.swipeDown()
					return false
				}, within: .records, message: "Could not reach the top of Records", file: file,
				line: line)
		else { return nil }
		guard
			wait(
				until: {
					if element.exists || named(app, "records.entries").isHittable { return true }
					list.swipeUp()
					return false
				}, within: .records, message: "Could not finish searching Records for \(kind)",
				file: file, line: line)
		else { return nil }
		guard element.exists else { return nil }
		return element.label
	}

	static func waitForRecordCount(
		_ app: XCUIApplication, _ kind: String, _ expected: String, within limit: Timeout = .screen
	) {
		wait(
			until: {
				if recordCount(app, kind) == expected { return true }
				app.navigationBars.buttons["records.refresh"].tap()
				return false
			}, within: limit, message: "\(kind) never reached \(expected)")
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
