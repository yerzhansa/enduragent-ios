#if !targetEnvironment(simulator)
	import XCTest

	@MainActor
	final class OpenRouterRecoveryPhoneCheck: XCTestCase {
		private let app = XCUIApplication(bundleIdentifier: "icu.enduragent.app")
		private var remaining = 0
		private var actions: [String] = []

		func testPickCatalogModelInSettingsAndKeepAfterRelaunch() throws {
			try prepare(sends: 0)
			let environment = ProcessInfo.processInfo.environment
			guard let id = environment["ENDURAGENT_OPENROUTER_MODEL"], !id.isEmpty,
				let name = environment["ENDURAGENT_OPENROUTER_MODEL_NAME"], !name.isEmpty,
				let provider = environment["ENDURAGENT_OPENROUTER_PROVIDER"], !provider.isEmpty
			else {
				throw PhoneRunBlocked(
					reason: "Supply the target catalog model ID, name and provider.")
			}
			let before = try progress()
			TutorialHarness.openSettings(app)
			try tap("settings.model")
			let row = element("model.choice.\(id)")
			TutorialHarness.scroll(app, to: row)
			try wait("The target catalog row is not available.") { row.isHittable && row.isEnabled }
			guard !row.isSelected else {
				throw PhoneRunBlocked(
					reason: "Choose a different catalog model to prove the change.")
			}
			XCTAssertTrue(row.label.contains(name))
			XCTAssertTrue(row.label.contains(provider))
			capture("model-before-choice")
			row.tap()
			try wait("The model choice did not save or show consent.") {
				(row.exists && row.isSelected) || element("consent.body").exists
			}
			if element("consent.body").exists {
				XCTAssertTrue(element("consent.body").label.contains(name))
				XCTAssertTrue(element("consent.body").label.contains(provider))
				capture("model-provider-consent")
				actions.append(
					"Operator reads and accepts the named provider disclosure by hand. No Send.")
				try wait("The operator did not accept the selected provider.", seconds: 180) {
					element("chat.composer").isHittable
				}
				TutorialHarness.openSettings(app)
				try tap("settings.model")
			}
			XCTAssertTrue(element("model.choice.\(id)").isSelected)
			capture("model-chosen")
			TutorialHarness.returnToChat(app)
			app.terminate()
			try launchChat()
			XCTAssertEqual(try progress(), before)
			try assertModel()
			TutorialHarness.openSettings(app)
			try tap("settings.model")
			TutorialHarness.scroll(app, to: element("model.choice.\(id)"))
			XCTAssertTrue(element("model.choice.\(id)").isSelected)
			capture("model-choice-reopened")
			TutorialHarness.returnToChat(app)
		}

		func testSelectedModelStreamsToolTurn() throws {
			try prepare(sends: 1)
			try assertModel()
			try openAccess()
			XCTAssertTrue(element("access.openRouter").isSelected)
			XCTAssertFalse(element("access.credits").isSelected)
			TutorialHarness.returnToChat(app)
			try sendToolTurn(lock: false)
			try assertModel()
		}

		func testRevokedKeyShowsOneRecoveryPrompt() throws {
			try prepare(sends: 1)
			guard
				ProcessInfo.processInfo.environment["ENDURAGENT_OPENROUTER_REVOKED"]
					== "operator-confirmed"
			else {
				throw PhoneRunBlocked(
					reason:
						"The operator must revoke the current key on OpenRouter by hand before this step."
				)
			}
			let before = try counts()
			try send("Read my intervals.icu athlete profile and explain one training metric.")
			try wait("The revoked key did not show Sign in again.", seconds: 180) {
				element("chat.access.signInAgain").isHittable
					&& element("chat.turnProgress").value as? String
						== "turns \(before + 1) settled \(before + 1)"
			}
			XCTAssertEqual(
				element("chat.transcript").buttons.matching(identifier: "chat.access.signInAgain")
					.count, 1)
			XCTAssertFalse(element("chat.turn.signInAgain").exists)
			capture("revoked-key-recovery")
			app.terminate()
			try launchChat()
			try wait("Relaunch lost the rejected-key recovery.") {
				element("chat.access.signInAgain").isHittable
			}
			XCTAssertEqual(try counts(), before + 1)
			capture("revoked-key-reopened")
		}

		func testCancelRecoveryKeepsRejectedConnection() throws {
			try prepare(sends: 0)
			let before = try progress()
			try signIn("chat.access.signInAgain", cancel: true)
			try wait("Cancelling removed the rejected-key prompt.") {
				element("chat.access.signInAgain").isHittable
			}
			XCTAssertEqual(try progress(), before)
			capture("recovery-cancelled")
		}

		func testSignInAgainRecoversWithoutLosingConversation() throws {
			try prepare(sends: 0)
			let before = try progress()
			try signIn("chat.access.signInAgain", cancel: false)
			try wait("The new connection did not clear rejection.") {
				!element("chat.access.signInAgain").exists && element("chat.composer").isHittable
			}
			XCTAssertEqual(try progress(), before)
			capture("recovery-saved")
			app.terminate()
			try launchChat()
			XCTAssertEqual(try progress(), before)
			XCTAssertFalse(element("chat.access.signInAgain").exists)
			try assertModel()
			capture("recovery-reopened")
		}

		func testSecondPhoneRequiresNamedConsentBeforeFirstRequest() throws {
			try prepare(sends: 0, consent: true)
			let environment = ProcessInfo.processInfo.environment
			guard environment["ENDURAGENT_SECOND_PHONE"] == "updated-same-apple-id",
				let modelName = environment["ENDURAGENT_OPENROUTER_MODEL_NAME"],
				let provider = environment["ENDURAGENT_OPENROUTER_PROVIDER"],
				!modelName.isEmpty, !provider.isEmpty
			else {
				throw PhoneRunBlocked(
					reason:
						"Confirm two updated phones on the same Apple ID and supply the selected model name and provider."
				)
			}
			let body = element("consent.body").label
			XCTAssertTrue(body.contains("OpenRouter"))
			XCTAssertTrue(body.contains(modelName))
			XCTAssertTrue(body.contains(provider))
			capture("second-phone-first-consent")
			try tap("consent.decline")
			try wait("Declining consent did not keep the request blocked.") {
				element("consent.resume").exists
			}
			XCTAssertFalse(element("chat.composer").exists)
			app.terminate()
			app.launch()
			try wait("The second phone lost required consent.") { element("consent.body").exists }
			capture("second-phone-consent-reopened")
		}

		func testTurnFinishesAcrossOperatorPhoneLock() throws {
			try prepare(sends: 1)
			try assertModel()
			try sendToolTurn(lock: true)
			try assertModel()
		}

		private func prepare(sends: Int, consent: Bool = false) throws {
			continueAfterFailure = false
			let environment = ProcessInfo.processInfo.environment
			guard let raw = environment["ENDURAGENT_PHONE_MESSAGE_BUDGET"], let budget = Int(raw),
				budget >= sends,
				environment["ENDURAGENT_PHONE_CHARGES_ACKNOWLEDGED"] == "yes"
			else {
				throw PhoneRunBlocked(
					reason:
						"Ask for this invocation's message budget and acknowledge OpenRouter usage charges before launch or Send."
				)
			}
			remaining = sends
			actions.append(
				"Approved budget \(budget). Planned Sends \(sends). No Try again, New conversation or calendar Add."
			)
			guard app.launchArguments.isEmpty, app.launchEnvironment.isEmpty else {
				throw PhoneRunBlocked(
					reason: "Use the plain signed phone install without fixtures or overrides.")
			}
			app.launch()
			if consent {
				try wait(
					"The operator must prepare the second phone at its first provider consent screen."
				) { element("consent.body").exists }
			} else {
				try requireChat()
			}
		}

		private func launchChat() throws {
			app.launch()
			try requireChat()
		}

		private func requireChat() throws {
			try wait(
				"The operator must unlock and prepare Chat with accepted consent.", seconds: 180
			) { app.state == .runningForeground && element("chat.composer").isHittable }
			guard !app.alerts.firstMatch.exists, !element("chat.stop").exists,
				!element("chat.preview.add").exists,
				element("chat.composer").value as? String == ""
			else {
				throw PhoneRunBlocked(reason: "An alert, draft, turn or review needs the operator.")
			}
		}

		private func openAccess() throws {
			TutorialHarness.openSettings(app)
			try tap("settings.accessMethod")
		}

		private func signIn(_ identifier: String, cancel: Bool) throws {
			try tap(identifier)
			let browsers = [
				app, XCUIApplication(bundleIdentifier: "com.apple.SafariViewService"),
				XCUIApplication(bundleIdentifier: "com.apple.AuthenticationServicesUI"),
			]
			actions.append(
				"STOP at every OpenRouter page. Operator verifies openrouter.ai and Enduragent, handles the system alert, and \(cancel ? "cancels" : "signs in and approves") by hand. Automation does not interact with any browser page."
			)
			try wait("The OpenRouter page did not appear; operator required.", seconds: 180) {
				browsers.contains { $0.webViews.firstMatch.exists }
			}
			capture(cancel ? "operator-cancel-page" : "operator-sign-in-page")
			try wait("The operator did not finish or cancel sign-in.", seconds: 180) {
				!browsers.contains { $0.webViews.firstMatch.exists }
					&& app.state == .runningForeground
			}
		}

		private func assertModel() throws {
			guard let model = ProcessInfo.processInfo.environment["ENDURAGENT_OPENROUTER_MODEL"],
				!model.isEmpty
			else {
				throw PhoneRunBlocked(
					reason: "Supply the model ID the operator selected after unit 8.3.")
			}
			TutorialHarness.openDebug(app)
			XCTAssertEqual(TutorialHarness.debugRow(app, "debug.accessModel").label, model)
			capture("selected-model")
			TutorialHarness.returnToChat(app)
		}

		private func sendToolTurn(lock: Bool) throws {
			let before = try counts()
			let question =
				"Use the intervals.icu athlete profile tool, then read my recent activities. Explain the data you found and one easy ride I could discuss with you. Do not save or change anything."
			try send(question)
			if lock {
				actions.append(
					"Operator locks the physical phone now, keeps it locked while coaching finishes, then unlocks. Home is not a lock proof."
				)
				try wait("The phone was not locked while the turn worked.", seconds: 180) {
					app.state != .runningForeground
				}
				capture("operator-locked-phone")
				try wait("The operator did not unlock the phone.", seconds: 180) {
					app.state == .runningForeground
				}
			}
			try wait("The approved tool-backed turn did not settle.", seconds: 180) {
				element("chat.turnProgress").value as? String
					== "turns \(before + 1) settled \(before + 1)"
			}
			let tools = element("chat.toolProgress").value as? String ?? ""
			XCTAssertTrue(tools.hasPrefix("turns \(before + 1) tools "))
			XCTAssertTrue(
				tools.contains("intervals_"),
				"The live turn must show a real intervals.icu tool call.")
			XCTAssertFalse(element("chat.access.signInAgain").exists)
			try assertReply(to: question)
			capture(lock ? "tool-turn-after-lock" : "streamed-tool-turn")
		}

		private func assertReply(to question: String) throws {
			let transcript = element("chat.transcript")
			for _ in 0..<12 {
				if transcript.staticTexts[question].isHittable { break }
				transcript.swipeDown(velocity: .slow)
			}
			var nodes: [(label: String, identifier: String, type: XCUIElement.ElementType)] = []
			func collect(_ snapshot: any XCUIElementSnapshot) {
				nodes.append((snapshot.label, snapshot.identifier, snapshot.elementType))
				for child in snapshot.children { collect(child) }
			}
			collect(try transcript.snapshot())
			guard
				let index = nodes.lastIndex(where: {
					$0.label == question && $0.type == .staticText
				})
			else {
				throw PhoneRunBlocked(
					reason: "The live question is not visible. Preserve the run for the operator.")
			}
			let reply = nodes[(index + 1)...]
			XCTAssertTrue(reply.contains { $0.type == .staticText && !$0.label.isEmpty })
			XCTAssertFalse(
				reply.contains {
					["chat.turn.notice", "chat.turn.tryAgain", "chat.working"].contains(
						$0.identifier)
				})
		}

		private func send(_ question: String) throws {
			guard remaining > 0 else {
				throw PhoneRunBlocked(reason: "The approved Send budget is exhausted.")
			}
			try requireChat()
			try tap("chat.composer")
			element("chat.composer").typeText(question)
			guard element("chat.composer").value as? String == question else {
				throw PhoneRunBlocked(reason: "The phone did not preserve the message.")
			}
			remaining -= 1
			actions.append("Send \(question). Planned Sends remaining \(remaining).")
			try tap("chat.send")
		}

		private func counts() throws -> Int {
			let fields = try progress().split(separator: " ")
			guard fields.count == 4, let turns = Int(fields[1]), let settled = Int(fields[3]),
				turns == settled
			else { throw PhoneRunBlocked(reason: "The conversation is not settled.") }
			return turns
		}

		private func progress() throws -> String {
			guard let progress = element("chat.turnProgress").value as? String else {
				throw PhoneRunBlocked(reason: "Turn progress is unavailable.")
			}
			return progress
		}

		private func element(_ id: String) -> XCUIElement { TutorialHarness.named(app, id) }

		private func tap(_ id: String) throws {
			try wait("Control unavailable: \(id).") {
				element(id).isHittable && element(id).isEnabled
			}
			element(id).tap()
		}

		private func wait(_ reason: String, seconds: TimeInterval = 25, until ready: () -> Bool)
			throws
		{
			let deadline = ProcessInfo.processInfo.systemUptime + seconds
			while !ready() {
				guard ProcessInfo.processInfo.systemUptime < deadline else {
					capture("deadline")
					throw PhoneRunBlocked(reason: reason)
				}
				RunLoop.current.run(until: Date(timeIntervalSinceNow: 0.05))
			}
		}

		private func capture(_ name: String) {
			let shot = XCTAttachment(screenshot: XCUIScreen.main.screenshot())
			shot.name = "openrouter-" + name
			shot.lifetime = .keepAlways
			add(shot)
			let transcript = XCTAttachment(string: app.debugDescription)
			transcript.name = "openrouter-" + name + "-transcript"
			transcript.lifetime = .keepAlways
			add(transcript)
		}

		override func tearDown() {
			let record = XCTAttachment(string: actions.joined(separator: "\n"))
			record.name = "openrouter-actions"
			record.lifetime = .keepAlways
			add(record)
		}
	}
#endif
