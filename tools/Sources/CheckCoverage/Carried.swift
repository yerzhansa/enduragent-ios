import ToolSupport

struct CarriedTest: Hashable {
	let file: String
	let name: String

	init(file: String, name: String) {
		self.file = file
		self.name = name
	}

	init?(_ test: JSONValue) throws {
		guard case .object = test, let file = try test.member("file").text else { return nil }
		let function = try test.member("function").text
		let proof = try test.member("class").text
		let method = try test.member("method").text
		switch (function, proof, method) {
		case (let function?, nil, nil):
			self.init(file: file, name: function)
		case (nil, let proof?, let method?):
			self.init(file: file, name: "\(proof).\(method)")
		default:
			return nil
		}
	}
}

extension CoverageChecker {
	static let retiringRecords = ["ADR-0083", "ADR-0079", "ADR-0082", "ADR-0084"]

	func checkCarried(_ carried: JSONValue, in sources: inout SourceFiles) throws {
		let files = try listedFiles(of: carried)
		var mapped: Set<CarriedTest> = []
		for (index, row) in try carried.member("tests").elements().enumerated() {
			guard let old = try CarriedTest(row.member("test")) else {
				try problems.report("carried \(index + 1)", "test-without-name")
				continue
			}
			let label = "carried \(old.name)"
			if !files.contains(old.file) {
				try problems.report(label, "unlisted-carried-file", old.file)
			}
			if !mapped.insert(old).inserted {
				try problems.report(label, "duplicate-carried-test", old.file)
			}
			if let declarations = try sources.declarations(in: old.file),
				!declarations.names.contains(old.name)
			{
				try problems.report(label, "missing-carried-test", old.file)
			}
			if try row.member("statement").text == nil {
				try problems.report(label, "no-statement")
			}
			try checkReplacement(of: row, label, listed: files, in: &sources)
		}
		for file in files {
			guard let declarations = try sources.declarations(in: file) else { continue }
			for name in declarations.names.sorted()
			where !mapped.contains(CarriedTest(file: file, name: name)) {
				try problems.report("carried", "unmapped-test", file, name)
			}
		}
	}

	private func listedFiles(of carried: JSONValue) throws -> Set<String> {
		var files: Set<String> = []
		for (index, entry) in try carried.member("files").elements().enumerated() {
			guard let file = entry.text else {
				try problems.report("carried file \(index + 1)", "no-identifier")
				continue
			}
			if !files.insert(file).inserted {
				try problems.report("carried file \(index + 1)", "duplicate-carried-file", file)
			}
		}
		return files
	}

	private func checkReplacement(
		of row: JSONValue, _ label: String, listed: Set<String>, in sources: inout SourceFiles
	) throws {
		let named = try row.member("replacements")
		let replacements = named.isTruthy ? try named.elements() : []
		switch (replacements.isEmpty, try row.member("retiredBy").text) {
		case (true, nil):
			try problems.report(label, "no-proof")
		case (false, .some):
			try problems.report(label, "more-than-one-proof")
		case (true, let reason?):
			if !Self.retiringRecords.contains(where: reason.contains) {
				try problems.report(label, "retired-without-adr")
			}
		case (false, nil):
			for replacement in replacements {
				if let file = try replacement.member("file").text, listed.contains(file) {
					try problems.report(label, "replacement-in-listed-file", file)
					continue
				}
				try check(replacement, label, in: &sources)
			}
		}
	}
}

extension SwiftDeclarations {
	var names: Set<String> {
		testFunctions.union(
			testCases.flatMap { testCase in
				testCase.testMethods.map { "\(testCase.name).\($0)" }
			})
	}
}
