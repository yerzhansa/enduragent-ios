import EnduragentCoach
import Foundation

public enum AthleteOwnershipFixture {
	public static let savedChat: ChatID = "fixture-ownership-saved"
	public static let unknownChat: ChatID = "fixture-ownership-unknown"
	public static let savedQuestion = "Earlier training for athlete A"
	public static let unknownQuestion = "Earlier training with no recoverable athlete"

	public static func seed(in records: RecordFaults, account: TrainingAccount) async throws {
		try await seed(in: records.log, account: account)
	}

	package static func seed(in log: any RecordLog, account: TrainingAccount) async throws {
		let unknown = TrainingAccount.intervals(connection: ConnectionID(), athlete: nil)
		for (index, chat, question, owner) in [
			(0, savedChat, savedQuestion, account),
			(1, unknownChat, unknownQuestion, unknown),
		] {
			let existing = try await log.fetch(
				RecordQuery(scope: .everySynced, chatId: chat))
			guard existing.records.isEmpty else { continue }
			let date = Date(timeIntervalSince1970: 897_984_000 + Double(index * 10))
			let turn = TurnID(ulid: ULID.generate(at: date))
			let bodies: [RecordBody] = [
				.synced(
					.userMessage(
						UserMessageBody(
							chatId: chat, turn: turn, fragment: 0, draft: DraftID(),
							athleteText: question, slash: nil))),
				.synced(
					.turnSettled(
						TurnSettledBody(
							chatId: chat, turn: turn,
							attempt: AttemptID(ulid: ULID.generate(at: date.addingTimeInterval(1))),
							settlement: .replied(
								.model("Retained training information."), lineage: nil)))),
			]
			let rows = bodies.enumerated().map { offset, body in
				let instant = date.addingTimeInterval(Double(offset))
				return AthleteRecord(
					ulid: ULID.generate(at: instant), deviceId: log.deviceId,
					hlc: HybridLogicalClock(
						wallMs: Int64(instant.timeIntervalSince1970 * 1_000), logical: 0,
						deviceId: log.deviceId),
					timeZone: .gmt, civilDate: CivilDate(date: instant, timeZone: .gmt),
					cause: .legacy, account: owner, body: body)
			}
			try await log.append(rows, locality: .synced)
		}
	}
}
