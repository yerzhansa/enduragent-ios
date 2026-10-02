#if !targetEnvironment(simulator)
	import XCTest

	final class ChoicesInConversationCheck: XCTestCase {
		@MainActor private var app: XCUIApplication {
			XCUIApplication(bundleIdentifier: "icu.enduragent.app")
		}
		private var messagesRemaining = 0
		private var actions: [String] = []

		override func tearDown() {
			attach(actions.joined(separator: "\n"), named: "choices-actions")
		}

		private func attach(_ text: String, named name: String) {
			let attachment = XCTAttachment(string: text)
			attachment.name = name
			attachment.lifetime = .keepAlways
			add(attachment)
		}

		@MainActor
		private func capture(_ name: String) {
			let attachment = XCTAttachment(screenshot: XCUIScreen.main.screenshot())
			attachment.name = name
			attachment.lifetime = .keepAlways
			add(attachment)
			attach(app.debugDescription, named: name + "-transcript")
		}

		@MainActor
		private func element(_ identifier: String) -> XCUIElement {
			app.descendants(matching: .any).matching(identifier: identifier).firstMatch
		}

		@MainActor
		private func wait(_ reason: String, seconds: TimeInterval, until ready: () throws -> Bool)
			throws
		{
			let deadline = ProcessInfo.processInfo.systemUptime + seconds
			while try !ready() {
				guard ProcessInfo.processInfo.systemUptime < deadline else {
					capture("choices-deadline")
					throw PhoneRunBlocked(reason: reason)
				}
				RunLoop.current.run(until: Date(timeIntervalSinceNow: 0.05))
			}
		}

		@MainActor
		private func requireChat() throws {
			let springboard = XCUIApplication(bundleIdentifier: "com.apple.springboard")
			guard app.state == .runningForeground, !app.alerts.firstMatch.exists,
				!springboard.alerts.firstMatch.exists, element("chat.composer").exists,
				![
					"consent.accept", "consent.resume", "notice.continue", "connect.apiKey",
					"starter.start",
				].contains(where: { element($0).exists })
			else {
				capture("choices-operator-required")
				throw PhoneRunBlocked(reason: "Stop. The operator must prepare the unlocked phone.")
			}
			guard !element("chat.stop").exists, !element("chat.preview.add").exists,
				!element("chat.preview.notice").exists
			else {
				capture("choices-open-work")
				throw PhoneRunBlocked(reason: "An earlier turn or workout review is still open.")
			}
		}

		@MainActor
		private func tap(_ identifier: String) throws {
			try wait("Control unavailable: \(identifier).", seconds: 15) {
				let control = element(identifier)
				return control.exists && control.isEnabled && control.isHittable
			}
			element(identifier).tap()
			actions.append("Tapped \(identifier).")
		}

		@MainActor
		private func progress() throws -> (turns: Int, settled: Int) {
			let value = element("chat.turnProgress").value as? String ?? ""
			let fields = value.split(separator: " ")
			guard fields.count == 4, let turns = Int(fields[1]), let settled = Int(fields[3]) else {
				throw PhoneRunBlocked(reason: "Unreadable turn progress.")
			}
			return (turns, settled)
		}

		@MainActor
		private func transcriptState() throws -> String {
			var rows: [String] = []
			func walk(_ node: any XCUIElementSnapshot, inside: Bool) {
				let here = inside || node.identifier == "chat.transcript"
				if here {
					rows.append(
						"\(node.identifier) \(node.label) \(node.value ?? "") \(node.frame)")
				}
				for child in node.children { walk(child, inside: here) }
			}
			walk(try app.snapshot(), inside: false)
			return rows.joined(separator: "\n")
		}

		@MainActor
		func testCaptureOneMessage() throws {
			continueAfterFailure = false
			let environment = ProcessInfo.processInfo.environment
			guard let rawBudget = environment["ENDURAGENT_PHONE_MESSAGE_BUDGET"],
				let budget = Int(rawBudget), budget >= 1,
				let question = environment["ENDURAGENT_CHOICES_MESSAGE"], !question.isEmpty,
				let model = environment["ENDURAGENT_CHOICES_MODEL"], !model.isEmpty,
				let fresh = environment["ENDURAGENT_CHOICES_FRESH"], ["0", "1"].contains(fresh)
			else {
				throw PhoneRunBlocked(
					reason:
						"Ask the operator for this invocation's message budget before sending. Use the saved choices helper."
				)
			}
			messagesRemaining = budget
			actions.append("Approved budget \(budget). Credits model \(model). Fresh \(fresh).")
			XCTAssertTrue(app.launchArguments.isEmpty)
			XCTAssertTrue(app.launchEnvironment.isEmpty)
			app.launch()
			try wait("Plain launch did not reach the foreground.", seconds: 25) {
				app.state == .runningForeground && element("chat.composer").exists
			}
			capture("choices-plain-launch")
			try requireChat()
			let composer = element("chat.composer")
			let draft = composer.value as? String ?? ""
			guard draft.isEmpty || draft == composer.placeholderValue else {
				throw PhoneRunBlocked(reason: "The operator's draft is still in the composer.")
			}
			if fresh == "1" {
				try tap("chat.newConversation")
				try wait("New conversation did not finish.", seconds: 180) {
					try progress().turns == 0 && element("chat.welcome").exists
				}
				capture("choices-fresh-conversation")
			}
			let before = try progress()
			guard before.turns == before.settled else {
				throw PhoneRunBlocked(reason: "An earlier turn has not settled.")
			}
			composer.tap()
			composer.typeText(question)
			guard composer.value as? String == question else {
				throw PhoneRunBlocked(reason: "Typing did not preserve the message.")
			}
			try requireChat()
			guard messagesRemaining > 0 else {
				throw PhoneRunBlocked(reason: "The approved message budget is exhausted.")
			}
			messagesRemaining -= 1
			actions.append("Send: \(question). Budget remaining \(messagesRemaining).")
			try tap("chat.send")
			try wait("The live reply did not settle.", seconds: 180) {
				let current = try progress()
				guard current.turns == before.turns + 1, current.settled == current.turns else {
					return false
				}
				capture("choices-settled")
				guard !element("chat.turn.notice").exists, !element("chat.turn.tryAgain").exists
				else {
					throw PhoneRunBlocked(
						reason: "The live turn ended with a notice. Stop this run.")
				}
				return true
			}
			try requireChat()
			let transcript = element("chat.transcript")
			for page in 0..<12 {
				let before = try transcriptState()
				capture("choices-reply-page-\(page)")
				transcript.swipeDown()
				if try transcriptState() == before { return }
			}
			throw PhoneRunBlocked(
				reason:
					"The transcript exceeded twelve capture pages. Stop and report incomplete evidence."
			)
		}
	}
#endif
