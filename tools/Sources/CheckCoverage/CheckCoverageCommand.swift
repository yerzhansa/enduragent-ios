import Foundation
import ToolSupport

@main
struct CheckCoverageCommand {
	static func main() throws {
		let status = try CheckCoverage.run(
			arguments: Array(CommandLine.arguments.dropFirst()),
			directory: FileManager.default.currentDirectoryPath,
			output: { try FileHandle.standardOutput.write(contentsOf: Data("\($0)\n".utf8)) },
			errors: { try FileHandle.standardError.write(contentsOf: Data("\($0)\n".utf8)) })
		exit(status)
	}
}

enum CheckCoverageMode: Equatable {
	case tables(root: String?, tables: [String], requireFinal: Bool)
	case writeRetained(specification: String, decision: String)
	case retainedDrift(specification: String, decision: String)
	case writeCloseout(table: String)

	init(arguments: [String]) throws {
		switch arguments.first {
		case let flag? where flag == "--write-retained" || flag == "--retained-drift":
			guard arguments.count == 3 else {
				throw CoverageFailure(
					description: "Usage: check-coverage \(flag) specification.json decision.md")
			}
			self =
				flag == "--write-retained"
				? .writeRetained(specification: arguments[1], decision: arguments[2])
				: .retainedDrift(specification: arguments[1], decision: arguments[2])
		case "--write-closeout":
			guard arguments.count == 2 else {
				throw CoverageFailure(description: "Usage: check-coverage --write-closeout table")
			}
			self = .writeCloseout(table: arguments[1])
		default:
			let requireFinal = arguments.first == "--require-final"
			let rest = Array(arguments.dropFirst(requireFinal ? 1 : 0))
			let rooted = rest.first == "--root"
			let tables = Array(rest.dropFirst(rooted ? 2 : 0))
			guard !tables.isEmpty else {
				throw CoverageFailure(
					description:
						"Usage: check-coverage [--require-final] [--root repository] table...")
			}
			self = .tables(root: rooted ? rest[1] : nil, tables: tables, requireFinal: requireFinal)
		}
	}
}

enum CheckCoverage {
	static func run(
		arguments: [String], directory: String,
		output: (String) throws -> Void, errors: @escaping (String) throws -> Void
	) throws -> Int32 {
		let mode: CheckCoverageMode
		do {
			mode = try CheckCoverageMode(arguments: arguments)
		} catch let usage as CoverageFailure {
			try errors(usage.description)
			return 2
		}
		switch mode {
		case .tables(let root, let tables, let requireFinal):
			let status = try checkTables(
				tables, root: root, directory: directory, output: output, errors: errors)
			guard requireFinal, status != 2 else { return status }
			return try requireFinalStage(
				root: root, directory: directory, errors: errors, status: status)
		case .writeCloseout(let table):
			return try writeCloseout(table, directory: directory, output: output, errors: errors)
		case .writeRetained(let specification, let decision):
			return try writeRetained(
				specification, decision, directory: directory, output: output, errors: errors)
		case .retainedDrift(let specification, let decision):
			return try retainedDrift(
				specification, decision, directory: directory, output: output, errors: errors)
		}
	}

	private static func checkTables(
		_ tables: [String], root rootArgument: String?, directory: String,
		output: (String) throws -> Void, errors: @escaping (String) throws -> Void
	) throws -> Int32 {
		let root: String
		do {
			root = try FileSystem.realPath(NodePath.resolve(directory, rootArgument ?? ""))
		} catch {
			try errors("check-coverage: the repository could not be found: \(error)")
			return 2
		}
		var status = try verifyRetained(root: root, output: output, errors: errors)
		for table in tables {
			let problems = Problems { try errors("\(table): \($0)") }
			let count: Int
			do {
				count = try CoverageChecker(root: root, table: table, problems: problems).run()
			} catch {
				try errors("check-coverage: \(table) could not be read: \(error)")
				status = 2
				continue
			}
			try output("check-coverage: \(table): \(count) criteria; \(problems.count) problems.")
			if problems.count > 0, status == 0 { status = 1 }
		}
		return status
	}

	private static func requireFinalStage(
		root rootArgument: String?, directory: String, errors: (String) throws -> Void,
		status: Int32
	) throws -> Int32 {
		let stage: CloseoutStage?
		do {
			let root = try FileSystem.realPath(NodePath.resolve(directory, rootArgument ?? ""))
			stage = HandEvidence.exists(root: root) ? try HandEvidence.load(root: root).stage : nil
		} catch {
			try errors("check-coverage: \(HandEvidence.path) could not be read: \(error)")
			return 2
		}
		guard stage != .final else { return status }
		try errors(
			"\(HandEvidence.path): closeout [closeout-not-final] stage \(stage?.rawValue ?? "none")"
		)
		return 1
	}

	private static func writeCloseout(
		_ table: String, directory: String, output: (String) throws -> Void,
		errors: (String) throws -> Void
	) throws -> Int32 {
		let path = NodePath.resolve(directory, table)
		let section: CloseoutSection
		let written: String
		do {
			guard let retained = try RetainedRequirements.load(root: directory) else {
				throw CoverageFailure(description: "\(RetainedRequirements.path) does not exist")
			}
			guard HandEvidence.exists(root: directory) else {
				throw CoverageFailure(description: "\(HandEvidence.path) does not exist")
			}
			section = CloseoutDerivation.section(
				retained: retained, hand: try HandEvidence.load(root: directory),
				tables: try CoverageIndex.load(root: directory).tables)
			guard let text = String(validating: try FileSystem.read(path), as: UTF8.self) else {
				throw CoverageFailure(description: "\(table) is not UTF-8")
			}
			written = try CloseoutLayout.written(section, into: text)
		} catch {
			try errors(
				"check-coverage: the closeout section of \(table) could not be written: \(error)")
			return 2
		}
		try Data(written.utf8).write(to: URL(fileURLWithPath: path), options: .atomic)
		try output(
			"check-coverage: wrote the closeout section of \(table): \(section.rows.count) rows, "
				+ "stage \(section.stage.rawValue).")
		return 0
	}

	private static func verifyRetained(
		root: String, output: (String) throws -> Void, errors: (String) throws -> Void
	) throws -> Int32 {
		let retained: RetainedRequirements
		do {
			guard let loaded = try RetainedRequirements.load(root: root) else { return 0 }
			retained = loaded
		} catch {
			try errors("check-coverage: \(RetainedRequirements.path) could not be read: \(error)")
			return 2
		}
		if let mismatch = retained.digestMismatch {
			try errors(mismatch)
			return 1
		}
		try output(
			"check-coverage: \(RetainedRequirements.path): \(retained.summary); digest matches.")
		return 0
	}

	private static func writeRetained(
		_ specification: String, _ decision: String, directory: String,
		output: (String) throws -> Void, errors: (String) throws -> Void
	) throws -> Int32 {
		let retained: RetainedRequirements
		do {
			retained = try extractRetained(specification, decision, directory: directory)
		} catch {
			try errors("check-coverage: the retained list could not be extracted: \(error)")
			return 2
		}
		let path = NodePath.resolve(directory, RetainedRequirements.path)
		try FileManager.default.createDirectory(
			atPath: NodePath.dirname(path), withIntermediateDirectories: true)
		try Data(retained.encoded().utf8).write(to: URL(fileURLWithPath: path), options: .atomic)
		try output("check-coverage: wrote \(RetainedRequirements.path): \(retained.summary).")
		return 0
	}

	private static func retainedDrift(
		_ specification: String, _ decision: String, directory: String,
		output: (String) throws -> Void, errors: (String) throws -> Void
	) throws -> Int32 {
		let fresh: RetainedRequirements
		let committed: RetainedRequirements
		do {
			fresh = try extractRetained(specification, decision, directory: directory)
			guard let loaded = try RetainedRequirements.load(root: directory) else {
				throw CoverageFailure(description: "\(RetainedRequirements.path) does not exist")
			}
			committed = loaded
		} catch {
			try errors("check-coverage: the retained list could not be compared: \(error)")
			return 2
		}
		let lines =
			[committed.digestMismatch].compactMap { $0 }
			+ fresh.drift(from: committed).map { "retained.json [retained-drift] \($0.line)" }
		for line in lines {
			try errors(line)
		}
		guard lines.isEmpty else { return 1 }
		try output(
			"check-coverage: \(RetainedRequirements.path) matches the specification and "
				+ "\(RetainedRequirements.record).")
		return 0
	}

	private static func extractRetained(
		_ specification: String, _ decision: String, directory: String
	) throws -> RetainedRequirements {
		let specificationBytes = try FileSystem.read(NodePath.resolve(directory, specification))
		guard let specificationText = String(validating: specificationBytes, as: UTF8.self),
			let decisionText = String(
				validating: try FileSystem.read(NodePath.resolve(directory, decision)),
				as: UTF8.self)
		else {
			throw CoverageFailure(description: "the specification or the decision is not UTF-8")
		}
		return try RetainedRequirements.extract(
			specification: JSONValue.parse(specificationText),
			specificationBytes: specificationBytes, decision: decisionText)
	}
}
