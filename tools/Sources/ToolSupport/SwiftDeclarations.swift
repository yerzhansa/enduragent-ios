public struct SwiftDeclarations {
	public struct TestCase {
		public let name: String
		public let testMethods: Set<String>
	}

	public let testFunctions: Set<String>
	public let testCases: [TestCase]

	public init(code: String, patterns: JavaScriptPatterns) throws {
		let units = Array(code.utf16)
		testFunctions = Set(
			try patterns.matchAll(#"@Test\b"#, code).compactMap { attribute in
				var reader = AttributedDeclaration(units: units, position: attribute.end)
				return reader.functionName()
			})
		let declarations = try patterns.matchAll(#"\bclass\s+(\w+)\s*:\s*XCTestCase\b"#, code)
		testCases = try declarations.enumerated().map { index, declaration in
			let end =
				index + 1 < declarations.count
				? declarations[index + 1].index : code.utf16.count
			return TestCase(
				name: declaration.groups[1],
				testMethods: Set(
					try patterns.matchAll(
						#"\bfunc\s+(test\w*)\s*\(\s*\)"#, code.slice(declaration.end, end)
					).map { $0.groups[1] }))
		}
	}

	public func declares(method: String, in testCase: String) -> Bool {
		testCases.contains { $0.name == testCase && $0.testMethods.contains(method) }
	}
}

private struct AttributedDeclaration {
	let units: [UInt16]
	var position: Int

	mutating func functionName() -> String? {
		skipArguments()
		while let word = nextWord() {
			if word == "func" {
				return nextWord()
			}
			skipArguments()
		}
		return nil
	}

	private mutating func nextWord() -> String? {
		skipWhitespace()
		let start = position
		if position < units.count, units[position] == Self.unit("@") {
			position += 1
		}
		while position < units.count, Self.isIdentifier(units[position]) {
			position += 1
		}
		guard position > start, units[position - 1] != Self.unit("@") else { return nil }
		return String(decoding: units[start..<position], as: UTF16.self)
	}

	private mutating func skipArguments() {
		skipWhitespace()
		guard position < units.count, units[position] == Self.unit("(") else { return }
		var depth = 0
		while position < units.count {
			switch units[position] {
			case Self.unit("("):
				depth += 1
			case Self.unit(")"):
				depth -= 1
			default:
				break
			}
			position += 1
			if depth == 0 { return }
		}
	}

	private mutating func skipWhitespace() {
		while position < units.count, Self.isWhitespace(units[position]) {
			position += 1
		}
	}

	private static func isIdentifier(_ unit: UInt16) -> Bool {
		switch unit {
		case Self.unit("a")...Self.unit("z"), Self.unit("A")...Self.unit("Z"),
			Self.unit("0")...Self.unit("9"), Self.unit("_"):
			true
		default:
			false
		}
	}

	private static func unit(_ scalar: Unicode.Scalar) -> UInt16 {
		UInt16(scalar.value)
	}

	private static func isWhitespace(_ unit: UInt16) -> Bool {
		unit == Self.unit(" ") || unit == Self.unit("\t") || unit == Self.unit("\n")
			|| unit == Self.unit("\r")
	}
}

extension JavaScriptPatterns {
	public func withoutStrings(_ swift: String) throws -> String {
		try replaceAll(#"(#+)?("""[\s\S]*?"""|"(?:\\.|[^"\\])*")\1"#, swift, with: "\"\"")
	}
}
