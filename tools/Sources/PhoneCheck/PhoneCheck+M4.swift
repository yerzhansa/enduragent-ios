import Foundation
import ToolSupport

extension PhoneCheck {
	func m4(_ arguments: [String]) throws {
		guard arguments.count == 3, !arguments[2].isEmpty else {
			throw PhoneFailure(
				description:
					"Usage: phone-check m4 <first step> <last step> <new evidence folder>.")
		}
		guard hasOperatorTerminal else {
			throw PhoneFailure(
				description: "An operator terminal is required before approval or Send.")
		}
		let plan = try session("m4")
		let steps = try PhoneSteps(first: arguments[0], last: arguments[1], plan: plan)
		try Console.say(
			"The operator taps these steps of the Milestone 4 session on the installed TestFlight build."
		)
		let sitting = try approve(
			steps.ids, of: plan, at: place(device: "", folder: resolve(arguments[2])))
		try walk(sitting) { _ in }
	}
}
