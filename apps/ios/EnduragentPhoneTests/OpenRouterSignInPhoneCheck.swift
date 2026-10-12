#if !targetEnvironment(simulator)
	import XCTest

	@MainActor
	final class OpenRouterSignInPhoneCheck: XCTestCase {
		private let app = XCUIApplication(bundleIdentifier: "icu.enduragent.app")

		func testHTTPSCallbackSavesConnection() throws {
			try prepare(minimumBudget: 0)
			let conversation = try progress()
			try openAccess()
			guard element("access.credits").isSelected,
				!element("access.openRouter").isSelected
			else {
				throw PhoneRunBlocked(
					reason:
						"Select Credits before this run so the callback must change the access method."
				)
			}
			try signInWaitingForOperator(cancel: false)
			XCTAssertTrue(element("access.openRouter").isSelected)
			XCTAssertFalse(element("access.credits").isSelected)
			XCTAssertFalse(element("access.notice").exists)
			capture("openrouter-callback-saved")
			TutorialHarness.returnToChat(app)
			XCTAssertEqual(try progress(), conversation)
			app.terminate()
			try launchPlain()
			XCTAssertEqual(try progress(), conversation)
			try openAccess()
			XCTAssertTrue(element("access.openRouter").isSelected)
			XCTAssertFalse(element("access.credits").isSelected)
			capture("openrouter-callback-reopened")
			TutorialHarness.returnToChat(app)
		}

		func testCancelKeepsPreviousAccessForNextTurn() throws {
			try prepare(minimumBudget: 1)
			let conversation = try progress()
			try openAccess()
			let credits = element("access.credits").isSelected
			let openRouter = element("access.openRouter").isSelected
			guard credits != openRouter else {
				throw PhoneRunBlocked(reason: "Prepare one working access method before this run.")
			}
			capture("openrouter-before-cancel")
			try signInWaitingForOperator(cancel: true)
			XCTAssertEqual(element("access.credits").isSelected, credits)
			XCTAssertEqual(element("access.openRouter").isSelected, openRouter)
			capture("openrouter-cancel-kept-access")
			TutorialHarness.returnToChat(app)
			XCTAssertEqual(try progress(), conversation)
			try sendOneTurn()
			app.terminate()
			try launchPlain()
			try openAccess()
			XCTAssertEqual(element("access.credits").isSelected, credits)
			XCTAssertEqual(element("access.openRouter").isSelected, openRouter)
			capture("openrouter-cancel-access-reopened")
			TutorialHarness.returnToChat(app)
		}

		private func prepare(minimumBudget: Int) throws {
			continueAfterFailure = false
			guard let raw = ProcessInfo.processInfo.environment["ENDURAGENT_PHONE_MESSAGE_BUDGET"],
				let budget = Int(raw), budget >= minimumBudget
			else {
				throw PhoneRunBlocked(
					reason:
						"Ask for this invocation's message budget before launch. Callback needs zero Sends; cancel needs one live Send through the previous access."
				)
			}
			attach(
				"Approved message budget \(budget). Planned Sends \(minimumBudget). No Try again, New conversation or calendar Add.",
				name: "openrouter-budget")
			try launchPlain()
		}

		@MainActor private var composerIsEmpty: Bool {
			let composer = element("chat.composer")
			return ["", composer.placeholderValue].contains(composer.value as? String ?? "")
		}

		private func launchPlain() throws {
			guard app.launchArguments.isEmpty, app.launchEnvironment.isEmpty else {
				throw PhoneRunBlocked(
					reason: "Use a plain phone launch without fixtures or overrides.")
			}
			app.launch()
			try wait("The operator must prepare the unlocked phone in the conversation.") {
				app.state == .runningForeground && element("chat.composer").isHittable
			}
			let springboard = XCUIApplication(bundleIdentifier: "com.apple.springboard")
			guard !app.alerts.firstMatch.exists, !springboard.alerts.firstMatch.exists,
				!element("chat.stop").exists, !element("chat.preview.add").exists,
				!element("chat.preview.notice").exists,
				composerIsEmpty
			else {
				throw PhoneRunBlocked(
					reason: "An alert, unfinished turn, review or draft needs the operator.")
			}
			capture("openrouter-plain-launch")
		}

		private func openAccess() throws {
			TutorialHarness.openSettings(app)
			try tap("settings.accessMethod")
			try wait("The access choices did not open.") {
				element("access.openRouter").isHittable && element("access.credits").exists
			}
		}

		private func signInWaitingForOperator(cancel: Bool) throws {
			try tap("access.openRouter")
			attach(
				"Operator handles the system permission alert. At openrouter.ai, \(cancel ? "cancel the system sheet" : "sign in and approve Enduragent") by hand. Automation enters no credential and taps nothing in the browser.",
				name: "openrouter-operator-step")
			let browsers = [
				app,
				XCUIApplication(bundleIdentifier: "com.apple.SafariViewService"),
				XCUIApplication(bundleIdentifier: "com.apple.AuthenticationServicesUI"),
			]
			try wait(
				"The OpenRouter page did not appear. Preserve the run for the operator.",
				seconds: 180
			) {
				browsers.contains { $0.webViews.firstMatch.exists }
			}
			capture(cancel ? "openrouter-cancel-page" : "openrouter-authorization-page")
			try wait(
				"The operator's callback or cancel did not dismiss the system sheet.", seconds: 180
			) {
				let choice = element("access.openRouter")
				return choice.isHittable && choice.isEnabled
					&& !browsers.contains { $0.webViews.firstMatch.exists }
			}
		}

		private func sendOneTurn() throws {
			let before = try progress()
			let fields = before.split(separator: " ")
			guard fields.count == 4, let turns = Int(fields[1]), let settled = Int(fields[3]),
				turns == settled, composerIsEmpty
			else {
				throw PhoneRunBlocked(
					reason: "The conversation is not ready for the one approved Send.")
			}
			let question = "What is an endurance ride?"
			let composer = element("chat.composer")
			composer.tap()
			composer.typeText(question)
			guard composer.value as? String == question else {
				throw PhoneRunBlocked(reason: "Typing did not preserve the message.")
			}
			attach(
				"Sending one live message. No further Send is permitted in this invocation.",
				name: "openrouter-send")
			try tap("chat.send")
			try wait("The previous access did not complete the next turn.", seconds: 180) {
				element("chat.turnProgress").value as? String
					== "turns \(turns + 1) settled \(turns + 1)"
			}
			let transcript = element("chat.transcript")
			for _ in 0..<12 {
				if transcript.staticTexts[question].isHittable { break }
				transcript.swipeDown(velocity: .slow)
			}
			var tail: [PhoneNode] = []
			func walk(_ snapshot: any XCUIElementSnapshot, inside: Bool) {
				let here = inside || snapshot.identifier == "chat.transcript"
				if here {
					tail.append(
						PhoneNode(
							identifier: snapshot.identifier, label: snapshot.label,
							value: "", type: snapshot.elementType, inTranscript: true))
				}
				for child in snapshot.children { walk(child, inside: here) }
			}
			walk(try app.snapshot(), inside: false)
			guard
				let index = tail.lastIndex(where: { $0.type == .staticText && $0.label == question }
				)
			else {
				throw PhoneRunBlocked(
					reason: "The sent message is missing from the visible conversation.")
			}
			let reply = tail[(index + 1)...]
			XCTAssertTrue(reply.contains { $0.type == .staticText && !$0.label.isEmpty })
			XCTAssertFalse(
				reply.contains {
					["chat.turn.notice", "chat.turn.tryAgain"].contains($0.identifier)
				})
			capture("openrouter-cancel-next-turn")
		}

		private func progress() throws -> String {
			guard let value = element("chat.turnProgress").value as? String else {
				throw PhoneRunBlocked(reason: "The conversation has no readable turn progress.")
			}
			return value
		}

		private func element(_ id: String) -> XCUIElement { TutorialHarness.named(app, id) }

		private func tap(_ id: String) throws {
			try wait("Control unavailable: \(id).") {
				let control = element(id)
				return control.exists && control.isEnabled && control.isHittable
			}
			element(id).tap()
		}

		private func wait(_ reason: String, seconds: TimeInterval = 25, until ready: () -> Bool)
			throws
		{
			let deadline = ProcessInfo.processInfo.systemUptime + seconds
			while !ready() {
				guard ProcessInfo.processInfo.systemUptime < deadline else {
					capture("openrouter-deadline")
					throw PhoneRunBlocked(reason: reason)
				}
				RunLoop.current.run(until: Date(timeIntervalSinceNow: 0.05))
			}
		}

		private func capture(_ name: String) {
			let attachment = XCTAttachment(screenshot: XCUIScreen.main.screenshot())
			attachment.name = name
			attachment.lifetime = .keepAlways
			add(attachment)
		}

		private func attach(_ text: String, name: String) {
			let attachment = XCTAttachment(string: text)
			attachment.name = name
			attachment.lifetime = .keepAlways
			add(attachment)
		}
	}
#endif
