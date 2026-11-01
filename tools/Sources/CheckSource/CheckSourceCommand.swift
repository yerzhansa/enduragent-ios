import Foundation
import ToolSupport

@main
struct CheckSourceCommand {
	static func main() throws {
		let status = try CheckSource.run(
			arguments: Array(CommandLine.arguments.dropFirst()),
			directory: FileManager.default.currentDirectoryPath,
			output: { try FileHandle.standardOutput.write(contentsOf: Data("\($0)\n".utf8)) },
			errors: { try FileHandle.standardError.write(contentsOf: Data("\($0)\n".utf8)) })
		exit(status)
	}
}

enum CheckSource {
	static func run(
		arguments: [String], directory: String,
		output: (String) throws -> Void, errors: @escaping (String) throws -> Void
	) throws -> Int32 {
		guard arguments.isEmpty || (arguments.count == 2 && arguments[0] == "--root") else {
			try errors("Usage: check-source [--root repository]")
			return 2
		}
		let findings = Findings(write: errors)
		let count: Int
		do {
			let root = try FileSystem.realPath(
				NodePath.resolve(directory, arguments.count == 2 ? arguments[1] : ""))
			count = try SourceChecker(root: root, findings: findings).run()
		} catch {
			try errors("check-source: inventory or file parsing failed; content omitted.")
			return 2
		}
		try output("check-source: \(count) tracked files; \(findings.count) violations.")
		return findings.count == 0 ? 0 : 1
	}
}
