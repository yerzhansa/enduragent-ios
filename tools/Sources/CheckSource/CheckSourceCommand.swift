import Foundation
import ToolSupport

@main
struct CheckSourceCommand {
	static func main() throws {
		let arguments = Array(CommandLine.arguments.dropFirst())
		guard arguments.isEmpty || (arguments.count == 2 && arguments[0] == "--root") else {
			try Console.complain("Usage: check-source [--root repository]")
			exit(2)
		}
		let root = arguments.count == 2 ? arguments[1] : FileManager.default.currentDirectoryPath
		do {
			let report = try SourceCheck().run(root: root)
			for violation in report.violations {
				try Console.complain(violation.line)
			}
			try Console.say(report.summary)
			exit(report.violations.isEmpty ? 0 : 1)
		} catch {
			try Console.complain("check-source: \(error)")
			exit(2)
		}
	}
}
