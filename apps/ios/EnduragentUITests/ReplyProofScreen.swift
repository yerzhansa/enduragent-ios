import EnduragentCoach
import EnduragentCoachFixtures
import XCTest

@MainActor
enum ReplyProofScreen {
	static let leafIDs = [
		"reply.heading", "reply.paragraph", "reply.code", "reply.table.header", "reply.table.row",
	]

	static func labels(_ app: XCUIApplication) -> [String: [String]] {
		Dictionary(
			uniqueKeysWithValues: leafIDs.map { identifier in
				(
					identifier,
					app.descendants(matching: .any).matching(identifier: identifier)
						.allElementsBoundByIndex.map(\.label)
				)
			})
	}

	static func assertDocument(_ app: XCUIApplication, source: String) {
		guard case .blocks(let blocks) = ReplyParser.foundation.document(source) else {
			XCTFail("The fixture must produce a formatted document")
			return
		}
		var expected = Dictionary(uniqueKeysWithValues: leafIDs.map { ($0, [String]()) })
		for block in blocks { collect(block, into: &expected) }
		XCTAssertEqual(labels(app), expected)
		for block in blocks { assertSupportedMarkupRemoved(block) }
		let tables = app.scrollViews.matching(identifier: "reply.table").allElementsBoundByIndex
		XCTAssertEqual(
			tables.count,
			blocks.filter {
				if case .table(let table) = $0 { return table.layout == .grid }
				return false
			}.count)
		for table in tables { XCTAssertGreaterThan(table.frame.height, 44) }
		let code = app.staticTexts.matching(identifier: "reply.code").allElementsBoundByIndex
		if source == FormattedReplyFixture.source {
			XCTAssertEqual(code.count, 2)
			XCTAssertEqual(code.last?.label, String(repeating: "238 W Zone 2\n", count: 800))
		}
	}

	static func assertLinks(_ app: XCUIApplication) {
		XCTAssertEqual(app.links.count, 2)
		XCTAssertEqual(
			Set(app.links.allElementsBoundByIndex.map(\.label)),
			["threshold basics", "Training calendar"])
		for label in ["threshold basics", "Training calendar"] {
			let link = app.links.matching(NSPredicate(format: "label == %@", label)).firstMatch
			scroll(until: { link.isHittable }, action: { app.swipeUp(velocity: .slow) })
		}
		scrollToHeading(app)
	}

	static func scrollToHeading(_ app: XCUIApplication) {
		let heading = app.staticTexts.matching(
			NSPredicate(
				format: "identifier == %@ AND label == %@", "reply.heading", "Next week at a glance"
			)
		).firstMatch
		scroll(until: { heading.isHittable }, action: { app.swipeDown(velocity: .fast) })
	}

	static func scrollToEnd(_ app: XCUIApplication) {
		let end = TutorialHarness.text(app, containing: "END FORMATTED REPLY")
		scroll(until: { end.isHittable }, action: { app.swipeUp(velocity: .fast) })
	}

	static func scrollToFallbackStart(_ app: XCUIApplication) {
		let fallback = TutorialHarness.named(app, "reply.fallback")
		scroll(
			until: { fallback.frame.minY >= app.navigationBars.firstMatch.frame.maxY },
			action: { app.swipeDown(velocity: .fast) })
	}

	static func waitForPrefix(_ app: XCUIApplication) {
		guard
			case .blocks(let blocks) = ReplyParser.foundation.document(
				FormattedReplyFixture.streamingPrefix),
			case .codeBlock(let text, _) = blocks.last
		else {
			XCTFail("The streaming fixture must end within its long code block")
			return
		}
		TutorialHarness.wait(
			until: {
				app.staticTexts.matching(identifier: "reply.code").allElementsBoundByIndex.last?
					.label == text
			}, within: .turn, message: "The formatted prefix did not finish streaming")
	}

	static func openArchive(_ app: XCUIApplication) {
		TutorialHarness.openHistory(app)
		let row = TutorialHarness.historyRows(app).firstMatch
		TutorialHarness.wait(row, until: .hittable)
		row.tap()
		TutorialHarness.wait(TutorialHarness.named(app, "archive.readOnly"))
	}

	static func scroll(until condition: @escaping () -> Bool, action: @escaping () -> Void) {
		TutorialHarness.wait(
			until: {
				if condition() { return true }
				action()
				return condition()
			}, within: .bulk, message: "The reply content did not scroll into view")
	}

	private static func collect(_ block: ReplyBlock, into labels: inout [String: [String]]) {
		switch block {
		case .paragraph:
			labels["reply.paragraph", default: []].append(block.accessibilityText)
		case .heading:
			labels["reply.heading", default: []].append(block.accessibilityText)
		case .codeBlock:
			labels["reply.code", default: []].append(block.accessibilityText)
		case .table(let table):
			labels["reply.table.header", default: []] += spoken([table.headerDescription])
			labels["reply.table.row", default: []] += spoken(table.rowDescriptions)
		case .list(let list):
			switch list {
			case .ordered(let items):
				for item in items.elements {
					for child in item.blocks.elements { collect(child, into: &labels) }
				}
			case .unordered(let items):
				for item in items.elements {
					for child in item.elements { collect(child, into: &labels) }
				}
			}
		}
	}

	static func spoken(_ descriptions: [ReplyRowDescription]) -> [String] {
		descriptions.map(\.accessibilityText).filter { !$0.isEmpty }
	}

	static func tables(_ source: String) -> [ReplyTable] {
		guard case .blocks(let blocks) = ReplyParser.foundation.document(source) else {
			XCTFail("The fixture must produce a formatted document")
			return []
		}
		return blocks.compactMap { block in
			if case .table(let table) = block { return table }
			return nil
		}
	}

	private static func assertSupportedMarkupRemoved(_ block: ReplyBlock) {
		switch block {
		case .heading(_, let runs), .paragraph(let runs):
			for run in runs {
				if case .literal = run { continue }
				for marker in ["**", "#", "`", "|"] {
					XCTAssertFalse(run.accessibilityText.contains(marker))
				}
			}
		case .table(let table):
			for row in [table.header] + table.rows {
				for cell in row { assertSupportedMarkupRemoved(.paragraph(cell)) }
			}
		case .list(let list):
			switch list {
			case .ordered(let items):
				for item in items.elements {
					for child in item.blocks.elements { assertSupportedMarkupRemoved(child) }
				}
			case .unordered(let items):
				for item in items.elements {
					for child in item.elements { assertSupportedMarkupRemoved(child) }
				}
			}
		case .codeBlock:
			break
		}
	}
}
