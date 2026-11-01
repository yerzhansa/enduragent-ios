import Foundation
import ToolSupport

extension PhoneCheck {
	func plan(_ arguments: [String]) throws {
		guard arguments.count == 4, !arguments[2].isEmpty, !arguments[3].isEmpty else {
			throw PhoneFailure(
				description:
					"Usage: phone-check plan <first step> <last step> <device id> <new evidence folder>."
			)
		}
		guard hasOperatorTerminal else {
			throw PhoneFailure(
				description:
					"An operator terminal is required before approval, build, launch or Send.")
		}
		let plan = try session("plan")
		let steps = try PhoneSteps(first: arguments[0], last: arguments[1], plan: plan)
		try Console.say(
			"PlanPhoneRun runs these steps of the plan phone session. New conversation also saves memory."
		)
		let place = place(device: arguments[2], folder: resolve(arguments[3]))
		guard
			try ask(
				"Prepare the unlocked phone in English on the seeded test account, in the conversation the step before left, with no draft. Type ready: "
			).hasSameUnits(as: "ready")
		else {
			throw PhoneFailure(description: "The phone setup was not confirmed. Stop.")
		}
		let sitting = try approve(steps.ids, of: plan, at: place)
		try walk(sitting) { _ in
			try Console.say(
				"Inspect every screenshot and the actions log in \(place.folder). After step 5, check that the intervals.icu website shows exactly one new workout."
			)
		}
	}
}
