import EnduragentCoach
import XCTest

extension ReviewCardReading {
	func auditPageByPage(_ screen: String) {
		guard audit("\(screen) text sizes", for: [.dynamicType]) != nil else { return }
		bringTheTitleIntoTheTranscript()
		for page in 0..<Self.pageLimit {
			let band = TutorialHarness.transcriptBand(run.app)
			let bar = run.named(Self.bar)
			let barEnds = bar.exists && bar.frame.maxY <= band.maxY + 1
			guard let items = audit("\(screen) page \(page)", for: [.textClipped, .hitRegion])
			else { return }
			let next = items.first { $0.frame.maxY > band.maxY }
			if next == nil && barEnds { return }
			guard let anchor = Self.anchor(in: items, band: band) else {
				XCTFail("\(name(screen)) page \(page): no line of the review is on screen")
				return
			}
			let margin = Self.pageMargin
			let toNext = (next?.frame.minY ?? band.maxY) - band.minY - margin
			let stride = toNext > margin ? min(toNext, band.height - 2 * margin) : band.height * 0.8
			let behind = returnAfterTheAudit(to: anchor)
			let now = TutorialHarness.transcriptBand(run.app)
			let start = CGPoint(x: now.midX, y: now.maxY - margin)
			TutorialHarness.drag(
				run.app, from: start, to: CGPoint(x: start.x, y: start.y - stride - behind),
				pace: .steady)
		}
		XCTFail(
			"\(name(screen)): the end of the review bar was not reached in \(Self.pageLimit) pages")
	}

	private static func anchor(in items: [Spoken], band: CGRect) -> Spoken? {
		let unique = items.filter { item in items.filter { $0.line == item.line }.count == 1 }
		return unique.first { $0.frame.minY >= band.minY && $0.frame.maxY <= band.maxY }
			?? unique.first { $0.frame.intersects(band) }
	}

	private func returnAfterTheAudit(to anchor: Spoken) -> CGFloat {
		let element = run.named("chat.transcript").descendants(matching: anchor.line.type)
			.matching(
				NSPredicate(
					format: "identifier == %@ AND label == %@", anchor.line.identifier,
					anchor.line.label)
			).firstMatch
		if !element.exists {
			let end = run.named("chat.transcript").staticTexts
				.matching(NSPredicate(format: "label == %@", run.say(Catalog.chatViewDisclaimer)))
				.firstMatch
			ReviewCardScreen.reveal(run.app, element, direction: end.exists ? .down : .up)
		}
		let target = anchor.frame.minY
		TutorialHarness.wait(
			until: {
				let offset = element.frame.minY - target
				if offset >= -4 && offset <= 60 { return true }
				let band = TutorialHarness.transcriptBand(run.app)
				let distance = min(offset > 0 ? offset - 20 : 20 - offset, band.height * 0.8)
				let start = CGPoint(x: band.midX, y: offset > 0 ? band.maxY - 24 : band.minY + 24)
				let end = CGPoint(
					x: start.x, y: offset > 0 ? start.y - distance : start.y + distance)
				TutorialHarness.drag(run.app, from: start, to: end, pace: .steady)
				return false
			}, within: .bulk,
			message: "\(element) did not return to \(target) after the audit")
		return max(0, element.frame.minY - target)
	}

	private func audit(_ page: String, for types: XCUIAccessibilityAuditType) -> [Spoken]? {
		var items: [Spoken] = []
		var owned: Set<Owner> = []
		do {
			for row in reviewRows() {
				let snapshot = try row.snapshot()
				Self.collect(snapshot, into: &items, leaving: nil)
				Self.own(snapshot, into: &owned)
			}
			try run.app.performAccessibilityAudit(for: types) { issue in
				guard let element = issue.element, element.exists else { return true }
				return !owned.contains(Self.owner(of: element))
			}
		} catch {
			XCTFail("\(name(page)): the review could not be read and audited: \(error)")
			return nil
		}
		return items
	}

	private struct Owner: Hashable {
		let type: UInt
		let identifier: String
		let label: String
	}

	private static func owner(of node: any XCUIElementSnapshot) -> Owner {
		Owner(type: node.elementType.rawValue, identifier: node.identifier, label: node.label)
	}

	private static func owner(of element: XCUIElement) -> Owner {
		Owner(
			type: element.elementType.rawValue, identifier: element.identifier,
			label: element.label)
	}

	private static func own(_ node: any XCUIElementSnapshot, into owned: inout Set<Owner>) {
		owned.insert(owner(of: node))
		for child in node.children { own(child, into: &owned) }
	}

	private static let pageLimit = 40
	private static let pageMargin: CGFloat = 24
}
