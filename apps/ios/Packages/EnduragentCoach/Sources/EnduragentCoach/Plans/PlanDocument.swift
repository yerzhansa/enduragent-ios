import Foundation

struct PlanDocument: Sendable, Equatable {
	let value: JSONValue
	let text: String
	let digest: PlanDigest

	private init(value: JSONValue) {
		self.value = value
		text = canonicalJSON(value)
		digest = PlanDigest(rawValue: sha256Hex(value.canonicalDigestInput()))
	}

	private static let largestSafeInteger = 9_007_199_254_740_991.0
	private static let summaryPhrasebook = CatalogPhrasebook(tag: .en)
	private static let javaScriptWhitespace: Set<UInt32> = [
		0x09, 0x0A, 0x0B, 0x0C, 0x0D, 0x20, 0xA0, 0x1680, 0x2000, 0x2001, 0x2002, 0x2003, 0x2004,
		0x2005, 0x2006, 0x2007, 0x2008, 0x2009, 0x200A, 0x2028, 0x2029, 0x202F, 0x205F, 0x3000,
		0xFEFF,
	]

	static func parse(arguments: JSONValue) throws(ToolInputError) -> PlanDocument {
		guard case .object(let fields) = arguments, let plan = fields["plan"] else {
			throw ToolInputError(code: "invalid_plan", details: "plan must be an object.")
		}
		if let problem = problem(in: plan) {
			throw ToolInputError(code: "invalid_plan", details: problem)
		}
		guard ToolResultCap.fits(plan) else {
			throw ToolInputError(
				code: "plan_too_large",
				details: "The plan is too large for plan_load to return whole. Send a shorter plan."
			)
		}
		return PlanDocument(value: plan)
	}

	static func restore(text: String, digest: PlanDigest) throws(PlanDocumentCorrupt)
		-> PlanDocument
	{
		let value: JSONValue
		do {
			value = try JSONValue.parse(text)
		} catch {
			throw PlanDocumentCorrupt(reason: "the plan text is not JSON: \(error)")
		}
		if let problem = problem(in: value) {
			throw PlanDocumentCorrupt(reason: problem)
		}
		let document = PlanDocument(value: value)
		guard document.text == text else {
			throw PlanDocumentCorrupt(reason: "the plan text is not its canonical rendering.")
		}
		guard document.digest == digest else {
			throw PlanDocumentCorrupt(reason: "the plan text does not match its digest.")
		}
		return document
	}

	var pendingSummary: String {
		guard let detail = summaryDetail("name") ?? summaryDetail("goal") else {
			return Self.summaryPhrasebook.say(Catalog.coachProposalSavePlan)
		}
		return Self.summaryPhrasebook.say(Catalog.coachProposalSavePlanDetail, ["detail": detail])
	}

	private func summaryDetail(_ key: String) -> String? {
		guard let field = value.objectFields[key]?.stringValue,
			!field.unicodeScalars.allSatisfy({ Self.javaScriptWhitespace.contains($0.value) })
		else { return nil }
		return field
	}

	private static func problem(in plan: JSONValue) -> String? {
		guard case .object(let fields) = plan else { return "plan must be an object." }
		guard case .string = fields["name"] else { return "plan.name must be text." }
		for key in ["primaryGoal", "status"] {
			if let field = fields[key], field.stringValue == nil {
				return "plan.\(key) must be text when present."
			}
		}
		if let weeks = fields["totalWeeks"], !isPositiveSafeInteger(weeks) {
			return "plan.totalWeeks must be a positive whole number when present."
		}
		return nil
	}

	private static func isPositiveSafeInteger(_ value: JSONValue) -> Bool {
		guard case .number(let number) = value else { return false }
		return number.rounded(.towardZero) == number && number >= 1
			&& number <= largestSafeInteger
	}
}

public struct PlanDigest: Hashable, Sendable {
	public let rawValue: String
}

struct PlanDocumentCorrupt: Error, Sendable, Equatable {
	let reason: String
}
