import ToolSupport

extension SourceChecker {
	static let failureCodeFile =
		"apps/ios/Packages/EnduragentCoach/Sources/EnduragentCoach/Diagnostics/FailureCode.swift"
	static let typeScope =
		#"((?:\b(?:private|fileprivate|public|package|internal|open|final|indirect)\s+"#
		+ #"|@\w+(?:\([^)]*\))?\s+)*)\b(struct|enum|class|actor|extension|protocol)\s+"#
		+ #"(?!(?:func|var|let|subscript|init|deinit|typealias|case|static)\b)"#
		+ #"(\w+(?:\.\w+)*)([^{};]*)\{|\{|\}"#
	static let errorInheritance = #"\b(?:Localized|CustomNS)?Error\b"#
	static let diagnosticsLogMaker =
		"apps/ios/Packages/EnduragentCoach/Sources/EnduragentCoach/Support/SupportService.swift"
	static let diagnosticsLogMade = #"\bDiagnosticsLog\s*(?:\.\s*init\s*)?\("#

	private struct Scope {
		let name: String?
		let hidden: Bool
	}

	func checkDiagnosticsLogMaker(_ source: SourceFile) throws {
		guard
			try patterns.test(Self.coachSource, source.file)
				|| patterns.test(Self.appSource, source.file),
			!source.file.hasSameUnits(as: Self.diagnosticsLogMaker),
			try patterns.test(Self.diagnosticsLogMade, patterns.withoutStrings(source.text))
		else { return }
		try findings.report(source.file, "diagnostics-log-one-maker")
	}

	func checkFailureCodes(_ sources: [SourceFile]) throws {
		var named: Set<String> = []
		var declared: [(file: String, name: String)] = []
		for source in sources {
			if source.file.hasSameUnits(as: Self.failureCodeFile) {
				named = try failureCodeNames(source.text)
			}
			for name in try errorTypes(declaredIn: source.text) {
				declared.append((source.file, name))
			}
		}
		for type in declared where !named.contains(type.name) {
			try findings.report(type.file, "failure-code-covers-errors", key: type.name)
		}
	}

	private func errorTypes(declaredIn text: String) throws -> [String] {
		let code = try patterns.withoutStrings(text)
		var scopes: [Scope] = []
		var errors: [String] = []
		for match in try patterns.matchAll(Self.typeScope, code) {
			if match.text.hasSameUnits(as: "}") {
				_ = scopes.popLast()
				continue
			}
			let kind = match.groups[2]
			guard !kind.isEmpty else {
				scopes.append(Scope(name: nil, hidden: scopes.last?.hidden ?? false))
				continue
			}
			let hidden =
				try (scopes.last?.hidden ?? false)
				|| patterns.test(#"\b(?:private|fileprivate)\b"#, match.groups[1])
			let path = (scopes.compactMap(\.name) + [match.groups[3]]).joined(separator: ".")
			scopes.append(Scope(name: path, hidden: hidden))
			if try !hidden && patterns.test(#"^(?:struct|enum|class)$"#, kind)
				&& inheritsError(match.groups[4])
			{
				errors.append(path)
			}
		}
		return errors
	}

	private func inheritsError(_ header: String) throws -> Bool {
		var header = header
		while try patterns.test(#"<[^<>]*>"#, header) {
			header = try patterns.replaceAll(#"<[^<>]*>"#, header, with: "")
		}
		let inheritance = try patterns.split(#"\bwhere\b"#, header)[0]
		return try patterns.test(#"^\s*:"#, inheritance)
			&& patterns.test(Self.errorInheritance, inheritance)
	}

	private func failureCodeNames(_ text: String) throws -> Set<String> {
		var names: Set<String> = []
		for block in try trailingBlocks(text, #"\benum\s+FailureCode\b"#) {
			let body = text.slice(block.start + 1, block.end)
			for payload in try patterns.matchAll(
				#"\bcase\s+\w+\s*\(\s*(\w+(?:\.\w+)*)\s*\)"#, body)
			{
				names.insert(payload.groups[1])
			}
		}
		for block in try trailingBlocks(text, #"\benum\s+PackageErrorType\b"#) {
			let body = text.slice(block.start + 1, block.end)
			for raw in try patterns.matchAll(#"\bcase\s+\w+\s*=\s*"([^"\\]*)""#, body) {
				names.insert(raw.groups[1])
			}
		}
		return names
	}
}
