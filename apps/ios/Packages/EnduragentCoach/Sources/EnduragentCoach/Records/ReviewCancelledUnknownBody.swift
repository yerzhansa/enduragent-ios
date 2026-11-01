import Foundation

package struct ReviewCancelledUnknownBody: Sendable, Equatable {
	package let chatId: ChatID
	package let review: WorkoutReviewID
	package let key: CalendarWriteKey
	package let observation: CalendarObservation

	fileprivate init(
		chatId: ChatID, review: WorkoutReviewID, key: CalendarWriteKey,
		observation: CalendarObservation
	) {
		self.chatId = chatId
		self.review = review
		self.key = key
		self.observation = observation
	}

	static func validated(in records: [AthleteRecord]) -> [AthleteRecord] {
		var markers: [AthleteRecord] = []
		for marker in records.sorted(by: { $0.hlc < $1.hlc }) {
			guard case .legacy(.reviewCancelledUnknown(let body)) = marker.body,
				case .operation = marker.cause,
				!markers.contains(where: {
					guard case .legacy(.reviewCancelledUnknown(let known)) = $0.body else {
						return false
					}
					return $0.account == marker.account && $0.deviceId == marker.deviceId
						&& known.chatId == body.chatId && known.review == body.review
						&& known.key == body.key
				})
			else { continue }
			let writes = records.filter { record in
				guard case .legacy(.reviewWrite(let write)) = record.body else { return false }
				return record.hlc < marker.hlc && record.deviceId == marker.deviceId
					&& record.account == marker.account && record.cause == marker.cause
					&& write.chatId == body.chatId && write.review == body.review
					&& write.key == body.key
			}.sorted { $0.hlc < $1.hlc }
			let evidence = writes.reduce(CalendarWriteEvidence.notSent) { evidence, record in
				guard case .legacy(.reviewWrite(let write)) = record.body else { return evidence }
				return evidence.merging(write.evidence)
			}
			guard case .unknown = evidence else { continue }
			markers.append(marker)
		}
		return markers
	}
}

struct ReviewCancelledUnknownPayload: Decodable {
	let chatId: String
	let review: String
	let writeID: UUID?
	let observation: CalendarObservation

	func body() throws -> ReviewCancelledUnknownBody {
		let set = WorkoutReviewID(ulid: try decodeULID(review))
		return ReviewCancelledUnknownBody(
			chatId: try decodeChatID(chatId), review: set,
			key: writeID.map { .durable(CalendarWriteID(rawValue: $0)) } ?? .legacy(set),
			observation: observation)
	}
}
