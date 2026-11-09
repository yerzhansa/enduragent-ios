import Foundation
import ToolSupport

@main
struct RetroCommand {
	static func main() throws {
		let arguments = Array(CommandLine.arguments.dropFirst())
		guard arguments.count == 2, arguments[0] == "--transcripts" else {
			try Console.complain("Usage: retro --transcripts <Claude Code projects folder>")
			exit(2)
		}
		let git = Subprocess(directory: FileManager.default.currentDirectoryPath)
		let root = try git.capture("git", ["rev-parse", "--show-toplevel"])
		let common = try git.capture(
			"git", ["rev-parse", "--path-format=absolute", "--git-common-dir"])
		let checkout = NodePath.dirname(common)
		let prefix = checkout.replacingOccurrences(of: "/", with: "-")
			.replacingOccurrences(of: ".", with: "-")
		try Console.say(
			try Retro(root: root, transcripts: arguments[1], worktreePrefix: prefix).run())
	}
}
