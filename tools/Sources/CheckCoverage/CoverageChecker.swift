import Foundation
import ToolSupport

final class Problems {
	private(set) var count = 0
	private let write: (String) throws -> Void

	init(write: @escaping (String) throws -> Void) {
		self.write = write
	}

	func report(_ criterion: String, _ rule: String, _ details: String...) throws {
		count += 1
		try write(([criterion, "[\(rule)]"] + details).joined(separator: " "))
	}
}

struct CoverageFailure: DescribedFailure {
	let description: String
}

struct CoverageChecker {
	static let marks = ["phoneSession", "noAutomatedProof"]
	static let handCheck = "checkedByHand"

	let root: String
	let table: String
	let problems: Problems

	func run() throws -> Int {
		let path = NodePath.resolve(root, table)
		guard let text = String(validating: try FileSystem.read(path), as: UTF8.self) else {
			throw CoverageFailure(description: "\(table) is not UTF-8")
		}
		let document = try JSONValue.parse(text)
		let milestone = try Milestone(units: document.member("units"), of: "the table")
		let requirements = try Requirements(declaredIn: document)
		let rows = try document.member("criteria").elements()
		let expected = Set(milestone.units.flatMap(\.identifiers))
		var seen: Set<String> = []
		var tested: Set<String> = []
		var sources = SourceFiles(root: root)
		for (index, row) in rows.enumerated() {
			guard let identifier = try row.member("id").text else {
				try problems.report("row \(index + 1)", "no-identifier")
				continue
			}
			if !expected.contains(identifier) {
				try problems.report(identifier, "unknown-criterion")
			}
			if !seen.insert(identifier).inserted {
				try problems.report(identifier, "duplicate-criterion")
			}
			if try row.member("statement").text == nil {
				try problems.report(identifier, "no-statement")
			}
			if try checkProof(of: row, identifier, in: &sources) {
				tested.insert(identifier)
			}
		}
		for unit in milestone.units {
			for identifier in unit.identifiers where !seen.contains(identifier) {
				try problems.report(identifier, "missing-criterion", "unit \(unit.name)")
			}
		}
		let carried = try document.member("carried")
		switch carried {
		case .undefined:
			break
		case .object:
			try checkCarried(carried, in: &sources)
		default:
			throw CoverageFailure(description: "the carried section is not a group")
		}
		if let requirements {
			if let scope = RequirementScope.of(table: table) {
				try RequirementChecker(
					requirements: requirements, scope: scope, problems: problems,
					criteria: seen, tested: tested
				).run(units: milestone.units)
			} else {
				try problems.report("requirements", "unknown-scope")
			}
		}
		return rows.count
	}

	private func checkProof(
		of row: JSONValue, _ identifier: String, in sources: inout SourceFiles
	) throws -> Bool {
		let listed = try row.member("tests")
		let tests = listed.isTruthy ? try listed.elements() : []
		var given = tests.isEmpty ? 0 : 1
		for mark in Self.marks where try row.member(mark).text != nil {
			given += 1
		}
		if given == 0 {
			try problems.report(identifier, "no-proof")
		}
		if given > 1 {
			try problems.report(identifier, "more-than-one-proof")
		}
		for test in tests {
			try check(test, identifier, in: &sources)
		}
		try checkHandCheck(of: row, identifier, in: sources)
		return !tests.isEmpty
	}

	private func checkHandCheck(
		of row: JSONValue, _ identifier: String, in sources: SourceFiles
	) throws {
		let check = try row.member(Self.handCheck)
		if case .undefined = check { return }
		guard case .object = check, try check.member("part").text != nil,
			let described = try check.member("described").text
		else {
			try problems.report(identifier, "empty-hand-check")
			return
		}
		if sources.path(of: described) == nil {
			try problems.report(identifier, "missing-hand-check-file", described)
		}
	}

	func check(
		_ test: JSONValue, _ identifier: String, in sources: inout SourceFiles
	) throws {
		guard let file = try test.member("file").text else {
			try problems.report(identifier, "test-without-file")
			return
		}
		let function = try test.member("function").text
		let proof = try test.member("class").text
		let method = try test.member("method").text
		guard let declarations = try sources.declarations(in: file) else {
			try problems.report(identifier, "missing-test-file", file)
			return
		}
		switch (function, proof, method) {
		case (let function?, nil, nil):
			if !declarations.testFunctions.contains(function) {
				try problems.report(identifier, "missing-test-function", file, function)
			}
		case (nil, let proof?, let method?):
			if !declarations.declares(method: method, in: proof) {
				try problems.report(identifier, "missing-proof-method", file, "\(proof).\(method)")
			}
		default:
			try problems.report(identifier, "test-without-name", file)
		}
	}
}

struct SourceFiles {
	let root: String
	private let patterns = JavaScriptPatterns()
	private var read: [String: SwiftDeclarations?] = [:]

	init(root: String) {
		self.root = root
	}

	mutating func declarations(in file: String) throws -> SwiftDeclarations? {
		if let known = read[file] { return known }
		let declarations = try load(file)
		read[file] = declarations
		return declarations
	}

	func path(of file: String) -> String? {
		let path = NodePath.resolve(root, file)
		var isDirectory: ObjCBool = false
		guard !NodePath.isAbsolute(file), path.hasUnitPrefix(root + "/"),
			FileManager.default.fileExists(atPath: path, isDirectory: &isDirectory),
			!isDirectory.boolValue
		else { return nil }
		return path
	}

	private func load(_ file: String) throws -> SwiftDeclarations? {
		guard let path = path(of: file),
			let text = String(validating: try FileSystem.read(path), as: UTF8.self)
		else { return nil }
		return try SwiftDeclarations(code: text, patterns: patterns)
	}
}

extension JSONValue {
	var text: String? {
		guard case .string(let value) = self, !value.isEmpty else { return nil }
		return value
	}
}
