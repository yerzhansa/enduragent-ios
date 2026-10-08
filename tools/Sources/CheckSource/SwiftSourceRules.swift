import ToolSupport

private enum Unit {
	static let openParenthesis = UInt16(UInt8(ascii: "("))
	static let closeParenthesis = UInt16(UInt8(ascii: ")"))
	static let openBrace = UInt16(UInt8(ascii: "{"))
	static let closeBrace = UInt16(UInt8(ascii: "}"))
	static let equals = UInt16(UInt8(ascii: "="))
}

extension SourceChecker {
	static let stringLiteral = #"(#+)?("""[\s\S]*?"""|"(?:\\.|[^"\\])*")\1"#
	static let setter =
		#"^\s*(?:@\w+(?:\([^)]*\))?\s+)*(?:(?:nonmutating|mutating)\s+)?"#
		+ #"(?:set|_modify|willSet|didSet)(?:\s*\([^)]*\))?\s*$"#
	static let duration =
		#"(?:Duration\s*\.\s*)?\.?(?:seconds|milliseconds|microseconds|nanoseconds|zero)\b"#

	func withoutStrings(_ text: String) throws -> String {
		try patterns.replaceAll(Self.stringLiteral, text, with: "\"\"")
	}

	func hasReleaseReference(_ text: String, _ reference: String) throws -> Bool {
		var guards: [(debug: Bool, alternate: Bool)] = []
		for line in try patterns.split(#"\r?\n"#, text) {
			if try patterns.test(#"^\s*#if\b"#, line) {
				guards.append((try patterns.test(#"^\s*#if\s+DEBUG\s*$"#, line), false))
			} else if try patterns.test(#"^\s*#(?:else|elseif)\b"#, line) {
				if !guards.isEmpty { guards[guards.count - 1].alternate = true }
			} else if try patterns.test(#"^\s*#endif\b"#, line) {
				_ = guards.popLast()
			} else if try patterns.test(reference, line)
				&& !guards.contains(where: { $0.debug && !$0.alternate })
			{
				return true
			}
		}
		return false
	}

	func hasExtraSecretStore(_ text: String) throws -> Bool {
		let declarations = try patterns.matchAll(
			#"\b(?:class|struct|actor|enum|extension)\s+(\w+(?:\.\w+)*)([^{}]*)\{"#, text)
		return try declarations.contains { declaration in
			if declaration.groups[1].hasSameUnits(as: "ICloudKeychainStore") { return false }
			var header = declaration.groups[2]
			while try patterns.test(#"<[^<>]*>"#, header) {
				header = try patterns.replaceAll(#"<[^<>]*>"#, header, with: "")
			}
			let inheritance = try patterns.split(#"\bwhere\b"#, header)[0]
			return try patterns.test(#"^\s*:[^:]*\bSecretStore\b"#, inheritance)
		}
	}

	func hasExposedMailboxState(_ text: String) throws -> Bool {
		let code = try withoutStrings(text)
		let length = code.utf16.count
		var depth = 0
		var projection = false
		for match in try patterns.matchAll(#"([^{};\n]*)([{};\n]|$)"#, code) {
			let declaration = match.groups[1]
			let boundary = match.groups[2]
			let opensBody =
				try boundary == "{"
				|| (boundary == "\n" && patterns.test(#"^\s*\{"#, code.slice(match.end, length)))
			if depth == 1, let member = try patterns.exec(#"^(.*?)\b(let|var)\s+"#, declaration),
				try !patterns.test(#"(?:^|\s)private(?:\s|$)"#, member.groups[1]),
				try !patterns.test(#"^\s*package\s+let\s+chatId\s*:\s*ChatID\s*$"#, declaration)
			{
				if try member.groups[2] == "let" || patterns.test(#"\blazy\b"#, member.groups[1])
					|| declaration.utf16.contains(Unit.equals) || !opensBody
				{
					return true
				}
				projection = true
			}
			if try depth == 2 && projection && opensBody && patterns.test(Self.setter, declaration)
			{
				return true
			}
			if boundary == "{" { depth += 1 }
			if boundary == "}" { depth -= 1 }
			if depth == 1 && boundary == "}" { projection = false }
		}
		return false
	}

	func trailingBlocks(_ code: String, _ pattern: String) throws -> [(start: Int, end: Int)] {
		let units = Array(code.utf16)
		return try patterns.matchAll(pattern, code).compactMap { match in
			var parentheses = 0
			var depth = 0
			var start: Int?
			for index in match.end..<units.count {
				let token = units[index]
				if start == nil {
					if token == Unit.openParenthesis { parentheses += 1 }
					if token == Unit.closeParenthesis { parentheses -= 1 }
					if token != Unit.openBrace || parentheses != 0 { continue }
					start = index
				}
				if token == Unit.openBrace { depth += 1 }
				if token == Unit.closeBrace {
					depth -= 1
					if depth == 0, let start { return (start, index) }
				}
			}
			return nil
		}
	}

	func hasUnboundedTestWait(_ text: String) throws -> Bool {
		let code = try withoutStrings(text)
		let loops = try trailingBlocks(code, #"\bwhile\b"#)
		let deadlines = try trailingBlocks(code, #"\bbeforeDeadline\b"#)
		let waits = try patterns.matchAll(
			#"\bawait\s+(?:[\w.]+\s*\.\s*waitUnlessCancelled\s*\(|withCheckedContinuation\b)"#, code
		)
		return waits.contains { wait in
			loops.contains { $0.start < wait.index && wait.index < $0.end }
				&& !deadlines.contains { $0.start < wait.index && wait.index < $0.end }
		}
	}

	func hasLiteralTestHangGuard(_ text: String) throws -> Bool {
		let code = try withoutStrings(text)
		return try patterns.test(#"\bwithin(?:\s+\w+\s*:\s*\w+\s*=|\s*:)\s*"# + Self.duration, code)
			|| patterns.test(
				#"\bContinuousClock(?:\s*\(\s*\))?\s*\.\s*now\s*\+\s*"# + Self.duration, code)
			|| patterns.test(
				#"\baddTask\s*\{\s*try\s+await\s+Task\s*\.\s*sleep\s*\(\s*for\s*:\s*"#
					+ Self.duration + #"(?:\s*\([^)]*\))?\s*\)\s*;?\s*return\s+(?:false|nil)\b"#,
				code)
	}

	func checkNavigationStacks(_ sources: [SourceFile]) throws {
		let declarations = #"\bstruct\s+(\w+)\s*:\s*View\b"#
		var views: [String: SourceFile] = [:]
		var roots: [SourceFile] = []
		for source in sources {
			let code = try withoutStrings(source.text)
			let names = try patterns.matchAll(declarations, code).map { $0.groups[1] }
			for (index, block) in try trailingBlocks(code, declarations).enumerated() {
				let body = code.slice(block.start + 1, block.end)
				views[names[index]] = SourceFile(file: source.file, text: body)
				let stacks = try trailingBlocks(body, #"\bNavigationStack\s*(?=\(\s*path\s*:)"#)
				for stack in stacks {
					roots.append(
						SourceFile(file: source.file, text: body.slice(stack.start + 1, stack.end)))
				}
			}
		}
		var visited: Set<String> = []
		var reported: Set<[UInt8]> = []
		while let root = roots.popLast() {
			var content = root.text
			let length = content.utf16.count
			for sheet in try trailingBlocks(root.text, #"\.(?:sheet|fullScreenCover)\b"#) {
				content =
					content.slice(0, sheet.start)
					+ String(repeating: " ", count: sheet.end - sheet.start + 1)
					+ content.slice(sheet.end + 1, length)
			}
			let file = Array(root.file.utf8)
			if try patterns.test(#"\bNavigationStack\b"#, content) && !reported.contains(file) {
				try findings.report(root.file, "shell-navigation-stack-owner")
				reported.insert(file)
			}
			for call in try patterns.matchAll(#"\b(\w+)\s*\("#, content) {
				let name = call.groups[1]
				if let view = views[name], !visited.contains(name) {
					visited.insert(name)
					roots.append(view)
				}
			}
		}
	}
}
