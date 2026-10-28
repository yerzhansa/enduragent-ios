import Foundation
import Testing
import ToolSupport

struct PlanPhoneBudgetTests {
	static let firstFive = "plan/1,plan/2,plan/3,plan/4,plan/5"
	static let session = "steps\tbudget\tspent\n\(firstFive)\t12\t10\nplan/6\t2\t1\n"
	static let actions = """
		Approved message budget 6 for plan/7.
		plan/1 starts.
		Message action chat.send. Budget remaining 14.
		Tapped chat.send.
		Message action chat.send. Budget remaining 13.
		Tapped chat.planSave.save.
		Message action chat.turn.tryAgain. Budget remaining 12.
		Message action chat.newConversation. Budget remaining 11.
		"""

	static func plan() throws -> PhoneSessionPlan { try PhoneSessionTests.committed("plan") }

	static func allSteps(of plan: PhoneSessionPlan) -> [String] { plan.steps.map(\.id) }

	func refusal(_ body: () throws -> Void) -> String? {
		do {
			try body()
			return nil
		} catch let refused as PhoneRefusal {
			return refused.description
		} catch {
			return "unexpected \(error)"
		}
	}

	@Test func theWholeSessionPlansTwelveSendsAndOneNewConversation() throws {
		let plan = try Self.plan()
		let passed = try [("1", "5"), ("6", "6"), ("7", "7")].flatMap { bounds in
			let steps = try PhoneSteps(first: bounds.0, last: bounds.1, plan: plan)
			let variable = PlannedPhoneStep.text(plan.plannedSteps(steps.ids))
			return try #require(PlannedPhoneStep.steps(in: variable))
		}
		#expect(passed.map(\.id) == (1...7).map { "plan/\($0)" })
		#expect(passed.map(\.planned) == [2, 1, 2, 2, 3, 1, 2])
		#expect(passed.reduce(0) { $0 + $1.planned } == 13)
		#expect(
			PlannedPhoneStep.text(plan.plannedSteps(["plan/2", "plan/3"]))
				== "plan/2=1,plan/3=2")
	}

	@Test(arguments: [("0", "7"), ("1", "8"), ("5", "3"), ("one", "7"), ("01", "7"), ("", "7")])
	func stepsOutsideTheSessionAreRefused(_ bounds: (String, String)) throws {
		let plan = try Self.plan()
		let refused = refusal { _ = try PhoneSteps(first: bounds.0, last: bounds.1, plan: plan) }
		#expect(refused == "Name the first and last step, from 1 to 7, first not after last.")
	}

	@Test(arguments: [("5", "6"), ("6", "7"), ("1", "7")])
	func stepSixRunsAlone(_ bounds: (String, String)) throws {
		let plan = try Self.plan()
		let refused = refusal { _ = try PhoneSteps(first: bounds.0, last: bounds.1, plan: plan) }
		#expect(refused?.hasPrefix("plan/6 runs alone") == true)
		let alone = try PhoneSteps(first: "6", last: "6", plan: plan)
		#expect(alone.ids == ["plan/6"])
		#expect(plan.planned(alone.ids) == 1)
	}

	@Test func aBudgetBelowTheStepsPlannedCountIsRefused() throws {
		let firstFive = try PhoneSteps(first: "1", last: "5", plan: try Self.plan()).ids
		for (name, steps, planned) in [
			("m4", Self.allSteps(of: try PhoneSessionTests.committed("m4")), 15),
			("plan", firstFive, 10),
			("closeout", Self.allSteps(of: try PhoneSessionTests.committed("closeout")), 32),
		] {
			let plan = try PhoneSessionTests.committed(name)
			let refused = refusal {
				_ = try PhoneBudget.approve(
					String(planned - 1), steps: steps, plan: plan, spent: 0)
			}
			#expect(
				refused
					== "A budget of \(planned - 1) is below the \(planned) message actions \(steps.joined(separator: ", ")) plan. Stop before build, launch or Send."
			)
			let approved = try PhoneBudget.approve(
				String(planned), steps: steps, plan: plan, spent: 0)
			#expect(approved.steps == steps)
			#expect(approved.budget == planned)
			#expect(approved.spent == planned)
		}
		let none = try PhoneBudget.approve(
			"0", steps: ["m4/approve-later"], plan: try PhoneSessionTests.committed("m4"),
			spent: 0)
		#expect(none.budget == 0)
		#expect(
			refusal {
				_ = try PhoneBudget.approve("0", steps: ["plan/6"], plan: try Self.plan(), spent: 0)
			}?.hasPrefix("A budget of 0 is below the 1 message actions plan/6 plan.") == true)
	}

	@Test(arguments: ["", "13 ", "-13", "1e2", "013", "fifteen", "1000000000"])
	func anAnswerThatIsNotABudgetIsRefused(_ answer: String) throws {
		for name in ["m4", "plan", "closeout"] {
			let plan = try PhoneSessionTests.committed(name)
			let refused = refusal {
				_ = try PhoneBudget.approve(
					answer, steps: [plan.steps[0].id], plan: plan, spent: 0)
			}
			#expect(
				refused == "No message budget approved. Stop before build, launch or Send.",
				"\(name)")
		}
	}

	@Test func aBudgetThatWouldTakeTheMilestonePastThirtyIsRefused() throws {
		let ledger = try PhoneLedger(text: Self.session, plan: try Self.plan())
		#expect(ledger.spent == 11)
		for (name, step, spent, cap) in [
			("m4", "m4/list", 30, 40), ("plan", "plan/7", ledger.spent, 30),
			("closeout", "closeout/fill", 40, 50),
		] {
			let plan = try PhoneSessionTests.committed(name)
			let over = cap - spent + 1
			let refused = refusal {
				_ = try PhoneBudget.approve(String(over), steps: [step], plan: plan, spent: spent)
			}
			#expect(
				refused
					== "\(spent) message actions are spent, so a budget of \(over) would pass the \(name) cap of \(cap). Stop before build, launch or Send."
			)
			let approved = try PhoneBudget.approve(
				String(over - 1), steps: [step], plan: plan, spent: spent)
			#expect(approved.steps == [step])
			#expect(approved.budget == over - 1)
			#expect(approved.spent == over - 1)
		}
	}

	@Test(arguments: [
		"plan/1\t12\n", "plan/1\t12\t10\textra\n", "plan/8\t12\t10\n", "plan/1\t12\tten\n",
		"plan/1\t12\t13\n", "plan/1\t31\t10\n", "\n", "plan/1 12 10\n", "m4/list\t1\t1\n",
		"plan/1,\t3\t3\n",
	])
	func aRowThatCannotBeReadRefusesTheInvocation(_ row: String) throws {
		let plan = try Self.plan()
		let refused = refusal {
			_ = try PhoneLedger(
				text: "steps\tbudget\tspent\nplan/1,plan/2\t3\t3\n" + row, plan: plan)
		}
		#expect(refused?.hasPrefix("messages.tsv row 2 cannot be read:") == true)
	}

	@Test(arguments: ["", "budget\tspent\nplan/1\t12\t10\n", "plan/1\t12\t10\n"])
	func aFileWithoutItsHeaderRefusesTheInvocation(_ text: String) throws {
		let plan = try Self.plan()
		let refused = refusal { _ = try PhoneLedger(text: text, plan: plan) }
		#expect(refused?.hasPrefix("messages.tsv does not start with its header.") == true)
	}

	@Test func aRunAddsOneRowCountingTheRunnersMessageActions() throws {
		let plan = try Self.plan()
		let ledger = try PhoneLedger(text: Self.session, plan: plan)
		let approved = try PhoneBudget.approve(
			"6", steps: ["plan/7"], plan: plan, spent: ledger.spent)
		let recorded = ledger.recording(approved, actions: Self.actions)
		#expect(recorded.text == Self.session + "plan/7\t6\t4\n")
		#expect(try PhoneLedger(text: recorded.text, plan: plan) == recorded)
		#expect(recorded.spent == 15)
	}

	@Test func aRunWhoseLogCannotBeReadRecordsTheWholeBudget() throws {
		let plan = try Self.plan()
		let ledger = try PhoneLedger(text: nil, plan: plan)
		let steps = try PhoneSteps(first: "1", last: "5", plan: plan)
		let approved = try PhoneBudget.approve("15", steps: steps.ids, plan: plan, spent: 0)
		let recorded = ledger.recording(approved, actions: nil)
		#expect(recorded.text == "steps\tbudget\tspent\n\(Self.firstFive)\t15\t15\n")
		#expect(recorded.spent == 15)
	}

	@Test func theActionsLogIsTheOneAttachmentNamedForIt() throws {
		let stamp = "plan-phone-actions_0_6F1C2B3A-4D5E-4F60-8A7B-9C0D1E2F3A4B.txt"
		func manifest(_ names: [String]) throws -> JSONValue {
			let attachments = names.enumerated().map { index, name in
				#"{"exportedFileName":"file-\#(index).txt","suggestedHumanReadableName":"\#(name)"}"#
			}
			return try JSONValue.parse(
				#"[{"testIdentifier":"PlanPhoneRun/testPlanPhoneRun","attachments":[\#(attachments.joined(separator: ","))]}]"#
			)
		}
		#expect(
			try PlanPhoneBudget.actionsFile(
				in: manifest(["step-1-plan.png", stamp]), named: "plan-phone-actions")
				== "file-1.txt")
		#expect(
			try PlanPhoneBudget.actionsFile(
				in: manifest(["step-1-plan.png"]), named: "plan-phone-actions") == nil)
		#expect(
			try PlanPhoneBudget.actionsFile(
				in: manifest([stamp, stamp]), named: "plan-phone-actions") == nil)
		#expect(
			try PlanPhoneBudget.actionsFile(
				in: manifest(["plan-phone-actions-old.txt"]), named: "plan-phone-actions") == nil)
	}
}
