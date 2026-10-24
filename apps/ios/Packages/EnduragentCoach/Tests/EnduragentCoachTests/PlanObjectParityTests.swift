import Foundation
import Testing

@testable import EnduragentCoach

@Suite struct PlanObjectParityTests {
	struct Verdict {
		let id: String
		let input: JSONValue
		let accepted: Bool
		let npmText: String?
		let npmSummary: String?
	}

	@Test func everyPlanSaveVerdictIsZodsAndAnAcceptedPlanKeepsEveryKey() throws {
		let verdicts = try Self.planObjects() + Self.toolInputs()
		var compared = 0
		var mismatched: [String] = []
		for verdict in verdicts {
			compared += 1
			switch Result(catching: { () throws(ToolInputError) in
				try PlanDocument.parse(arguments: verdict.input)
			}) {
			case .success(let document):
				let kept =
					try verdict.npmText.map(JSONValue.parse) ?? verdict.input.objectFields["plan"]
				if !verdict.accepted || document.value != kept {
					mismatched.append(verdict.id)
				}
			case .failure(let refusal):
				if verdict.accepted || refusal.code != "invalid_plan" {
					mismatched.append(verdict.id)
				}
			}
		}
		#expect(mismatched.isEmpty)
		let planObjects = try PlanFixtures.manifestCount(["plan-object"])
		let planSaves = try PlanFixtures.manifestCount("tool-inputs", tool: "plan_save")
		#expect(compared == planObjects + planSaves)
		#expect(planObjects > 0)
		#expect(planSaves > 0)
	}

	@Test func savedTextSortsKeysAndDiffersFromNpmsTextOnlyInKeyOrder() throws {
		let accepted = try Self.planObjects().filter(\.accepted)
		var compared = 0
		var reordered = 0
		var mismatched: [String] = []
		for verdict in accepted {
			let npmText = try #require(verdict.npmText)
			let document = try PlanDocument.parse(arguments: verdict.input)
			compared += 1
			let npmValue = try JSONValue.parse(npmText)
			if npmText != document.text { reordered += 1 }
			if document.text != canonicalJSON(document.value)
				|| canonicalJSON(npmValue) != document.text
			{
				mismatched.append(verdict.id)
			}
		}
		#expect(mismatched.isEmpty)
		#expect(compared == accepted.count)
		#expect(compared > 0)
		#expect(reordered > 0)

		let outOfOrder = try #require(accepted.first { $0.id == "plan-object/0004" })
		#expect(
			outOfOrder.npmText
				== "{\n  \"name\": \"Unsorted\",\n  \"zeta\": 1,\n  \"alpha\": 2,\n"
				+ "  \"middle\": {\n    \"zz\": true,\n    \"aa\": false\n  }\n}")
		#expect(
			try PlanDocument.parse(arguments: outOfOrder.input).text
				== "{\n  \"alpha\": 2,\n  \"middle\": {\n    \"aa\": false,\n    \"zz\": true\n  },\n"
				+ "  \"name\": \"Unsorted\",\n  \"zeta\": 1\n}")
	}

	@Test func pendingSummaryIsNpmsSummaryForEveryAcceptedPlan() throws {
		let accepted = try Self.planObjects().filter(\.accepted)
		var compared = 0
		var forms: Set<Bool> = []
		var mismatched: [String] = []
		for verdict in accepted {
			let summary = try #require(verdict.npmSummary)
			let document = try PlanDocument.parse(arguments: verdict.input)
			compared += 1
			forms.insert(summary.hasPrefix(Self.bareSummary + " — "))
			if document.pendingSummary != summary { mismatched.append(verdict.id) }
		}
		#expect(mismatched.isEmpty)
		#expect(compared == accepted.count)
		#expect(compared > 0)
		#expect(forms == [true, false])
	}

	static let bareSummary = "Save the training plan — replaces the current saved plan"

	static func planObjects() throws -> [Verdict] {
		try PlanFixtures.cases("plan-object").map { item in
			let output = item.output?.objectFields ?? [:]
			return Verdict(
				id: item.id, input: item.input,
				accepted: try #require(output["accepted"]?.boolValue),
				npmText: output["saved"]?.stringValue,
				npmSummary: output["pending"]?.objectFields["summary"]?.stringValue)
		}
	}

	static func toolInputs() throws -> [Verdict] {
		try PlanFixtures.cases("tool-inputs").filter { $0.tool == "plan_save" }.map { item in
			Verdict(
				id: item.id, input: item.input,
				accepted: try #require(item.output?.objectFields["accepted"]?.boolValue),
				npmText: nil, npmSummary: nil)
		}
	}
}
