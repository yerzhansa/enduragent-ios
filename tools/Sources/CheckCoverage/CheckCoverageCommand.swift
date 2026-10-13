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
		guard arguments.isEmpty || (arguments.count == 2 && arguments[0] == "--root") else {
			try errors("Usage: check-coverage [--root repository]")
			return 2
		}
		let problems = Problems(write: errors)
		let count: Int
		do {
			let root = try FileSystem.realPath(
				NodePath.resolve(directory, arguments.count == 2 ? arguments[1] : ""))
			count = try CoverageChecker(root: root, milestone: .three, problems: problems).run()
		} catch {
			try errors("check-coverage: the coverage table could not be read: \(error)")
			return 2
		}
		try output("check-coverage: \(count) criteria; \(problems.count) problems.")
		return problems.count == 0 ? 0 : 1
	}
}
