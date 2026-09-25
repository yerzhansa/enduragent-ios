import Foundation
import Testing

@testable import EnduragentCoach

let amsterdamZone: IANATimeZone = {
	guard let zone = IANATimeZone(identifier: "Europe/Amsterdam") else {
		preconditionFailure("Europe/Amsterdam is a valid identifier")
	}
	return zone
}()

func testStamp(
	operation: OperationID? = nil,
	attempt: ULID = ULID.generate(at: Date(timeIntervalSince1970: 897_984_000)),
	account: TrainingAccount = .unconnected,
	zone: IANATimeZone = amsterdamZone
) -> OperationStamp {
	OperationStamp(
		operation: operation ?? .turn(TurnID(ulid: attempt)),
		attempt: AttemptID(ulid: attempt),
		binding: ActionBinding(account: account, zone: zone)
	)
}

func storedRecord(
	device: DeviceID,
	wall: Int64,
	logical: UInt32 = 0,
	date: CivilDate = "1998-06-13",
	ulid: ULID? = nil,
	cause: RecordCause = .legacy,
	body: RecordBody
) -> AthleteRecord {
	AthleteRecord(
		ulid: ulid ?? ULID.generate(at: Date(timeIntervalSince1970: TimeInterval(wall))),
		deviceId: device,
		hlc: HybridLogicalClock(wallMs: wall, logical: logical, deviceId: device),
		timeZone: amsterdamZone,
		civilDate: date,
		cause: cause,
		account: .unconnected,
		body: body
	)
}

func sampleUser(chatId: ChatID, text: String, turn: TurnID? = nil) -> SyncedRecordBody {
	.userMessage(
		UserMessageBody(
			chatId: chatId,
			turn: turn ?? TurnID(ulid: ULID.generate(at: Date(timeIntervalSince1970: 897_984_000))),
			fragment: 0,
			draft: DraftID(),
			athleteText: text,
			slash: nil
		)
	)
}

func sampleReply(chatId: ChatID, turn: TurnID, text: String) -> SyncedRecordBody {
	.turnSettled(
		TurnSettledBody(
			chatId: chatId,
			turn: turn,
			attempt: AttemptID(ulid: ULID.generate(at: Date(timeIntervalSince1970: 897_984_001))),
			settlement: .replied(.model(text), lineage: nil)
		)
	)
}

func legacyUser(chatId: ChatID, text: String) -> RecordBody {
	.legacy(.userMessageV1(chatId: chatId, athleteText: text, slash: nil))
}

func legacyReply(chatId: ChatID, text: String) -> RecordBody {
	.legacy(
		.assistantMessage(
			AssistantMessageBody(chatId: chatId, text: text, templateHash: "t", assembledHash: "a")))
}

func sampleProposal(chatId: ChatID, nonce: Nonce, expiresAt: Date) -> ProposalBody {
	ProposalBody(
		chatId: chatId,
		nonce: nonce,
		tool: .intervalsCreateStrengthWorkout,
		toolInput: .createStrengthWorkout(date: "1998-06-13", name: "Core", description: "20 min"),
		summary: "Core session",
		description: "Core · 20 min",
		expiresAt: expiresAt
	)
}

func messageText(_ record: AthleteRecord) -> String {
	switch record.body {
	case .synced(.userMessage(let body)): body.athleteText
	case .synced(.turnSettled(let body)):
		switch body.settlement {
		case .replied(.model(let text), _): text
		}
	case .legacy(.userMessageV1(_, let text, _)): text
	case .legacy(.assistantMessage(let body)): body.text
	default: ""
	}
}

func seed(_ log: any RecordLog, _ records: [AthleteRecord]) async throws {
	for record in records {
		try await log.append([record], locality: record.locality)
	}
}

func fixedUlid(_ offset: Int) -> ULID {
	let alphabet = Array("0123456789ABCDEFGHJKMNPQRSTVWXYZ")
	let prefix = ULID.generate(at: Date(timeIntervalSince1970: 899_164_800)).rawValue.prefix(10)
	var suffix = ""
	var remaining = offset
	for _ in 0..<16 {
		suffix = String(alphabet[remaining % 32]) + suffix
		remaining /= 32
	}
	guard let ulid = ULID(rawValue: prefix + suffix) else {
		preconditionFailure("fixed ulid is well formed")
	}
	return ulid
}

func kinds(_ records: [AthleteRecord]) -> [String] {
	records.map(\.body.kind)
}
