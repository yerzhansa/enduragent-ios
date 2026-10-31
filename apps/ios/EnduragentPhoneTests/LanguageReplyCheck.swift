#if !targetEnvironment(simulator)
	import XCTest

	@MainActor
	final class LanguageReplyCheck: XCTestCase {
		private let app = XCUIApplication(bundleIdentifier: "icu.enduragent.app")
		private var remaining = 0
		private var actions: [String] = []

		private func attachActions() {
			let attachment = XCTAttachment(string: actions.joined(separator: "\n"))
			attachment.name = "language-actions"
			attachment.lifetime = .keepAlways
			add(attachment)
		}

		private func element(_ id: String) -> XCUIElement {
			app.descendants(matching: .any).matching(identifier: id).firstMatch
		}

		private func capture(_ name: String) {
			let shot = XCTAttachment(screenshot: XCUIScreen.main.screenshot())
			shot.name = name
			shot.lifetime = .keepAlways
			add(shot)
			let transcript = XCTAttachment(string: app.debugDescription)
			transcript.name = name + "-transcript"
			transcript.lifetime = .keepAlways
			add(transcript)
		}

		private func wait(_ reason: String, seconds: TimeInterval = 20, until ready: () -> Bool)
			throws
		{
			let deadline = ProcessInfo.processInfo.systemUptime + seconds
			while !ready() {
				guard ProcessInfo.processInfo.systemUptime < deadline else {
					capture("language-deadline")
					throw PhoneRunBlocked(reason: reason)
				}
				RunLoop.current.run(until: Date(timeIntervalSinceNow: 0.05))
			}
		}

		private func tap(_ id: String) throws {
			try wait("Control unavailable: \(id).") {
				let control = element(id)
				return control.exists && control.isEnabled && control.isHittable
			}
			element(id).tap()
			actions.append("Tapped \(id).")
		}

		private func launchPlain() throws {
			guard app.launchArguments.isEmpty, app.launchEnvironment.isEmpty else {
				throw PhoneRunBlocked(
					reason: "Use a plain phone launch, without fixtures or overrides.")
			}
			app.launch()
			try wait("The operator must prepare the unlocked phone in the conversation.") {
				app.state == .runningForeground && element("chat.composer").isHittable
			}
			let springboard = XCUIApplication(bundleIdentifier: "com.apple.springboard")
			guard !app.alerts.firstMatch.exists, !springboard.alerts.firstMatch.exists,
				!element("chat.stop").exists, !element("chat.preview.add").exists,
				!element("chat.preview.notice").exists
			else {
				throw PhoneRunBlocked(
					reason: "An alert, earlier turn or workout review needs the operator.")
			}
			let composer = element("chat.composer")
			guard composer.value as? String == "" else {
				throw PhoneRunBlocked(reason: "The operator's draft is still in the composer.")
			}
		}

		private func returnToChat() throws {
			for _ in 0..<4 {
				if element("chat.settings").isHittable { return }
				let bar = app.navigationBars.firstMatch
				let title = bar.identifier
				bar.buttons.firstMatch.tap()
				try wait("Back did not leave \(title).") {
					app.navigationBars.firstMatch.identifier != title
				}
			}
			throw PhoneRunBlocked(reason: "Settings did not return to the conversation.")
		}

		private func chooseAndReopen(_ id: String) throws {
			try tap("chat.settings")
			try tap("settings.language")
			try tap("language.choice.\(id)")
			try wait("Language \(id) was not saved.") {
				element("language.choice.\(id)").isSelected
					&& !element("language.saveFailed").exists
			}
			capture("language-\(id)-chosen")
			try tap("language.close")
			try returnToChat()
			app.terminate()
			try launchPlain()
			XCTAssertEqual(element("chat.composer").placeholderValue, "Écris à ton coach")
			try tap("chat.settings")
			try tap("settings.language")
			XCTAssertTrue(element("language.choice.\(id)").isSelected)
			XCTAssertEqual(element("language.choice.automatic").label, "Automatique")
			capture("language-\(id)-restored")
			try tap("language.close")
			try returnToChat()
		}

		private func sendAndCapture(_ question: String, name: String) throws {
			guard remaining > 0, !element("chat.stop").exists else {
				throw PhoneRunBlocked(reason: "No budget remains or a turn is still working.")
			}
			let progress = element("chat.turnProgress")
			let fields = (progress.value as? String ?? "").split(separator: " ")
			guard fields.count == 4, let turns = Int(fields[1]), let settled = Int(fields[3]),
				turns == settled
			else {
				throw PhoneRunBlocked(
					reason: "The conversation has unreadable or unfinished turn progress.")
			}
			let composer = element("chat.composer")
			guard composer.value as? String == "" else {
				throw PhoneRunBlocked(reason: "The operator's draft is still in the composer.")
			}
			composer.tap()
			composer.typeText(question)
			guard composer.value as? String == question else {
				throw PhoneRunBlocked(reason: "Typing did not preserve the message.")
			}
			remaining -= 1
			actions.append("Send \(question). Budget remaining \(remaining).")
			try tap("chat.send")
			try wait("The live reply did not settle.", seconds: 180) {
				progress.value as? String == "turns \(turns + 1) settled \(turns + 1)"
			}
			XCTAssertFalse(element("chat.stop").exists)
			XCTAssertEqual(composer.placeholderValue, "Écris à ton coach")
			let transcript = element("chat.transcript")
			for page in 0..<12 {
				capture("\(name)-page-\(page)")
				if transcript.staticTexts[question].isHittable {
					let reply = try replyNodes(after: question)
					guard reply.contains(where: { $0.type == .staticText && !$0.label.isEmpty }),
						!reply.contains(where: {
							["chat.turn.notice", "chat.turn.tryAgain"].contains($0.identifier)
						})
					else {
						throw PhoneRunBlocked(
							reason: "The live turn has no reply or ended with a notice.")
					}
					return
				}
				transcript.swipeDown(velocity: .slow)
			}
			throw PhoneRunBlocked(
				reason: "The reply exceeded twelve pages. Report incomplete evidence.")
		}

		private func replyNodes(after question: String) throws -> [PhoneNode] {
			var nodes: [PhoneNode] = []
			func walk(_ snapshot: any XCUIElementSnapshot, inside: Bool) {
				let here = inside || snapshot.identifier == "chat.transcript"
				if here {
					nodes.append(
						PhoneNode(
							identifier: snapshot.identifier, label: snapshot.label,
							value: snapshot.value as? String ?? "", type: snapshot.elementType,
							inTranscript: true))
				}
				for child in snapshot.children { walk(child, inside: here) }
			}
			walk(try app.snapshot(), inside: false)
			guard
				let lastQuestion = nodes.lastIndex(where: {
					$0.type == .staticText && $0.label == question
				})
			else {
				throw PhoneRunBlocked(
					reason: "The latest message is missing from the captured transcript.")
			}
			return Array(nodes[(lastQuestion + 1)...])
		}

		func testFrenchRepliesAfterFixedAndAutomaticRelaunch() throws {
			continueAfterFailure = false
			defer { attachActions() }
			guard let raw = ProcessInfo.processInfo.environment["ENDURAGENT_PHONE_MESSAGE_BUDGET"],
				let budget = Int(raw), budget >= 4
			else {
				throw PhoneRunBlocked(
					reason:
						"Ask for this invocation's message budget before launch. Four Sends spend Credits or use OpenRouter."
				)
			}
			remaining = budget
			actions.append(
				"Approved budget \(budget). No Try again, New conversation or calendar Add.")
			try launchPlain()
			try chooseAndReopen("fr")
			try sendAndCapture("What is an endurance ride?", name: "language-fixed-english")
			try chooseAndReopen("automatic")
			for (name, question) in [
				("english", "What is a recovery ride?"),
				("japanese", "テンポ走とは何ですか？"),
				("review", "/review"),
			] {
				try sendAndCapture(question, name: "language-automatic-\(name)")
			}
			actions.append("Operator must inspect every live reply and confirm French prose.")
			capture("language-left-on-phone")
		}
	}
#endif
