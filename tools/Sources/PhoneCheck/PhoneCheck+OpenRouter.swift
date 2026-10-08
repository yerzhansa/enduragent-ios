import Foundation
import ToolSupport

private struct OpenRouterStep {
	let test: String
	let sends: Int
	var needsModel = false
}

extension PhoneCheck {
	private static let steps: KeyValuePairs<String, OpenRouterStep> = [
		"signin": OpenRouterStep(
			test: "OpenRouterSignInPhoneCheck/testHTTPSCallbackSavesConnection", sends: 0),
		"pick": OpenRouterStep(
			test: "OpenRouterRecoveryPhoneCheck/testPickCatalogModelInSettingsAndKeepAfterRelaunch",
			sends: 0, needsModel: true),
		"tool": OpenRouterStep(
			test: "OpenRouterRecoveryPhoneCheck/testSelectedModelStreamsToolTurn", sends: 1,
			needsModel: true),
		"revoked": OpenRouterStep(
			test: "OpenRouterRecoveryPhoneCheck/testRevokedKeyShowsOneRecoveryPrompt", sends: 1),
		"cancel": OpenRouterStep(
			test: "OpenRouterRecoveryPhoneCheck/testCancelRecoveryKeepsRejectedConnection", sends: 0
		),
		"recover": OpenRouterStep(
			test: "OpenRouterRecoveryPhoneCheck/testSignInAgainRecoversWithoutLosingConversation",
			sends: 0, needsModel: true),
		"second-consent": OpenRouterStep(
			test:
				"OpenRouterRecoveryPhoneCheck/testSecondPhoneRequiresNamedConsentBeforeFirstRequest",
			sends: 0),
		"locked": OpenRouterStep(
			test: "OpenRouterRecoveryPhoneCheck/testTurnFinishesAcrossOperatorPhoneLock", sends: 1,
			needsModel: true),
	]

	func openRouter(_ arguments: [String]) throws {
		guard arguments.count == 3, !arguments[1].isEmpty, !arguments[2].isEmpty,
			let scenario = Self.steps.first(where: { $0.key.hasSameUnits(as: arguments[0]) })?.value
		else {
			throw PhoneFailure(
				description:
					"Usage: phone-check openrouter <\(Self.steps.map(\.key).joined(separator: "|"))> <device id> <new evidence folder>."
			)
		}
		guard hasOperatorTerminal else {
			throw PhoneFailure(
				description:
					"An operator terminal is required before approval, build, launch or Send.")
		}
		let step = arguments[0]
		let folder = resolve(arguments[2])
		let build = "/tmp/enduragent-dd/U8-3-phone"
		try Console.say(
			"This \(step) invocation plans \(scenario.sends) live Sends. Sends spend Credits or use the connected OpenRouter account and may incur charges. No Try again, New conversation, purchase or calendar Add. A stopped invocation needs a fresh budget."
		)
		try Console.say(
			"At every OpenRouter page automation stops. Handle system alerts by hand, verify openrouter.ai and Enduragent, then sign in, revoke or cancel by hand. No script enters credentials or operates a browser page. Keep screenshots and transcripts local."
		)
		let budget = try ask(
			"Approve this invocation's message budget, at least \(scenario.sends), acknowledging automatic usage charges. Enter a whole number or stop: "
		)
		let approved = JavaScriptNumber.parse(budget)
		guard try patterns.test(#"^(0|[1-9]\d*)$"#, budget), approved <= 9_007_199_254_740_991,
			approved >= Double(scenario.sends)
		else {
			throw PhoneFailure(
				description: "No sufficient budget approved. Stop before build, launch or Send.")
		}
		var environment: [(key: String, value: String)] = [
			("ENDURAGENT_PHONE_MESSAGE_BUDGET", budget),
			("ENDURAGENT_PHONE_CHARGES_ACKNOWLEDGED", "yes"),
		]
		var model: String?
		func askNameAndProvider(_ name: String, _ provider: String, missing: String) throws {
			let modelName = try ask(name).trimmedAsJavaScript
			environment.append(("ENDURAGENT_OPENROUTER_MODEL_NAME", modelName))
			let hostingProvider = try ask(provider).trimmedAsJavaScript
			environment.append(("ENDURAGENT_OPENROUTER_PROVIDER", hostingProvider))
			guard !modelName.isEmpty, !hostingProvider.isEmpty else {
				throw PhoneFailure(description: missing)
			}
		}
		if scenario.needsModel {
			let answer = try ask(
				step == "pick"
					? "Enter a different catalog model ID to choose in Settings, with no Send: "
					: "Enter the exact saved model ID confirmed by the pick step: "
			).trimmedAsJavaScript
			guard !answer.isEmpty else {
				throw PhoneFailure(description: "No model choice confirmed. Stop.")
			}
			environment.append(("ENDURAGENT_OPENROUTER_MODEL", answer))
			model = answer
		}
		if step == "pick" {
			try askNameAndProvider(
				"Target catalog model display name: ", "Target catalog model hosting provider: ",
				missing: "The catalog model name and provider were not supplied. Stop.")
			try Console.say(
				"The proof taps only that catalog row. If consent appears, read the named model and provider, then accept by hand. The choice must stay marked after relaunch. Nothing is sent."
			)
		}
		if step == "revoked" {
			guard
				try ask(
					"Revoke only the current test key on OpenRouter by hand. Confirm the correct key and account. Type revoked to proceed: "
				).hasSameUnits(as: "revoked")
			else {
				throw PhoneFailure(description: "Revocation was not confirmed. Stop.")
			}
			environment.append(("ENDURAGENT_OPENROUTER_REVOKED", "operator-confirmed"))
		}
		if step == "second-consent" {
			guard
				try ask(
					"Use two updated signed phones on the same Apple ID. Leave the receiver at its first consent for the synced OpenRouter choice. Type ready to confirm: "
				).hasSameUnits(as: "ready")
			else {
				throw PhoneFailure(description: "Second-phone setup was not confirmed. Stop.")
			}
			environment.append(("ENDURAGENT_SECOND_PHONE", "updated-same-apple-id"))
			try askNameAndProvider(
				"Selected model display name on the source phone: ",
				"Named hosting provider on the source phone: ",
				missing: "The synced consent recipient was not supplied. Stop.")
		}
		if step == "locked" {
			try Console.say(
				"When the turn starts, physically lock the iPhone. Keep it locked until coaching finishes, then unlock it. Inspect the lock screenshot afterward. Home does not prove locked Keychain access."
			)
		}
		guard
			try ask(
				"Prepare English, the plain signed install, no draft, no unfinished turn or workout review, and the required screen. Read this step in verify-ios. Type ready: "
			).hasSameUnits(as: "ready")
		else {
			throw PhoneFailure(description: "The phone setup was not confirmed. Stop.")
		}
		try requireFreeDisk()
		try makeNewFolder(folder)
		try write(
			JSONValue.keyed([
				"step": .string(step), "sendsPlanned": .number(Double(scenario.sends)),
				"approvedBudget": .number(approved), "chargesAcknowledged": .bool(true),
				"model": model.map(JSONValue.string) ?? .undefined,
			]).indentedText, to: NodePath.join(folder, "approval.json"))
		let bundle = NodePath.join(folder, "phone.xcresult")
		let proof = Result {
			try xcodebuild(
				[
					"test", "-project", "apps/ios/Enduragent.xcodeproj", "-scheme",
					"EnduragentPhone",
					"-configuration", "Debug", "-sdk", "iphoneos", "-destination",
					"platform=iOS,id=\(arguments[1])", "-derivedDataPath", build,
					"-parallel-testing-enabled", "NO", "-resultBundlePath", bundle,
					"-only-testing:EnduragentPhoneTests/\(scenario.test)",
				] + environment.map { "\($0.key)=\($0.value)" },
				log: NodePath.join(folder, "phone.log"),
				failure:
					"The phone proof failed. Stop and report \(folder)/phone.log, Sends used and phone state."
			)
		}
		if FileManager.default.fileExists(atPath: build) {
			try FileManager.default.removeItem(atPath: build)
		}
		try proof.get()
		try keepPassingSummary(
			of: bundle, in: folder, unreadable: "Cannot read the phone result. Stop.",
			failed: "The selected phone test did not pass exactly once. Stop.")
		try exportAttachments(
			of: bundle, to: NodePath.join(folder, "attachments"),
			failure: "Cannot export phone attachments. Stop.")
		try Console.say(
			"Inspect every screenshot and transcript in \(folder)/attachments. Verify the streamed reply, real tool call, retained earlier messages and selected model. For lock, verify an actual locked screen and a completed turn after unlocking. For sync, verify the selected model and provider match the source phone and consent precedes any Send. Check OpenRouter usage and Credits for accidental fallback. Keep missing evidence pending."
		)
		let verdict = try ask(
			"Type pass only after that inspection, otherwise describe the failed criterion: ")
		try write("\(verdict)\n", to: NodePath.join(folder, "verdict.txt"))
		guard verdict.hasSameUnits(as: "pass") else {
			throw PhoneFailure(
				description:
					"Operator review did not pass. Stop. A new invocation needs a new budget.")
		}
		try Console.say(
			"Evidence saved in \(folder). Continue with the next manual checkpoint in verify-ios using a fresh invocation and budget."
		)
	}
}
