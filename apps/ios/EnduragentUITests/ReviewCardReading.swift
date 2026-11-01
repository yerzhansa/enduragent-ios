import XCTest

@MainActor
enum ReviewCardReading {
	struct Line {
		var identifier: String
		var label: String
	}

	struct Spoken {
		var line: Line
		var frame: CGRect
	}

	static let minimumTarget: CGFloat = 44
	static let bar = "chat.review.bar"

	static func collect(_ node: any XCUIElementSnapshot, into items: inout [Spoken]) {
		let spoken = node.elementType == .staticText || node.elementType == .button
		if spoken && !node.label.isEmpty {
			items.append(
				Spoken(
					line: Line(identifier: node.identifier, label: node.label), frame: node.frame))
		}
		if node.elementType == .button { return }
		for child in node.children { collect(child, into: &items) }
	}

	static func follows(_ earlier: CGRect, _ later: CGRect) -> Bool {
		later.minY >= earlier.maxY - 2
			|| (later.minX >= earlier.maxX - 2 && later.maxY > earlier.minY)
	}
}
