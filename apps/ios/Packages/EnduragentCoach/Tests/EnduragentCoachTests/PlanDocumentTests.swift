import EnduragentCoachFixtures
import Foundation
import Testing

@testable import EnduragentCoach

@Suite struct PlanDocumentTests {
	static let base: JSONValue = .object([
		"name": .string("Base"), "primaryGoal": .string("century"), "totalWeeks": .number(12),
	])

	@Test func aPlanAtTheToolResultCapIsAcceptedAndOneTokenOverIsRefusedAsTooLarge()
		async throws
	{
		let atCap = try Self.plan(estimatedTokens: TurnPolicy.toolResultTokenCap)
		let overCap = try Self.plan(estimatedTokens: TurnPolicy.toolResultTokenCap + 1)

		let accepted = try PlanDocument.parse(arguments: .object(["plan": atCap]))
		#expect(accepted.value == atCap)
		#expect(
			throws: ToolInputError(
				code: "plan_too_large",
				details: "The plan is too large for plan_load to return whole. Send a shorter plan."
			)
		) {
			try PlanDocument.parse(arguments: .object(["plan": overCap]))
		}

		guard case .result(let delivered) = try await Self.runtimeOutcome(returning: atCap) else {
			Issue.record("the runtime omitted a plan PlanDocument accepted")
			return
		}
		#expect(delivered.objectFields["data"] == atCap)
		guard case .truncated = try await Self.runtimeOutcome(returning: overCap) else {
			Issue.record("the runtime delivered a plan PlanDocument refused")
			return
		}
	}

	@Test func digestIsTheSha256OfTheCanonicalDigestInputAndRestoresTheSameDocument() throws {
		let document = try PlanDocument.parse(arguments: .object(["plan": Self.base]))

		#expect(document.digest.rawValue == sha256Hex(Self.base.canonicalDigestInput()))
		#expect(
			document.digest.rawValue
				== "99a5ebd7e05dfb395dc73eba044ba930c3db23209c366bde2e1e51d44c5e2ff9")
		#expect(try PlanDocument.restore(text: document.text, digest: document.digest) == document)
	}

	@Test func aSavedPlanRowWhoseDocumentWasEditedByHandIsMalformed() throws {
		let document = try PlanDocument.parse(arguments: .object(["plan": Self.base]))
		let edits = [
			document.text.replacingOccurrences(of: "\"century\"", with: "\"gran fondo\""),
			document.text.replacingOccurrences(of: "\n  ", with: "\n    "),
			document.text.replacingOccurrences(of: "\"Base\"", with: "12"),
		]

		for edited in edits {
			#expect(edited != document.text)
			let row = SavedPlanRows.payload(
				text: edited, digest: document.digest.rawValue, id: 1, confirmation: 2,
				decided: HybridLogicalClock(
					wallMs: 1, logical: 0, deviceId: DeviceID(rawValue: "plan-phone")))
			#expect(
				SavedPlanRows.decode(row).failure
					== .malformed(kind: "savedPlan", ulid: "saved-plan-row"))
		}
		let untouched = SavedPlanRows.payload(
			text: document.text, digest: document.digest.rawValue, id: 1, confirmation: 2,
			decided: HybridLogicalClock(
				wallMs: 1, logical: 0, deviceId: DeviceID(rawValue: "plan-phone")))
		#expect(SavedPlanRows.decode(untouched).failure == nil)
	}

	@Test func restoreKeepsAStoredPlanThatNoLongerFitsTheCap() throws {
		let overCap = try Self.plan(estimatedTokens: TurnPolicy.toolResultTokenCap + 1)
		let text = canonicalJSON(overCap)
		let digest = PlanDigest(rawValue: sha256Hex(overCap.canonicalDigestInput()))

		let restored = try PlanDocument.restore(text: text, digest: digest)

		#expect(restored.value == overCap)
		#expect(restored.text == text)
	}

	static func plan(estimatedTokens tokens: Int) throws -> JSONValue {
		let empty = JSONValue.object(["name": .string("Base"), "notes": .string("")])
		let overhead = UntrustedEnvelope.wrap(empty).canonicalDigestInput().utf16.count
		let plan = JSONValue.object([
			"name": .string("Base"),
			"notes": .string(String(repeating: "x", count: tokens * 10 / 3 - overhead)),
		])
		try #require(estimateTokens(UntrustedEnvelope.wrap(plan).canonicalDigestInput()) == tokens)
		return plan
	}

	static func runtimeOutcome(returning plan: JSONValue) async throws -> ToolOutcome {
		let tool = BoundTool(
			schema: ToolSchema(name: .memoryRead, description: "", parameters: .object([:])),
			effect: .memoryRead(.memoryRead), narrowing: nil
		) { _, _ in .result(plan) }
		return try await ToolRuntime.execute(
			tool, arguments: .object([:]),
			scope: TurnScope(stamp: testStamp(), policy: .npm, ladder: .npm, uptime: .zero)
		).outcome
	}
}
