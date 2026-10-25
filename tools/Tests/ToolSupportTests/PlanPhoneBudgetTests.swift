import Foundation
import Testing
import ToolSupport

struct PlanPhoneBudgetTests {
	static let session = "steps\tbudget\tspent\n1-5\t12\t10\n6-6\t2\t1\n"
	static let actions = """
		Approved message budget 6 for steps 7-7.
		Step 1 starts.
		Message action chat.send. Budget remaining 14.
		Tapped chat.send.
		Message action chat.send. Budget remaining 13.
		Tapped chat.planSave.save.
		Message action chat.turn.tryAgain. Budget remaining 12.
		Message action chat.newConversation. Budget remaining 11.
		"""

	func refusal(_ body: () throws -> Void) -> String? {
		do {
			try body()
			return nil
		} catch let refused as PlanPhoneRefusal {
			return refused.description
		} catch {
			return "unexpected \(error)"
		}
	}

	@Test func theWholeSessionPlansTwelveSendsAndOneNewConversation() throws {
		let session = try ["1-5", "6-6", "7-7"].map {
			let bounds = $0.split(separator: "-").map(String.init)
			return try PlanPhoneSteps(first: bounds[0], last: bounds[1]).planned
		}
		#expect(session == [10, 1, 2])
		#expect(session.reduce(0, +) == 13)
	}

	@Test(arguments: [("0", "7"), ("1", "8"), ("5", "3"), ("one", "7"), ("01", "7"), ("", "7")])
	func stepsOutsideTheSessionAreRefused(_ bounds: (String, String)) {
		let refused = refusal { _ = try PlanPhoneSteps(first: bounds.0, last: bounds.1) }
		#expect(refused?.contains("Name the first and last step") == true)
	}

	@Test(arguments: [("5", "6"), ("6", "7"), ("1", "7")])
	func stepSixRunsAlone(_ bounds: (String, String)) throws {
		let refused = refusal { _ = try PlanPhoneSteps(first: bounds.0, last: bounds.1) }
		#expect(refused?.hasPrefix("Step 6 runs alone") == true)
		#expect(try PlanPhoneSteps(first: "6", last: "6").planned == 1)
	}

	@Test func aBudgetBelowTheStepsPlannedCountIsRefused() throws {
		let steps = try PlanPhoneSteps(first: "1", last: "5")
		let refused = refusal {
			_ = try PlanPhoneBudget.approve("9", for: steps, after: PlanPhoneLedger(text: nil))
		}
		#expect(
			refused
				== "A budget of 9 is below the 10 message actions steps 1-5 plan. Stop before build, launch or Send."
		)
		let approved = try PlanPhoneBudget.approve(
			"10", for: steps, after: PlanPhoneLedger(text: nil))
		#expect(approved.budget == 10)
	}

	@Test(arguments: ["0", "", "13 ", "-13", "1e2", "013", "fifteen"])
	func anAnswerThatIsNotABudgetIsRefused(_ answer: String) throws {
		let steps = try PlanPhoneSteps(first: "6", last: "6")
		let refused = refusal {
			_ = try PlanPhoneBudget.approve(answer, for: steps, after: PlanPhoneLedger(text: nil))
		}
		#expect(refused == "No message budget approved. Stop before build, launch or Send.")
	}

	@Test func aBudgetThatWouldTakeTheMilestonePastThirtyIsRefused() throws {
		let ledger = try PlanPhoneLedger(text: Self.session)
		let steps = try PlanPhoneSteps(first: "7", last: "7")
		#expect(ledger.spent == 11)
		let refused = refusal { _ = try PlanPhoneBudget.approve("20", for: steps, after: ledger) }
		#expect(
			refused
				== "11 message actions are spent, so a budget of 20 would pass the milestone's 30. Stop before build, launch or Send."
		)
		let approved = try PlanPhoneBudget.approve("19", for: steps, after: ledger)
		#expect(approved.steps == steps)
		#expect(approved.budget == 19)
		#expect(approved.spent == 19)
	}

	@Test(arguments: [
		"1-5\t12\n", "1-5\t12\t10\textra\n", "1-8\t12\t10\n", "1-5\t12\tten\n",
		"1-5\t12\t13\n", "1-5\t31\t10\n", "\n", "1-5 12 10\n",
	])
	func aRowThatCannotBeReadRefusesTheInvocation(_ row: String) {
		let refused = refusal {
			_ = try PlanPhoneLedger(text: "steps\tbudget\tspent\n1-2\t3\t3\n" + row)
		}
		#expect(refused?.hasPrefix("messages.tsv row 2 cannot be read:") == true)
	}

	@Test(arguments: ["", "budget\tspent\n1-5\t12\t10\n", "1-5\t12\t10\n"])
	func aFileWithoutItsHeaderRefusesTheInvocation(_ text: String) {
		let refused = refusal { _ = try PlanPhoneLedger(text: text) }
		#expect(refused?.hasPrefix("messages.tsv does not start with its header.") == true)
	}

	@Test func aRunAddsOneRowCountingTheRunnersMessageActions() throws {
		let ledger = try PlanPhoneLedger(text: Self.session)
		let steps = try PlanPhoneSteps(first: "7", last: "7")
		let approved = try PlanPhoneBudget.approve("6", for: steps, after: ledger)
		let recorded = ledger.recording(approved, actions: Self.actions)
		#expect(recorded.text == Self.session + "7-7\t6\t4\n")
		#expect(try PlanPhoneLedger(text: recorded.text) == recorded)
		#expect(recorded.spent == 15)
	}

	@Test func aRunWhoseLogCannotBeReadRecordsTheWholeBudget() throws {
		let ledger = try PlanPhoneLedger(text: nil)
		let steps = try PlanPhoneSteps(first: "1", last: "5")
		let approved = try PlanPhoneBudget.approve("15", for: steps, after: ledger)
		let recorded = ledger.recording(approved, actions: nil)
		#expect(recorded.text == "steps\tbudget\tspent\n1-5\t15\t15\n")
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
			try PlanPhoneBudget.actionsFile(in: manifest(["step-1-plan.png", stamp]))
				== "file-1.txt")
		#expect(try PlanPhoneBudget.actionsFile(in: manifest(["step-1-plan.png"])) == nil)
		#expect(try PlanPhoneBudget.actionsFile(in: manifest([stamp, stamp])) == nil)
		#expect(
			try PlanPhoneBudget.actionsFile(in: manifest(["plan-phone-actions-old.txt"])) == nil)
	}
}
