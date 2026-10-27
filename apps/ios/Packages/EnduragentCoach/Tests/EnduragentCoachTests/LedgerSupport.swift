import EnduragentCoachFixtures
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
	account: TrainingAccount = .unconnected,
	body: RecordBody
) -> AthleteRecord {
	AthleteRecord(
		ulid: ulid ?? ULID.generate(at: Date(timeIntervalSince1970: TimeInterval(wall))),
		deviceId: device,
		hlc: HybridLogicalClock(wallMs: wall, logical: logical, deviceId: device),
		timeZone: amsterdamZone,
		civilDate: date,
		cause: cause,
		account: account,
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
			AssistantMessageBody(chatId: chatId, text: text, templateHash: "t", assembledHash: "a"))
	)
}

func sampleLocal(askedAt: Date) -> DeviceLocalRecordBody {
	.workoutDrift(WorkoutDriftBody(planWorkoutId: fixedUlid(900), askedAt: askedAt))
}

func messageText(_ record: AthleteRecord) -> String {
	switch record.body {
	case .synced(.userMessage(let body)): body.athleteText
	case .synced(.turnSettled(let body)):
		switch body.settlement {
		case .replied(let reply, _): reply.sentence(in: CatalogPhrasebook(tag: .en))
		case .interrupted(let partial, _, _): partial
		case .failed, .savedWork: ""
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

func kinds(_ records: [AthleteRecord]) -> [String] {
	records.map(\.body.kind)
}

func legacyCancellation(review: WorkoutReviewID, chat: ChatID = .main) throws
	-> ReviewCancelledUnknownBody
{
	let json =
		#"{"chatId":"\#(chat.rawValue)","observation":"absent","review":"\#(review.ulid.rawValue)"}"#
	let decoded = try RecordCodec.decode(
		kind: LegacyKind.reviewCancelledUnknown.rawValue, version: 2, data: Data(json.utf8),
		civilDate: "1998-06-14", ulid: review.ulid.rawValue
	).get()
	guard case .legacy(.reviewCancelledUnknown(let body)) = decoded else {
		throw UnexpectedReview(detail: "the stored cancellation did not decode as a legacy row")
	}
	return body
}
