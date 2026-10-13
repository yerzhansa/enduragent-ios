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

	let root: String
	let milestone: Milestone
	let problems: Problems

	func run() throws -> Int {
		let path = NodePath.resolve(root, milestone.table)
		guard let text = String(validating: try FileSystem.read(path), as: UTF8.self) else {
			throw CoverageFailure(description: "\(milestone.table) is not UTF-8")
		}
		let rows = try JSONValue.parse(text).member("criteria").elements()
		let expected = Set(milestone.units.flatMap(\.identifiers))
		var seen: Set<String> = []
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
			try checkProof(of: row, identifier, in: &sources)
		}
		for unit in milestone.units {
			for identifier in unit.identifiers where !seen.contains(identifier) {
				try problems.report(identifier, "missing-criterion", "unit \(unit.name)")
			}
		}
		return rows.count
	}

	private func checkProof(
		of row: JSONValue, _ identifier: String, in sources: inout SourceFiles
	) throws {
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
	}

	private func check(
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
			if !declarations.declares(function: function) {
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

private struct SourceFiles {
	let root: String
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

	private func load(_ file: String) throws -> SwiftDeclarations? {
		let path = NodePath.resolve(root, file)
		var isDirectory: ObjCBool = false
		guard !NodePath.isAbsolute(file), path.hasUnitPrefix(root + "/"),
			FileManager.default.fileExists(atPath: path, isDirectory: &isDirectory),
			!isDirectory.boolValue
		else { return nil }
		guard let text = String(validating: try FileSystem.read(path), as: UTF8.self) else {
			return nil
		}
		return SwiftDeclarations(source: text)
	}
}

extension JSONValue {
	fileprivate var text: String? {
		guard case .string(let value) = self, !value.isEmpty else { return nil }
		return value
	}
}
