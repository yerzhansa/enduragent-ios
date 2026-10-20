import XCTest

@MainActor
struct ReviewReadingOrder {
	enum Part: Hashable, CustomStringConvertible {
		case title
		case card(Int)
		case kept, notice, bar

		var description: String {
			switch self {
			case .title: "title"
			case .card(let index): "card \(index)"
			case .kept: "kept"
			case .notice: "notice"
			case .bar: "bar"
			}
		}
	}

	struct Heard {
		var part: Part
		var type: XCUIElement.ElementType
		var identifier: String
		var label: String
		var frame: CGRect
		var inTranscript: Bool

		var line: String { "\(part) \(identifier) \"\(label)\"" }
	}

	private(set) var heard: [Heard] = []
	private(set) var disorder: [String] = []

	var parts: [Part] {
		heard.map(\.part).reduce(into: []) { parts, part in
			if parts.last != part { parts.append(part) }
		}
	}

	var transcript: String { heard.map(\.line).joined(separator: " | ") }

	func lines(of part: Part) -> [Heard] {
		heard.filter { $0.part == part }
	}

	static func read(
		_ app: XCUIApplication, until control: String, eachPage: (Int) -> Void = { _ in },
		file: StaticString = #filePath, line: UInt = #line
	) -> ReviewReadingOrder {
		var reading = ReviewReadingOrder()
		bringTheTitleIntoTheTranscript(app)
		for page in 0..<pageLimit {
			let shown = Self.page(app)
			reading.merge(shown)
			eachPage(page)
			let band = TutorialHarness.transcriptBand(app)
			if !shown.contains(where: { $0.inTranscript && $0.frame.maxY > band.maxY + 1 }) {
				if reading.heard.contains(where: { $0.identifier == control }) { return reading }
				guard
					TutorialHarness.wait(
						TutorialHarness.named(app, control), within: .turn, required: false)
				else {
					XCTFail(
						"\(control) never appeared at the end of the review: \(reading.transcript)",
						file: file, line: line)
					return reading
				}
				continue
			}
			let reach = band.height * 0.3
			TutorialHarness.drag(
				app, from: CGPoint(x: band.midX, y: band.midY + reach),
				to: CGPoint(x: band.midX, y: band.midY - reach), pace: .steady)
		}
		XCTFail(
			"the end of the review was not reached in \(pageLimit) pages", file: file, line: line)
		return reading
	}

	private static let pageLimit = 160

	private static func bringTheTitleIntoTheTranscript(_ app: XCUIApplication) {
		let transcript = TutorialHarness.named(app, "chat.transcript")
		let title = transcript.descendants(matching: .any)
			.matching(identifier: "chat.preview.title").firstMatch
		if !title.exists {
			let rows = transcript.cells.containing(
				NSPredicate(format: "identifier BEGINSWITH %@", "chat.preview."))
			ReviewCardScreen.reveal(app, title, direction: rows.count == 0 ? .up : .down)
		}
		TutorialHarness.bringIntoTranscript(app, title)
	}

	private static func page(_ app: XCUIApplication) -> [Heard] {
		var items: [Heard] = []
		do {
			collect(try app.snapshot(), part: nil, inTranscript: false, into: &items)
		} catch {
			XCTFail("the review could not be read: \(error)")
		}
		return items
	}

	private static func collect(
		_ node: any XCUIElementSnapshot, part inherited: Part?, inTranscript within: Bool,
		into items: inout [Heard]
	) {
		let inTranscript = within || node.identifier == "chat.transcript"
		let part = Self.part(named: node.identifier) ?? inherited
		let spoken = node.elementType == .staticText || node.elementType == .button
		if spoken, !node.label.isEmpty, let part, inTranscript || part == .bar {
			items.append(
				Heard(
					part: part, type: node.elementType, identifier: node.identifier,
					label: node.label, frame: node.frame, inTranscript: inTranscript))
		}
		if node.elementType == .button { return }
		for child in node.children {
			collect(child, part: part, inTranscript: inTranscript, into: &items)
		}
	}

	private static func part(named identifier: String) -> Part? {
		switch identifier {
		case "chat.preview.title", "chat.preview.preparedEarlier": return .title
		case "chat.preview.kept": return .kept
		case "chat.preview.notice", "chat.review.notice", "chat.review.connect": return .notice
		case "chat.review.bar": return .bar
		default:
			let card = "chat.preview.card."
			guard identifier.hasPrefix(card) else { return nil }
			return Int(identifier.dropFirst(card.count)).map(Part.card)
		}
	}

	private mutating func merge(_ page: [Heard]) {
		var cursor = -1
		for (offset, item) in page.enumerated() {
			if let index = heard.firstIndex(where: { Self.same($0, item) }) {
				if index < cursor {
					disorder.append("\(item.line) is read before \(heard[cursor].line)")
				}
				cursor = max(cursor, index)
			} else {
				cursor += 1
				heard.insert(item, at: cursor)
			}
			let earlier = offset > 0 ? page[offset - 1] : nil
			if let earlier, earlier.inTranscript == item.inTranscript,
				!Self.follows(earlier.frame, item.frame)
			{
				disorder.append(
					"\(item.line) \(item.frame) is read after \(earlier.line) \(earlier.frame)")
			}
		}
	}

	private static func same(_ one: Heard, _ other: Heard) -> Bool {
		one.part == other.part && one.identifier == other.identifier && one.label == other.label
	}

	private static func follows(_ earlier: CGRect, _ later: CGRect) -> Bool {
		later.minY >= earlier.maxY - 2
			|| (later.minX >= earlier.maxX - 2 && later.maxY > earlier.minY)
	}
}
