#if !targetEnvironment(simulator)
	import EnduragentCoach
	import XCTest

	final class PlanPhoneRun: XCTestCase {
		static let plannedActions = [2, 1, 2, 2, 3, 1, 2]
		static let card = "chat.planSave.card"
		static let save = "chat.planSave.save"
		static let cancel = "chat.planSave.cancel"

		@MainActor var app: XCUIApplication {
			XCUIApplication(bundleIdentifier: "icu.enduragent.app")
		}
		let phrasebook = CatalogPhrasebook(tag: .en)
		var messagesRemaining = 0
		var approvesRemaining = 1
		var savedPlan: String?
		var log: [String] = []

		override func tearDown() {
			let attachment = XCTAttachment(string: log.joined(separator: "\n"))
			attachment.name = "plan-phone-actions"
			attachment.lifetime = .keepAlways
			add(attachment)
		}

		@MainActor
		func testPlanPhoneRun() throws {
			continueAfterFailure = false
			let environment = ProcessInfo.processInfo.environment
			let bounds = (environment["ENDURAGENT_PLAN_PHONE_STEPS"] ?? "")
				.split(separator: "-", omittingEmptySubsequences: false).map { Int($0) }
			guard bounds.count == 2, let first = bounds[0], let last = bounds[1], first >= 1,
				first <= last, last <= Self.plannedActions.count
			else {
				throw PhoneRunBlocked(reason: "Run PlanPhoneRun through phone-check plan.")
			}
			let steps = first...last
			let planned = Self.plannedActions[(steps.lowerBound - 1)...(steps.upperBound - 1)]
				.reduce(0, +)
			guard let value = environment["ENDURAGENT_PHONE_MESSAGE_BUDGET"],
				let budget = Int(value), budget >= planned, budget <= 30
			else {
				throw PhoneRunBlocked(
					reason:
						"Ask the operator for this invocation's message budget through phone-check plan. Steps \(first)-\(last) need \(planned) message actions, and the milestone's cap is 30."
				)
			}
			messagesRemaining = budget
			log.append("Approved message budget \(budget) for steps \(first)-\(last).")
			try launchPlain()
			guard !element(Self.save).exists, !element("chat.preview.add").exists else {
				throw PhoneRunBlocked(reason: "A plan-save card or workout review is still open.")
			}
			for step in steps {
				log.append("Step \(step) starts.")
				switch step {
				case 1: try draftWithoutSaving()
				case 2: try feasibility()
				case 3: try saveSurvivesRelaunch()
				case 4: try replaceAndAskHistory()
				case 5: try expireBesideReview()
				case 6: try saveAtLargestText()
				default: try cancelCarriedCard()
				}
				shot("step-\(step)-done")
			}
			XCTAssertEqual(approvesRemaining, steps.contains(5) ? 0 : 1)
		}

		@MainActor
		private func draftWithoutSaving() throws {
			let turns = try compose("/")
			try tap("chat.slash.plan")
			try wait("The slash list did not fill /plan.", seconds: 15) {
				element("chat.composer").value as? String == "/plan "
			}
			try spendMessage("chat.send")
			try settle("/plan", turns: turns)
			XCTAssertTrue(
				try PhoneSample(app, after: "/plan").replyLines.joined().contains("?"),
				"The coach asks for what it needs.")
			try expectNoCard(after: "/plan")
			shot("step-1-plan-asks")
			let details =
				"I'm an intermediate cyclist with an FTP of 250 W. I can train 8 hours a week on Tuesday, Thursday, Saturday and Sunday, with my long ride on Sunday. My goal is a gran fondo on \(Self.granFondoDate). Show me the plan with its phases and their weeks, and a sample week."
			try settle(details, turns: try send(details))
			try expectTools(["build_plan_skeleton", "get_sample_week"])
			try expectNoCard(after: details)
			shot("step-1-draft")
		}

		@MainActor
		private func feasibility() throws {
			let question = "Can I get from 250 to 300 W?"
			try settle(question, turns: try send(question))
			try expectTools(["assess_feasibility"])
			try expectNoCard(after: question)
			shot("step-2-feasibility")
		}

		@MainActor
		private func saveSurvivesRelaunch() throws {
			let request = "Save that plan"
			try settle(request, turns: try send(request))
			let plan = try waitingCard(after: request, replacing: nil)
			shot("step-3-card-waiting")
			try relaunch()
			XCTAssertEqual(try waitingCard(after: request, replacing: nil), plan)
			shot("step-3-card-waiting-after-kill")
			try decide(Self.save, reading: Catalog.chatPlanSaveSaved, plan)
			savedPlan = plan
			try relaunch()
			try expectEnded(plan, reading: Catalog.chatPlanSaveSaved)
			shot("step-3-saved-after-kill")
			let question = "What is my current plan?"
			try settle(question, turns: try send(question))
			try expectReply(to: question, naming: [plan])
			shot("step-3-current-plan")
		}

		@MainActor
		private func replaceAndAskHistory() throws {
			let previous = try currentPlan()
			let request = "Make it 10 weeks and save it"
			try settle(request, turns: try send(request))
			let plan = try waitingCard(after: request, replacing: previous)
			try decide(Self.save, reading: Catalog.chatPlanSaveSaved, plan)
			savedPlan = plan
			let question = "When did my plan change?"
			try settle(question, turns: try send(question))
			try expectReply(to: question, naming: [previous, plan])
			shot("step-4-plan-history")
		}

		@MainActor
		private func expireBesideReview() throws {
			let previous = try currentPlan()
			let ride = "Add an easy 45-minute ride tomorrow"
			try settle(ride, turns: try send(ride))
			try wait("The workout review has no Approve.", seconds: 30) {
				element("chat.preview.add").isHittable
			}
			try expectNoCard(after: ride)
			shot("step-5-review-waiting")
			let longer = "Make the plan 12 weeks"
			try settle(longer, turns: try send(longer, besideReview: true))
			try expectNoCard(after: longer)
			let request = "Save that plan"
			try settle(request, turns: try send(request, besideReview: true))
			let prepared = ProcessInfo.processInfo.systemUptime
			let plan = try waitingCard(after: request, replacing: previous)
			shot("step-5-card-waiting")
			try wait("The eleventh minute did not come.", seconds: 600) {
				ProcessInfo.processInfo.systemUptime >= prepared + 580
			}
			XCTAssertTrue(element(Self.save).exists, "The card still waits before its ten minutes.")
			try wait("The card did not read Expired at the eleventh minute.", seconds: 40) {
				state(of: plan) == phrasebook.say(Catalog.chatPlanSaveExpired)
					&& !element(Self.save).exists && !element(Self.cancel).exists
			}
			XCTAssertLessThan(ProcessInfo.processInfo.systemUptime, prepared + 615)
			shot("step-5-card-expired")
			guard approvesRemaining == 1 else {
				throw PhoneRunBlocked(
					reason: "The session's one calendar Approve was already used.")
			}
			approvesRemaining = 0
			let notes = app.descendants(matching: .any).matching(identifier: "chat.note").count
			try tap("chat.preview.add")
			try wait("Approve did not finish.", seconds: 90) {
				!element("chat.preview.add").exists
					&& app.descendants(matching: .any).matching(identifier: "chat.note").count
						> notes
			}
			shot("step-5-approved-once")
		}

		@MainActor
		private func saveAtLargestText() throws {
			let previous = try currentPlan()
			let request = "Make the plan 14 weeks and save it"
			try settle(request, turns: try send(request))
			let plan = try waitingCard(after: request, replacing: previous, docked: false)
			try expectSpoken(
				[
					"chat.planSave.title", "chat.planSave.name", "chat.planSave.goal.label",
					"chat.planSave.duration.label", "chat.planSave.phase", "chat.planSave.replaces",
				], from: "chat.planSave.title",
				optional: ["chat.planSave.goal.label", "chat.planSave.duration.label"])
			shot("step-6-card-read")
			let save = try reach(Self.save)
			XCTAssertTrue(
				element("chat.transcript").descendants(matching: .any)
					.matching(identifier: "chat.planSave.bar").firstMatch.exists,
				"At the largest text size the bar is in the transcript.")
			XCTAssertGreaterThanOrEqual(save.frame.minY, newest(Self.card).frame.maxY)
			try expectSpoken(
				["chat.planSave.replaces", Self.save, Self.cancel], from: "chat.planSave.name")
			shot("step-6-largest-text")
			try decide(Self.save, reading: Catalog.chatPlanSaveSaved, plan)
			savedPlan = plan
		}

		@MainActor
		private func cancelCarriedCard() throws {
			let previous = try currentPlan()
			let request = "Make the plan 16 weeks and save it"
			try settle(request, turns: try send(request))
			let plan = try waitingCard(after: request, replacing: previous)
			shot("step-7-card-waiting")
			try spendMessage("chat.newConversation")
			try wait("New conversation did not finish.", seconds: 180) {
				try PhoneSample(app).turns == 0 && element("chat.welcome").exists
			}
			try wait("The carried card did not arm at the top.", seconds: 30) {
				element(Self.save).exists && element("chat.planSave.preparedEarlier").exists
			}
			let cards = element("chat.transcript").descendants(matching: .any)
				.matching(identifier: Self.card)
			XCTAssertEqual(cards.count, 1, "The carried card is shown once.")
			XCTAssertEqual(part("chat.planSave.name", of: newest(Self.card)).label, plan)
			shot("step-7-carried")
			try decide(Self.cancel, reading: Catalog.chatPlanSaveCanceled, plan)
		}
	}
#endif
