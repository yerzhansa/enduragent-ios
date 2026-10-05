import ToolSupport

extension PhoneCheck {
	func language(_ arguments: [String]) throws {
		guard arguments.count == 2, !arguments[0].isEmpty, !arguments[1].isEmpty,
			hasOperatorTerminal
		else {
			throw PhoneFailure(
				description:
					"Usage: phone-check language <device id> <new evidence folder>. An operator terminal is required."
			)
		}
		let device = arguments[0]
		let folder = resolve(arguments[1])
		try Console.say(
			"LanguageReplyCheck sends four live messages. They spend real Credits or use the connected OpenRouter account. It changes the saved language preference and leaves Automatic selected. No Try again, New conversation or calendar Add."
		)
		let budget = try ask(
			"Approve this invocation's Send budget, at least 4, acknowledging those charges. Enter a whole number or stop: "
		)
		let approved = JavaScriptNumber.parse(budget)
		guard try patterns.test(#"^[1-9]\d*$"#, budget), approved <= 9_007_199_254_740_991,
			approved >= 4
		else {
			throw PhoneFailure(
				description:
					"No sufficient message budget approved. Stop before build, launch or Send.")
		}
		let prepared = try ask(
			"Prepare the unlocked phone with consent accepted, model access working, no draft or open review, and preferred languages Russian, French, English. Type ready to confirm: "
		)
		guard prepared.hasSameUnits(as: "ready") else {
			throw PhoneFailure(description: "The operator did not confirm the phone setup.")
		}
		try requireFreeDisk()
		try makeNewFolder(folder)
		try write(
			JSONValue.keyed([
				"approvedSendBudget": .number(approved), "sendsPlanned": .number(4),
				"preferredLanguages": .array([.string("ru"), .string("fr"), .string("en")]),
				"chargesAcknowledged": .bool(true),
			]).indentedText, to: NodePath.join(folder, "approval.json"))
		let bundle = NodePath.join(folder, "phone.xcresult")
		try xcodebuild(
			[
				"test", "-project", "apps/ios/Enduragent.xcodeproj", "-scheme", "EnduragentPhone",
				"-configuration", "Debug", "-sdk", "iphoneos", "-destination",
				"platform=iOS,id=\(device)",
				"-derivedDataPath", "/tmp/enduragent-dd/U9-2-phone", "-parallel-testing-enabled",
				"NO",
				"-resultBundlePath", bundle,
				"-only-testing:EnduragentPhoneTests/LanguageReplyCheck/testFrenchRepliesAfterFixedAndAutomaticRelaunch",
				"ENDURAGENT_PHONE_MESSAGE_BUDGET=\(budget)",
			], log: NodePath.join(folder, "phone.log"),
			failure: "The phone proof failed. Stop and report \(folder)/phone.log.")
		try keepPassingSummary(
			of: bundle, in: folder, unreadable: "Cannot read the phone test result. Stop.",
			failed: "The phone capture did not pass exactly once. Stop.")
		try exportAttachments(
			of: bundle, to: NodePath.join(folder, "attachments"),
			failure: "Cannot export the phone attachments. Stop.")
		try Console.say(
			"Inspect all reply pages and transcripts in \(folder)/attachments. Fixed French after relaunch must answer the English question in French. Automatic after relaunch must answer English, Japanese and /review in French. A notice, empty reply or any non-French generated prose fails this proof."
		)
		let verdict = try ask(
			"Type pass only if every live reply meets that rule, otherwise describe the failure: ")
		try write("\(verdict)\n", to: NodePath.join(folder, "verdict.txt"))
		guard verdict.hasSameUnits(as: "pass") else {
			throw PhoneFailure(
				description:
					"The live language proof failed. Stop and report it. A new invocation needs a new budget."
			)
		}
		try Console.say(
			"Operator-reviewed language evidence is saved in \(folder). The phone remains on Automatic."
		)
	}
}
