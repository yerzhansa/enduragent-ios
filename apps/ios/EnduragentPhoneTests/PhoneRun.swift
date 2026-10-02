#if !targetEnvironment(simulator)
	import XCTest

	struct PhoneRunBlocked: Error {
		let reason: String
	}

	struct PhoneNode: Sendable {
		let identifier: String
		let label: String
		let value: String
		let type: XCUIElement.ElementType
		let inTranscript: Bool
	}

	struct PhoneSample {
		let nodes: [PhoneNode]
		let tail: [PhoneNode]
		let turns: Int
		let settled: Int

		var working: Bool { tail.contains { $0.identifier == "chat.working" } }
		var replyLength: Int {
			tail.filter {
				$0.type == .staticText && ["", "chat.transcript"].contains($0.identifier)
			}
			.map(\.label.count).reduce(0, +)
		}
		func has(_ identifier: String) -> Bool { nodes.contains { $0.identifier == identifier } }
	}

	final class PhoneRun: XCTestCase {
		@MainActor private var app: XCUIApplication {
			XCUIApplication(bundleIdentifier: "icu.enduragent.app")
		}
		private var messagesRemaining = 0
		private var addsRemaining = 1
		private var log: [String] = []

		override func tearDown() {
			let attachment = XCTAttachment(string: log.joined(separator: "\n"))
			attachment.name = "phone-run-actions"
			attachment.lifetime = .keepAlways
			add(attachment)
		}

		@MainActor
		private func shot(_ name: String) {
			let attachment = XCTAttachment(screenshot: XCUIScreen.main.screenshot())
			attachment.name = name
			attachment.lifetime = .keepAlways
			add(attachment)
		}

		@MainActor
		private func element(_ identifier: String) -> XCUIElement {
			app.descendants(matching: .any).matching(identifier: identifier).firstMatch
		}

		@MainActor
		private func sample(_ question: String = "") throws -> PhoneSample {
			var nodes: [PhoneNode] = []
			func walk(_ snapshot: any XCUIElementSnapshot, inside: Bool) {
				if snapshot.elementType == .keyboard { return }
				let here = inside || snapshot.identifier == "chat.transcript"
				nodes.append(
					PhoneNode(
						identifier: snapshot.identifier, label: snapshot.label,
						value: snapshot.value as? String ?? "", type: snapshot.elementType,
						inTranscript: here))
				for child in snapshot.children { walk(child, inside: here) }
			}
			walk(try app.snapshot(), inside: false)
			guard let progress = nodes.first(where: { $0.identifier == "chat.turnProgress" }) else {
				throw PhoneRunBlocked(
					reason: "No turn progress on screen. The operator must open the conversation.")
			}
			let fields = progress.value.split(separator: " ")
			guard fields.count == 4, let turns = Int(fields[1]), let settled = Int(fields[3]) else {
				throw PhoneRunBlocked(reason: "Unreadable turn progress.")
			}
			let transcript = nodes.filter(\.inTranscript)
			let index = transcript.lastIndex { $0.type == .staticText && $0.label == question }
			let tail = index.map { Array(transcript[($0 + 1)...]) } ?? []
			return PhoneSample(nodes: nodes, tail: tail, turns: turns, settled: settled)
		}

		@MainActor
		private func wait(
			_ reason: String, seconds: TimeInterval = 180, until condition: () throws -> Bool
		) throws {
			let deadline = ProcessInfo.processInfo.systemUptime + seconds
			while try !condition() {
				guard ProcessInfo.processInfo.systemUptime < deadline else {
					shot("deadline")
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
				]
				.contains(where: { element($0).exists })
			else {
				shot("operator-required")
				throw PhoneRunBlocked(
					reason:
						"Stop. The operator must unlock, sign in, or accept consent on the phone.")
			}
		}

		@MainActor
		private func launchPlain() throws {
			XCTAssertTrue(app.launchArguments.isEmpty)
			XCTAssertTrue(app.launchEnvironment.isEmpty)
			app.launch()
			try wait("The plain launch did not reach the foreground.", seconds: 25) {
				app.state == .runningForeground
			}
			shot("plain-launch")
			try requireChat()
		}

		@MainActor
		private func tap(_ identifier: String) throws {
			try wait("Control unavailable: \(identifier).", seconds: 15) {
				let control = element(identifier)
				return control.exists && control.isEnabled && control.isHittable
			}
			element(identifier).tap()
			log.append("Tapped \(identifier).")
		}

		@MainActor
		private func spendMessage(_ identifier: String) throws {
			try requireChat()
			guard messagesRemaining > 0 else {
				throw PhoneRunBlocked(reason: "The approved message budget is exhausted.")
			}
			messagesRemaining -= 1
			log.append("Message action \(identifier). Budget remaining \(messagesRemaining).")
			try tap(identifier)
		}

		@MainActor
		private func send(_ question: String) throws -> Int {
			try requireChat()
			let before = try sample()
			guard !before.has("chat.stop"), !before.has("chat.preview.add") else {
				throw PhoneRunBlocked(reason: "An earlier turn or workout review is still open.")
			}
			let composer = element("chat.composer")
			let value = composer.value as? String ?? ""
			guard value.isEmpty || value == composer.placeholderValue else {
				throw PhoneRunBlocked(reason: "The operator's draft is still in the composer.")
			}
			composer.tap()
			composer.typeText(question)
			guard composer.value as? String == question else {
				throw PhoneRunBlocked(reason: "Typing did not preserve the question.")
			}
			try spendMessage("chat.send")
			return before.turns + 1
		}

		@MainActor
		private func settle(_ question: String, turns: Int) throws {
			try wait("The reply did not settle.") {
				let current = try sample(question)
				return current.turns == turns && current.settled == turns
					&& !current.has("chat.stop")
					&& current.replyLength > 0
					&& !current.tail.contains {
						$0.identifier == "chat.turn.notice" || $0.identifier == "chat.turn.tryAgain"
					}
			}
			let current = try sample(question)
			XCTAssertGreaterThan(current.replyLength, 0)
			XCTAssertFalse(
				current.tail.contains {
					$0.identifier == "chat.turn.notice" || $0.identifier == "chat.turn.tryAgain"
				})
		}

		@MainActor
		private func writing(_ question: String) throws {
			try wait("No partial reply appeared before the turn finished.", seconds: 100) {
				let current = try sample(question)
				if !current.tail.isEmpty, current.turns == current.settled {
					throw PhoneRunBlocked(reason: "The reply finished before the interruption.")
				}
				return current.working && current.replyLength > 0
			}
		}

		@MainActor
		private func returnToChat() throws {
			for _ in 0..<4 {
				if element("chat.settings").isHittable { return }
				let bar = app.navigationBars.firstMatch
				let title = bar.identifier
				let back = bar.buttons.firstMatch
				try wait("The Back button is unavailable.") { back.isHittable }
				back.tap()
				try wait("Back did not leave \(title).") {
					app.navigationBars.firstMatch.identifier != title
				}
			}
			guard element("chat.settings").isHittable else {
				throw PhoneRunBlocked(reason: "Back did not return to the conversation.")
			}
		}

		@MainActor
		private func history() throws -> Set<String> {
			try tap("chat.history")
			let rows = app.descendants(matching: .any).matching(
				NSPredicate(format: "identifier BEGINSWITH %@", "history.row."))
			try wait("History has no archived conversation.", seconds: 15) {
				rows.firstMatch.exists
			}
			shot("history")
			let identifiers = Set(rows.allElementsBoundByIndex.map { $0.identifier })
			rows.firstMatch.tap()
			try wait("The archived conversation did not open.", seconds: 15) {
				element("archive.readOnly").exists
			}
			shot("archive-read-only")
			try returnToChat()
			return identifiers
		}

		@MainActor
		private func credits(_ name: String) throws {
			try tap("chat.settings")
			try tap("settings.credits")
			try wait("Credits has no balance.", seconds: 25) { element("credits.balance").exists }
			log.append("\(name): \(element("credits.balance").label)")
			shot(name)
			try returnToChat()
		}

		@MainActor
		func testPhoneRun() throws {
			continueAfterFailure = false
			guard
				let value = ProcessInfo.processInfo.environment["ENDURAGENT_PHONE_MESSAGE_BUDGET"],
				let budget = Int(value), budget >= 9
			else {
				throw PhoneRunBlocked(
					reason:
						"Ask the operator for this run's message budget. The full run needs nine Send or Try again actions."
				)
			}
			messagesRemaining = budget
			log.append("Approved message budget \(budget). Add budget 1.")
			try launchPlain()
			XCTAssertGreaterThan(try sample().turns, 0)
			_ = try history()
			try credits("credits-before")
			try normalReply()
			try stopAndTryAgain()
			try homeDuringReply()
			try killAndTryAgain()
			try workoutAndCancel()
			try newConversation()
			try credits("credits-after")
			XCTAssertEqual(addsRemaining, 0)
			shot("left-on-phone")
		}

		@MainActor
		private func normalReply() throws {
			let question = "What should I focus on in training this week?"
			let turns = try send(question)
			try writing(question)
			let first = try sample(question).replyLength
			try wait("The reply did not grow while streaming.") {
				let current = try sample(question)
				return current.working && current.replyLength > first
			}
			shot("reply-streaming")
			try settle(question, turns: turns)
			shot("reply-finished")
		}

		@MainActor
		private func stopAndTryAgain() throws {
			let question =
				"Explain in detail, week by week, how an 8 week base training block should progress."
			let turns = try send(question)
			try writing(question)
			let stop = element("chat.stop").frame
			XCUIApplication(bundleIdentifier: "com.apple.springboard").coordinate(
				withNormalizedOffset: .zero
			)
			.withOffset(CGVector(dx: stop.midX, dy: stop.midY)).tap()
			log.append("Tapped Stop during the partial reply.")
			try wait("Stop did not offer Try again.", seconds: 40) {
				element("chat.turn.tryAgain").exists && !element("chat.stop").exists
			}
			XCTAssertGreaterThan(try sample(question).replyLength, 0)
			XCTAssertTrue(element("chat.turn.notice").exists)
			shot("stopped-partial")
			try spendMessage("chat.turn.tryAgain")
			try settle(question, turns: turns)
			shot("try-again-finished")
		}

		@MainActor
		private func homeDuringReply() throws {
			let question = "In one sentence, what is a tempo ride?"
			let turns = try send(question)
			XCUIDevice.shared.press(.home)
			shot("home-during-reply")
			let deadline = ProcessInfo.processInfo.systemUptime + 20
			try wait("The Home interval did not end.", seconds: 25) {
				ProcessInfo.processInfo.systemUptime >= deadline
			}
			app.activate()
			try requireChat()
			XCTAssertEqual(try sample(question).settled, turns)
			try settle(question, turns: turns)
			XCTAssertTrue(element("chat.turn.finishedWhileLocked").exists)
			shot("reply-after-home")
		}

		@MainActor
		private func killAndTryAgain() throws {
			let question = "Explain in detail how to pace a 100 km ride, hour by hour."
			let turns = try send(question)
			try writing(question)
			app.terminate()
			XCTAssertEqual(app.state, .notRunning)
			try launchPlain()
			try wait("The interrupted turn has no Try again.", seconds: 15) {
				element("chat.turn.tryAgain").exists
			}
			XCTAssertTrue(element("chat.turn.notice").exists)
			shot("killed-turn-reopened")
			try spendMessage("chat.turn.tryAgain")
			try settle(question, turns: turns)
		}

		@MainActor
		private func workoutAndCancel() throws {
			let question = "Create one 45 minute easy endurance ride for tomorrow."
			let turns = try send(question)
			try settle(question, turns: turns)
			try wait("The workout review has no Add.", seconds: 15) {
				element("chat.preview.add").isHittable
			}
			XCTAssertTrue(element("chat.preview.cancel").isEnabled)
			shot("workout-before-add")
			try requireChat()
			guard addsRemaining == 1 else {
				throw PhoneRunBlocked(reason: "The one Add was already used.")
			}
			addsRemaining = 0
			try tap("chat.preview.add")
			try wait("Add did not finish.", seconds: 60) { !element("chat.preview.add").exists }
			XCTAssertTrue(element("chat.note").exists)
			shot("workout-after-one-add")
			let cancelled = "Create one 30 minute recovery spin for the day after tomorrow."
			let next = try send(cancelled)
			try settle(cancelled, turns: next)
			try tap("chat.preview.cancel")
			try wait("Cancel did not remove the card.", seconds: 15) {
				!element("chat.preview.cancel").exists
			}
			try launchPlain()
			XCTAssertFalse(element("chat.preview.add").exists)
			shot("cancel-survives-relaunch")
		}

		@MainActor
		private func newConversation() throws {
			let earlier = try history()
			try tap("chat.newConversation")
			XCTAssertTrue(element("chat.composer").isEnabled)
			try wait("New conversation did not finish.", seconds: 25) {
				try sample().turns == 0 && element("chat.welcome").exists
			}
			let question = "What is a good warm up before intervals?"
			let turns = try send(question)
			try settle(question, turns: turns)
			XCTAssertEqual(turns, 1)
			let later = try history()
			XCTAssertEqual(later.subtracting(earlier).count, 1)
		}
	}
#endif
