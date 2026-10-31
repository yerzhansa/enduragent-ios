import EnduragentCoachFixtures
import Foundation
import Testing

@testable import EnduragentCoach

enum PreparationFixture {
	static let key = DraftKey(
		turn: TurnID(ulid: reviewULID(700)), attempt: AttemptID(ulid: reviewULID(701)))

	static let ride =
		#"{"kind":"add-cycling","date":"DATE","workout":{"name":"Threshold 2x2","steps":[{"type":"warmup","duration":{"value":5,"unit":"minutes"},"power":{"kind":"percent_ftp","value":55}},{"type":"interval","duration":{"value":20,"unit":"minutes"},"power":{"kind":"percent_ftp","value":90}}]},"trainingLoad":48}"#

	static let strength =
		#"{"kind":"add-strength","date":"DATE","name":"Core","durationMinutes":30,"effort":"Easy","description":"Plank 3x45s"}"#

	static func ride(on date: CivilDate) -> String {
		ride.replacingOccurrences(of: "DATE", with: date.rawValue)
	}

	static func strength(on date: CivilDate) -> String {
		strength.replacingOccurrences(of: "DATE", with: date.rawValue)
	}

	static func workout(
		_ id: Int, on date: CivilDate, name: String? = "Endurance", owned: Bool = true,
		category: String = "WORKOUT", minutes: Int? = 60
	) -> CalendarEvent {
		CalendarEvent(
			description: "Steady ride", id: EventID(rawValue: id),
			startDateLocal: "\(date.rawValue)T00:00:00", name: name, category: category,
			externalId: nil, uid: nil, tags: owned ? [IntervalsPolicy.coachTag] : [],
			coachCreated: owned, movingTime: minutes.map { $0 * 60 }, trainingLoad: 40)
	}

	static func request(_ preparation: String, today: CivilDate) throws -> PreparationRequest {
		try PreparationRequest(
			arguments: try JSONValue.parse(#"{"preparation":\#(preparation)}"#), today: today)
	}

	static func draft(
		_ request: PreparationRequest, head: WorkoutReview? = nil, reads: any CalendarReads,
		today: CivilDate
	) async -> Result<ReviewDraft, PreparationRefusal> {
		do {
			return .success(
				try await Preparation.draft(
					request, key: key, chat: .main, binding: testStamp().binding, head: head,
					reads: reads, today: today))
		} catch {
			return .failure(error)
		}
	}
}

extension Result where Success == ReviewDraft, Failure == PreparationRefusal {
	var draft: ReviewDraft? {
		guard case .success(let draft) = self else { return nil }
		return draft
	}

	var remaining: [ProposedTarget]? {
		guard case .success(let draft) = self, case .changes(let remaining, _) = draft.content
		else { return nil }
		return remaining
	}

	var kept: [KeptWorkout]? {
		guard case .success(let draft) = self, case .changes(_, let kept) = draft.content else {
			return nil
		}
		return kept
	}

	var refusal: PreparationRefusal? {
		guard case .failure(let refusal) = self else { return nil }
		return refusal
	}
}
