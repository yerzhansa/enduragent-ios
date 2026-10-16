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

enum CheckCoverage {
	static func run(
		arguments: [String], directory: String,
		output: (String) throws -> Void, errors: @escaping (String) throws -> Void
	) throws -> Int32 {
		let rooted = arguments.first == "--root"
		let tables = Array(arguments.dropFirst(rooted ? 2 : 0))
		guard !tables.isEmpty else {
			try errors("Usage: check-coverage [--root repository] table...")
			return 2
		}
		let root: String
		do {
			root = try FileSystem.realPath(NodePath.resolve(directory, rooted ? arguments[1] : ""))
		} catch {
			try errors("check-coverage: the repository could not be found: \(error)")
			return 2
		}
		var status: Int32 = 0
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
}
