import EnduragentCoachFixtures
import Foundation
import Synchronization
import Testing

@testable import EnduragentCoach

extension PlanTurns {
	func cards(on coach: Coach, in chat: ChatID = .main) async throws -> [PlanCard] {
		try #require(await coach.currentSnapshot(chat)).plans
	}

	func armedToken(on coach: Coach) async throws -> PlanSaveToken {
		let card = try #require(try await cards(on: coach).last)
		#expect(await coach.decide(.presented(card.ref), in: .main) == .presented)
		return try #require(Self.token(of: try await cards(on: coach).last))
	}

	static func token(of card: PlanCard?) -> PlanSaveToken? {
		guard case .waiting(.armed(let token))? = card?.state else { return nil }
		return token
	}

	func prepareAndArm(_ plan: JSONValue, on coach: Coach) async throws -> PlanSaveToken {
		_ = try await reply(after: [[save(plan)]], on: coach)
		return try await armedToken(on: coach)
	}

	func waitForCards(
		on coach: Coach, _ matches: @escaping @Sendable ([PlanCard]) -> Bool
	) async throws -> [PlanCard]? {
		try await firstSnapshot(in: await coach.observe(.main), within: .hangGuard) {
			matches($0.plans)
		}?.plans
	}

	func planLoad(on coach: Coach) async throws -> JSONValue {
		try #require(
			try await tools([.toolCall(name: "plan_load", arguments: "{}")], on: coach).first)
	}

	func tools(_ calls: [ScriptedEvent], on coach: Coach) async throws -> [JSONValue] {
		script(calls + [.finish(reason: .toolCalls), .text("Read."), .finish(reason: .stop)])
		#expect(replyText(try await coach.sendAndSettle("What is my plan?")) == "Read.")
		return try toolData()
	}

	func claims(in log: any RecordLog) async throws -> [(PlanStepRecord, SaveClaim)] {
		try await steps(in: log).compactMap { step in
			guard case .claimed(let claim) = step.body.step else { return nil }
			return (step, claim)
		}
	}

	static func document(_ plan: JSONValue) throws -> PlanDocument {
		try PlanDocument.parse(arguments: .object(["plan": plan]))
	}
}

final class PlanOutcomes: Sendable {
	private let recorded = Mutex<[PlanDecisionOutcome]>([])

	var all: [PlanDecisionOutcome] { recorded.withLock { $0 } }

	func record(_ outcome: PlanDecisionOutcome) {
		recorded.withLock { $0.append(outcome) }
	}
}

extension SavedPlanRows {
	static func stored(in log: any RecordLog) async throws -> [(
		record: AthleteRecord, payload: JSONValue
	)] {
		try await log.fetch(RecordQuery(scope: .synced([SavedPlans.kind]))).records.map { record in
			let encoded = try RecordCodec.encode(record.body)
			return (
				record,
				try JSONValue.parse(try #require(String(data: encoded.data, encoding: .utf8)))
			)
		}
	}

	static func stored(_ id: SavedPlanID, in log: any RecordLog) async throws -> [(
		record: AthleteRecord, payload: JSONValue
	)] {
		try await stored(in: log).filter {
			$0.payload.objectFields["id"] == .string(id.ulid.rawValue)
		}
	}

	static func payload(of clock: HybridLogicalClock) -> JSONValue {
		.object([
			"wallMs": .number(Double(clock.wallMs)), "logical": .number(Double(clock.logical)),
			"deviceId": .string(clock.deviceId.rawValue),
		])
	}
}
