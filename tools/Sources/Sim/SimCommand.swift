import Foundation
import ToolSupport

@main
struct SimCommand {
	static func main() throws {
		let arguments = Array(CommandLine.arguments.dropFirst())
		let commands = Simulator.commands
		guard let command = arguments.first, commands.contains(command) else {
			try Console.complain("Usage: sim <\(commands.joined(separator: "|"))> [arguments]")
			exit(2)
		}
		do {
			let succeeded = try Simulator().perform(command, Array(arguments.dropFirst()))
			exit(succeeded ? 0 : 1)
		} catch {
			try Console.complain("sim \(command): \(error)")
			exit(1)
		}
	}
}
