public struct SwiftDeclarations {
	public struct TestCase {
		public let name: String
		public let methods: Set<String>
	}

	public let functions: Set<String>
	public let testCases: [TestCase]

	public init(code: String, patterns: JavaScriptPatterns) throws {
		functions = try Self.functions(in: code, patterns)
		let declarations = try patterns.matchAll(#"\bclass\s+(\w+)\s*:\s*XCTestCase\b"#, code)
		testCases = try declarations.enumerated().map { index, declaration in
			let end =
				index + 1 < declarations.count
				? declarations[index + 1].index : code.utf16.count
			return TestCase(
				name: declaration.groups[1],
				methods: try Self.functions(in: code.slice(declaration.end, end), patterns))
		}
	}

	public func declares(method: String, in testCase: String) -> Bool {
		testCases.contains { $0.name == testCase && $0.methods.contains(method) }
	}

	private static func functions(in code: String, _ patterns: JavaScriptPatterns) throws
		-> Set<String>
	{
		Set(try patterns.matchAll(#"\bfunc\s+(\w+)\s*\("#, code).map { $0.groups[1] })
	}
}

extension JavaScriptPatterns {
	public func withoutStrings(_ swift: String) throws -> String {
		try replaceAll(#"(#+)?("""[\s\S]*?"""|"(?:\\.|[^"\\])*")\1"#, swift, with: "\"\"")
	}
}
