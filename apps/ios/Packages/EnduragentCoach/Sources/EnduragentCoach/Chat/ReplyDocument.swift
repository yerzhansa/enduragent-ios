public enum ReplyDocument: Sendable, Equatable {
	case blocks([ReplyBlock])
	case plainText(source: String, failure: ReplyParseFailure)

	public var accessibilityText: String {
		switch self {
		case .blocks(let blocks): return blocks.map(\.accessibilityText).joined(separator: "\n\n")
		case .plainText(let source, _): return source
		}
	}
}

public indirect enum ReplyBlock: Sendable, Equatable {
	case paragraph([ReplyRun])
	case heading(HeadingLevel, [ReplyRun])
	case list(ReplyList)
	case codeBlock(text: String, language: String?)
	case table(ReplyTable)

	public var accessibilityText: String {
		switch self {
		case .paragraph(let runs), .heading(_, let runs):
			return runs.map(\.accessibilityText).joined()
		case .codeBlock(let text, _): return text
		case .list(.ordered(let items)):
			return items.elements.map {
				$0.blocks.elements.map(\.accessibilityText).joined(separator: "\n")
			}.joined(separator: "\n")
		case .list(.unordered(let items)):
			return items.elements.map {
				$0.elements.map(\.accessibilityText).joined(separator: "\n")
			}.joined(separator: "\n")
		case .table(let table):
			return ([table.header] + table.rows).map { row in
				row.map { $0.map(\.accessibilityText).joined() }.joined(separator: "\t")
			}.joined(separator: "\n")
		}
	}
}

public enum HeadingLevel: Int, Sendable, Equatable {
	case one = 1
	case two
	case three
	case four
	case five
	case six
}

public struct NonEmpty<Element: Sendable & Equatable>: Sendable, Equatable {
	public let first: Element
	public let rest: [Element]

	public init(first: Element, rest: [Element]) {
		self.first = first
		self.rest = rest
	}

	public var elements: [Element] { [first] + rest }

	init(validating elements: [Element]) throws {
		guard let first = elements.first else { throw ReplyParseFailure.documentStructure }
		self.init(first: first, rest: Array(elements.dropFirst()))
	}
}

public enum ReplyList: Sendable, Equatable {
	case ordered(NonEmpty<NumberedItem>)
	case unordered(NonEmpty<NonEmpty<ReplyBlock>>)
}

public struct NumberedItem: Sendable, Equatable {
	public let ordinal: UInt
	public let blocks: NonEmpty<ReplyBlock>

	public init(ordinal: UInt, blocks: NonEmpty<ReplyBlock>) {
		self.ordinal = ordinal
		self.blocks = blocks
	}
}

public enum ColumnAlignment: Sendable, Equatable {
	case left
	case center
	case right
}

public struct ReplyTable: Sendable, Equatable {
	public let columns: NonEmpty<ColumnAlignment>
	public let header: [[ReplyRun]]
	public let rows: [[[ReplyRun]]]

	init(
		validating columns: NonEmpty<ColumnAlignment>, header: [[ReplyRun]], rows: [[[ReplyRun]]]
	) throws {
		let width = columns.elements.count
		guard header.count == width, rows.allSatisfy({ $0.count == width }) else {
			throw ReplyParseFailure.documentStructure
		}
		self.columns = columns
		self.header = header
		self.rows = rows
	}
}

public enum ReplyParseFailure: Error, Sendable, Equatable {
	case foundation(domain: String, code: Int)
	case documentStructure
	#if DEBUG
		case injected
	#endif
}
