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
		let planned = plan.planned(steps.ids)
		let folder = resolve(arguments[2])
		let ledgerPath = ledgerFile(of: plan)
		let ledger = try readLedger(at: ledgerPath, of: plan)
		try Console.say(
			"The operator taps \(steps.ids.joined(separator: ", ")) of the Milestone 4 session on the installed TestFlight build. They plan \(planned) message actions. Each Send, Try again and New conversation is one, and they spend the phone's Credits or its OpenRouter account. Milestone 4 has spent \(ledger.spent) of \(plan.cap)."
		)
		try say(steps, of: plan)
		let invocation = try PhoneBudget.approve(
			try ask(
				"Approve this invocation's message budget, at least \(planned) and at most \(plan.cap - ledger.spent), acknowledging those charges. Enter a whole number or stop: "
			), steps: steps.ids, plan: plan, spent: ledger.spent)
		try makeNewFolder(folder)
		try write(
			JSONValue.keyed([
				"steps": .array(steps.ids.map(JSONValue.string)),
				"plannedActions": .number(Double(planned)),
				"approvedBudget": .number(Double(invocation.budget)),
				"spentBefore": .number(Double(ledger.spent)), "chargesAcknowledged": .bool(true),
			]).indentedText, to: NodePath.join(folder, "approval.json"))
		try book(ledger.recording(invocation, actions: nil), at: ledgerPath)
		var verdicts: [String] = []
		for id in steps.ids {
			let verdict = try ask(
				"After \(id), type pass, fail <check> or blocked <reason>: ")
			verdicts.append("\(id)\t\(verdict)")
			try write(
				verdicts.map { $0 + "\n" }.joined(), to: NodePath.join(folder, "verdicts.tsv"))
			guard verdict.hasSameUnits(as: "pass") else {
				throw PhoneFailure(
					description:
						"\(id) did not pass. Stop. A new invocation needs a new budget.")
			}
		}
	}
}
