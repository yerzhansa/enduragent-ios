#if !targetEnvironment(simulator)
	import EnduragentCoach
	import XCTest

	extension PlanPhoneRun {
		static var granFondoDate: String {
			let formatter = DateFormatter()
			formatter.locale = Locale(identifier: "en_US_POSIX")
			formatter.dateFormat = "MMMM d, yyyy"
			return formatter.string(from: Date(timeIntervalSinceNow: 84 * 86_400))
		}

		@MainActor
		func element(_ identifier: String) -> XCUIElement {
			app.descendants(matching: .any).matching(identifier: identifier).firstMatch
		}

		@MainActor
		func newest(_ identifier: String) -> XCUIElement {
			let matches = element("chat.transcript").descendants(matching: .any)
				.matching(identifier: identifier)
			return matches.element(boundBy: max(matches.count - 1, 0))
		}

		@MainActor
		func part(_ identifier: String, of card: XCUIElement) -> XCUIElement {
			card.descendants(matching: .any).matching(identifier: identifier).firstMatch
		}

		@MainActor
		func shot(_ name: String) {
			let attachment = XCTAttachment(screenshot: XCUIScreen.main.screenshot())
			attachment.name = name
			attachment.lifetime = .keepAlways
			add(attachment)
		}

		@MainActor
		func wait(_ reason: String, seconds: TimeInterval, until condition: () throws -> Bool)
			throws
		{
			let deadline = ProcessInfo.processInfo.systemUptime + seconds
			while try !condition() {
				guard ProcessInfo.processInfo.systemUptime < deadline else {
					shot("deadline")
					log.append("Stopped: \(reason)")
					throw PhoneRunBlocked(reason: reason)
				}
				RunLoop.current.run(until: Date(timeIntervalSinceNow: 0.25))
			}
		}

		@MainActor
		func pause(_ seconds: TimeInterval) throws {
			let end = ProcessInfo.processInfo.systemUptime + seconds
			try wait("The pause did not end.", seconds: seconds + 5) {
				ProcessInfo.processInfo.systemUptime >= end
			}
		}

		@MainActor
		func requireChat() throws {
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
		func launchPlain() throws {
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
		func relaunch() throws {
			app.terminate()
			XCTAssertEqual(app.state, .notRunning)
			log.append("Ended the app.")
			try launchPlain()
		}

		@MainActor
		func tap(_ identifier: String) throws {
			try wait("Control unavailable: \(identifier).", seconds: 15) {
				let control = element(identifier)
				return control.exists && control.isEnabled && control.isHittable
			}
			element(identifier).tap()
			log.append("Tapped \(identifier).")
		}

		@MainActor
		func spendMessage(_ identifier: String) throws {
			try requireChat()
			guard messagesRemaining > 0 else {
				throw PhoneRunBlocked(reason: "The approved message budget is exhausted.")
			}
			messagesRemaining -= 1
			log.append("Message action \(identifier). Budget remaining \(messagesRemaining).")
			try tap(identifier)
		}

		@MainActor
		func compose(_ text: String, besideReview: Bool = false) throws -> Int {
			try requireChat()
			let before = try PhoneSample(app)
			guard !before.has("chat.stop"), besideReview || !before.has("chat.preview.add") else {
				throw PhoneRunBlocked(reason: "An earlier turn or workout review is still open.")
			}
			let composer = element("chat.composer")
			let value = composer.value as? String ?? ""
			guard value.isEmpty || value == composer.placeholderValue else {
				throw PhoneRunBlocked(reason: "The operator's draft is still in the composer.")
			}
			composer.tap()
			composer.typeText(text)
			guard composer.value as? String == text else {
				throw PhoneRunBlocked(reason: "Typing did not preserve the message.")
			}
			return before.turns + 1
		}

		@MainActor
		func send(_ question: String, besideReview: Bool = false) throws -> Int {
			let turns = try compose(question, besideReview: besideReview)
			try spendMessage("chat.send")
			return turns
		}

		@MainActor
		func settle(_ question: String, turns: Int) throws {
			try wait("The reply to \"\(question)\" did not settle.", seconds: 420) {
				let current = try PhoneSample(app, after: question)
				guard current.turns == turns, current.settled == turns, !current.has("chat.stop")
				else { return false }
				if current.tail.contains(where: { $0.identifier == "chat.turn.tryAgain" }) {
					let tryAgain = newest("chat.turn.tryAgain")
					if tryAgain.isEnabled, tryAgain.isHittable {
						try spendMessage("chat.turn.tryAgain")
						try wait("Try again did not start the turn again.", seconds: 30) {
							try !PhoneSample(app, after: question).tail.contains {
								$0.identifier == "chat.turn.tryAgain"
							}
						}
					}
					return false
				}
				if let notice = current.tail.first(where: {
					["chat.turn.notice", "chat.turn.planSaveNotice"].contains($0.identifier)
				}) {
					shot("turn-notice")
					throw PhoneRunBlocked(reason: "The turn ended with \"\(notice.label)\".")
				}
				return current.replyLength > 0
			}
		}

		@MainActor
		func expectNoCard(after question: String) throws {
			try pause(3)
			let tail = try PhoneSample(app, after: question).tail
			XCTAssertFalse(
				tail.contains { $0.identifier.hasPrefix("chat.planSave.") },
				"No plan-save card follows \"\(question)\".")
			XCTAssertFalse(element(Self.save).exists)
		}

		@MainActor
		func expectTools(_ names: [String]) throws {
			let observed = (element("chat.toolProgress").value as? String ?? "")
				.split(separator: " ").map(String.init)
			log.append("Observed tools: \(observed.dropFirst(3).joined(separator: " ")).")
			for name in names {
				XCTAssertTrue(observed.dropFirst(3).contains(name), "The turn called \(name).")
			}
		}

		@MainActor
		func expectReply(to question: String, naming plans: [String]) throws {
			let reply = try PhoneSample(app, after: question).replyLines.joined(separator: "\n")
			for plan in plans {
				XCTAssertTrue(
					reply.localizedCaseInsensitiveContains(plan), "The reply names \(plan).")
			}
		}

		@MainActor
		func waitingCard(
			after request: String, replacing previous: String?, docked: Bool = true
		) throws -> String {
			try wait("No waiting plan-save card after \"\(request)\".", seconds: 60) {
				let card = newest(Self.card)
				return card.exists && !part("chat.planSave.state", of: card).exists
					&& newest("chat.planSave.title").isHittable
			}
			if docked {
				try wait("Save plan did not appear with the card's title on screen.", seconds: 30) {
					element(Self.save).isHittable
				}
				XCTAssertTrue(
					newest("chat.planSave.title").isHittable, "The card's title is on screen.")
			}
			let sample = try PhoneSample(app, after: request)
			if sample.nodes.contains(where: {
				$0.inTranscript && $0.type == .staticText && $0.label == request
			}) {
				XCTAssertTrue(
					sample.tail.contains { $0.identifier == Self.card },
					"The card waits under its turn.")
			}
			let card = newest(Self.card)
			XCTAssertFalse(part("chat.planSave.state", of: card).exists, "The card waits.")
			let replaces = part("chat.planSave.replaces", of: card)
			if let previous {
				XCTAssertTrue(replaces.exists, "The card names the plan it replaces.")
				XCTAssertEqual(
					replaces.label,
					phrasebook.say(Catalog.chatPlanSaveReplaces, ["name": previous]))
			} else {
				XCTAssertFalse(replaces.exists, "The first card replaces no plan.")
			}
			let name = part("chat.planSave.name", of: card).label
			log.append("Card waits: \(name).")
			return name
		}

		@MainActor
		func state(of plan: String) -> String? {
			let card = newest(Self.card)
			let name = part("chat.planSave.name", of: card)
			let state = part("chat.planSave.state", of: card)
			guard card.exists, name.exists, name.label == plan, state.exists else { return nil }
			return state.label
		}

		@MainActor
		func reach(_ identifier: String) throws -> XCUIElement {
			let control = element(identifier)
			let transcript = element("chat.transcript")
			let armed = ProcessInfo.processInfo.systemUptime + 5
			while !control.isHittable, ProcessInfo.processInfo.systemUptime < armed {
				RunLoop.current.run(until: Date(timeIntervalSinceNow: 0.25))
			}
			for _ in 0..<12 where !control.isHittable {
				let upper = transcript.coordinate(withNormalizedOffset: CGVector(dx: 0.5, dy: 0.35))
				let lower = transcript.coordinate(withNormalizedOffset: CGVector(dx: 0.5, dy: 0.65))
				if control.exists, control.frame.midY < transcript.frame.midY {
					upper.press(forDuration: 0.1, thenDragTo: lower)
				} else {
					lower.press(forDuration: 0.1, thenDragTo: upper)
				}
			}
			guard control.isHittable else {
				shot("unreachable")
				throw PhoneRunBlocked(reason: "\(identifier) cannot be reached.")
			}
			return control
		}

		@MainActor
		func decide(_ identifier: String, reading key: CatalogKey, _ plan: String) throws {
			try reach(identifier).tap()
			log.append("Tapped \(identifier).")
			try expectEnded(plan, reading: key)
		}

		@MainActor
		func expectEnded(_ plan: String, reading key: CatalogKey) throws {
			let expected = phrasebook.say(key)
			try wait("The card for \(plan) did not read \"\(expected)\".", seconds: 60) {
				state(of: plan) == expected && !element(Self.save).exists
					&& !element(Self.cancel).exists
			}
			log.append("Card reads \(expected)")
		}

		@MainActor
		func currentPlan() throws -> String {
			if let savedPlan { return savedPlan }
			let saved = phrasebook.say(Catalog.chatPlanSaveSaved)
			let transcript = element("chat.transcript")
			for _ in 0..<12 {
				let cards = transcript.descendants(matching: .any).matching(identifier: Self.card)
					.allElementsBoundByIndex
				if let card = cards.last(where: {
					let state = part("chat.planSave.state", of: $0)
					return state.exists && state.label == saved
				}) {
					let name = part("chat.planSave.name", of: card).label
					log.append("Saved plan read from the conversation: \(name).")
					savedPlan = name
					return name
				}
				transcript.swipeDown(velocity: .slow)
			}
			throw PhoneRunBlocked(
				reason:
					"No saved plan card in this conversation. Resume from the step that saves one."
			)
		}

		@MainActor
		func spokenParts() throws -> [String] {
			var identifiers: [String] = []
			func walk(_ snapshot: any XCUIElementSnapshot) {
				if snapshot.identifier.hasPrefix("chat.planSave.") {
					identifiers.append(snapshot.identifier)
				}
				for child in snapshot.children { walk(child) }
			}
			walk(try element("chat.transcript").snapshot())
			log.append("Spoken parts: \(identifiers.joined(separator: " ")).")
			return identifiers
		}

		@MainActor
		func expectSpoken(_ order: [String], from start: String, optional: Set<String> = [])
			throws
		{
			let spoken = try spokenParts()
			guard let first = spoken.lastIndex(of: start) else {
				throw PhoneRunBlocked(reason: "\(start) is not on screen.")
			}
			let card = Array(spoken[first...])
			for part in order where !optional.contains(part) {
				XCTAssertTrue(card.contains(part), "VoiceOver reads \(part).")
			}
			let present = order.filter { card.contains($0) }
			for (earlier, later) in zip(present, present.dropFirst()) {
				XCTAssertLessThan(
					card.lastIndex(of: earlier) ?? 0, card.firstIndex(of: later) ?? 0,
					"VoiceOver reads \(earlier) before \(later).")
			}
		}
	}
#endif
