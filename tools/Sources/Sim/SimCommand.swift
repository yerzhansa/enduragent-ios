import Foundation
import ToolSupport

@main
struct SimCommand {
	static func main() throws {
		exit(try run(Array(CommandLine.arguments.dropFirst())))
	}

	private static func run(_ argv: [String]) throws -> Int32 {
		let simulator: Simulator
		do {
			guard let executable = Bundle.main.executablePath else {
				throw SimFailure(description: "cannot find the running helper")
			}
			let environment = ProcessInfo.processInfo.environment
			let repo = try Checkout.root(ofExecutable: executable)
			let options = try SimOptions.parse(
				argv, environment: environment, repo: repo,
				directory: FileManager.default.currentDirectoryPath)
			simulator = Simulator(
				repo: repo, options: options, environment: environment, executable: executable)
		} catch {
			try Console.complain("sim: \(Console.text(of: error))")
			return 1
		}
		guard let command = simulator.options.command,
			Simulator.commands.contains(where: { $0.hasSameUnits(as: command) })
		else {
			try Console.complain(
				"Usage: sim <\(Simulator.commands.joined(separator: "|"))> [arguments]")
			return 2
		}
		do {
			return try simulator.perform(command, simulator.options.arguments) ? 0 : 1
		} catch {
			try Console.complain("sim \(command): \(Console.text(of: error))")
			return 1
		}
	}
}
