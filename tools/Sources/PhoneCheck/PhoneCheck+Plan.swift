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
		let planned = plan.planned(steps.ids)
		let named = steps.ids.joined(separator: ", ")
		let folder = resolve(arguments[3])
		let ledgerPath = ledgerFile(of: plan)
		let ledger = try readLedger(at: ledgerPath, of: plan)
		try Console.say(
			"PlanPhoneRun runs \(named) of the plan phone session and plans \(planned) message actions. Each Send, Try again and New conversation is one, and New conversation also saves memory. They spend the phone's Credits or its OpenRouter account. Milestone 5 has spent \(ledger.spent) of \(plan.cap)."
		)
		try say(steps, of: plan)
		let invocation = try PhoneBudget.approve(
			try ask(
				"Approve this invocation's message budget, at least \(planned) and at most \(plan.cap - ledger.spent), acknowledging those charges. Enter a whole number or stop: "
			), steps: steps.ids, plan: plan, spent: ledger.spent)
		guard
			try ask(
				"Prepare the unlocked phone in English on the seeded test account, in the conversation the step before left, with no draft. Type ready: "
			).hasSameUnits(as: "ready")
		else {
			throw PhoneFailure(description: "The phone setup was not confirmed. Stop.")
		}
		try requireFreeDisk()
		try makeNewFolder(folder)
		try write(
			JSONValue.keyed([
				"steps": .array(steps.ids.map(JSONValue.string)),
				"plannedActions": .number(Double(planned)),
				"approvedBudget": .number(Double(invocation.budget)),
				"spentBefore": .number(Double(ledger.spent)), "chargesAcknowledged": .bool(true),
			]).indentedText, to: NodePath.join(folder, "approval.json"))
		try book(ledger.recording(invocation, actions: nil), at: ledgerPath)
		let build = "/tmp/enduragent-dd/M5-8-2-phone"
		let bundle = NodePath.join(folder, "phone.xcresult")
		let proof = Result {
			try xcodebuild(
				[
					"test", "-project", "apps/ios/Enduragent.xcodeproj", "-scheme",
					"EnduragentPhone", "-configuration", "Debug", "-sdk", "iphoneos",
					"-destination", "platform=iOS,id=\(arguments[2])", "-derivedDataPath", build,
					"-parallel-testing-enabled", "NO", "-resultBundlePath", bundle,
					"-only-testing:EnduragentPhoneTests/PlanPhoneRun/testPlanPhoneRun",
					"ENDURAGENT_PHONE_MESSAGE_BUDGET=\(invocation.budget)",
					"\(PlannedPhoneStep.variable)=\(PlannedPhoneStep.text(plan.plannedSteps(steps.ids)))",
				], log: NodePath.join(folder, "phone.log"),
				failure: "The plan phone run failed. Stop and report \(folder)/phone.log.")
		}
		let attachments = NodePath.join(folder, "attachments")
		let recorded = ledger.recording(
			invocation, actions: try planActions(of: bundle, exportedTo: attachments))
		try book(recorded, at: ledgerPath)
		try Console.say(
			"This invocation spent \(recorded.invocations.last?.spent ?? invocation.budget) message actions. Milestone 5 has spent \(recorded.spent) of \(plan.cap)."
		)
		if FileManager.default.fileExists(atPath: build) {
			try FileManager.default.removeItem(atPath: build)
		}
		try proof.get()
		try keepPassingSummary(
			of: bundle, in: folder, unreadable: "Cannot read the plan phone result. Stop.",
			failed: "PlanPhoneRun did not pass exactly once. Stop.")
		try Console.say(
			"Inspect every screenshot and the actions log in \(attachments). After step 5, check that the intervals.icu website shows exactly one new workout. After step 6, confirm VoiceOver read the card's title, name, goal, length, each phase and the replaces line before Save plan and Cancel."
		)
		let verdict = try ask(
			"Type pass only after that inspection, otherwise describe the failed check: ")
		try write("\(verdict)\n", to: NodePath.join(folder, "verdict.txt"))
		guard verdict.hasSameUnits(as: "pass") else {
			throw PhoneFailure(
				description:
					"Operator review did not pass. Stop. A new invocation needs a new budget.")
		}
	}

	private func planActions(of bundle: String, exportedTo folder: String) throws -> String? {
		do {
			try makeNewFolder(folder)
			try exportAttachments(
				of: bundle, to: folder, failure: "Cannot export the plan phone attachments.")
			let manifest = try JSONValue.parse(
				String(
					decoding: try FileSystem.read(NodePath.join(folder, "manifest.json")),
					as: UTF8.self))
			guard let file = try PlanPhoneBudget.actionsFile(in: manifest) else {
				try Console.complain(
					"The result bundle has no single \(PlanPhoneBudget.actionsAttachment) log. Recording the whole budget as spent."
				)
				return nil
			}
			return String(decoding: try FileSystem.read(NodePath.join(folder, file)), as: UTF8.self)
		} catch {
			try Console.complain(
				"Cannot read the message actions: \(Console.text(of: error)). Recording the whole budget as spent."
			)
			return nil
		}
	}
}
