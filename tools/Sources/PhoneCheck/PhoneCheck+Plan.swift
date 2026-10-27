import Foundation
import ToolSupport

extension PhoneCheck {
	private static var planLedger: String {
		NodePath.join(NSHomeDirectory(), "Library/Logs/enduragent-m5/PHONE/messages.tsv")
	}

	private static let planSetup: [Int: String] = [
		1: "The phone starts with no saved plan and no plan-save card.",
		5:
			"Auto-Lock is Never: step 5 waits eleven minutes with the app in the foreground. Step 5 makes the session's one calendar Approve.",
		6: "Largest text size and VoiceOver are on in iOS Settings for step 6, and off after it.",
	]

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
		let steps = try PlanPhoneSteps(first: arguments[0], last: arguments[1])
		let folder = resolve(arguments[3])
		let ledgerPath = Self.planLedger
		let ledger = try PlanPhoneLedger(
			text: FileManager.default.fileExists(atPath: ledgerPath)
				? String(decoding: try FileSystem.read(ledgerPath), as: UTF8.self) : nil)
		try Console.say(
			"PlanPhoneRun runs steps \(steps.text) of the plan phone session and plans \(steps.planned) message actions. Each Send, Try again and New conversation is one, and New conversation also saves memory. They spend the phone's Credits or its OpenRouter account. Milestone 5 has spent \(ledger.spent) of \(PlanPhoneBudget.cap)."
		)
		for step in steps.first...steps.last {
			if let setup = Self.planSetup[step] { try Console.say("Step \(step): \(setup)") }
		}
		let invocation = try PlanPhoneBudget.approve(
			try ask(
				"Approve this invocation's message budget, at least \(steps.planned) and at most \(PlanPhoneBudget.cap - ledger.spent), acknowledging those charges. Enter a whole number or stop: "
			), for: steps, after: ledger)
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
				"steps": .string(steps.text), "plannedActions": .number(Double(steps.planned)),
				"approvedBudget": .number(Double(invocation.budget)),
				"spentBefore": .number(Double(ledger.spent)), "chargesAcknowledged": .bool(true),
			]).indentedText, to: NodePath.join(folder, "approval.json"))
		try FileManager.default.createDirectory(
			atPath: NodePath.dirname(ledgerPath), withIntermediateDirectories: true)
		try write(ledger.recording(invocation, actions: nil).text, to: ledgerPath)
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
					"ENDURAGENT_PLAN_PHONE_STEPS=\(steps.text)",
				], log: NodePath.join(folder, "phone.log"),
				failure: "The plan phone run failed. Stop and report \(folder)/phone.log.")
		}
		let attachments = NodePath.join(folder, "attachments")
		let recorded = ledger.recording(
			invocation, actions: try planActions(of: bundle, exportedTo: attachments))
		try write(recorded.text, to: ledgerPath)
		try Console.say(
			"This invocation spent \(recorded.invocations.last?.spent ?? invocation.budget) message actions. Milestone 5 has spent \(recorded.spent) of \(PlanPhoneBudget.cap)."
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
