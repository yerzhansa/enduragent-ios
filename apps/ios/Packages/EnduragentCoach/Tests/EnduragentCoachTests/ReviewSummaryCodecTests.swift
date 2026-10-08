import Foundation
import Testing

@testable import EnduragentCoach

@Suite struct ReviewSummaryCodecTests {
	@Test func structuredReviewOutcomeDecodes() throws {
		let decoded = decode(#"{"chatId":"main","change":{"deleteWorkout":{}}}"#)
		guard case .success(.synced(.reviewApplied)) = decoded else {
			Issue.record("Structured review outcome was rejected: \(decoded)")
			return
		}
	}

	@Test func legacyReviewOutcomeStillDecodes() throws {
		let decoded = decode(#"{"chatId":"main","summary":"Create a workout"}"#)
		guard case .success(.synced(.reviewApplied)) = decoded else {
			Issue.record("Legacy review outcome was rejected: \(decoded)")
			return
		}
	}

	@Test(arguments: [
		#"{"chatId":"main"}"#,
		#"{"chatId":"main","summary":"old","change":{"deleteWorkout":{}}}"#,
		#"{"chatId":"main","change":{"createStrengthWorkout":{"date":"bad","name":"Core"}}}"#,
	])
	func malformedOrAmbiguousReviewOutcomeIsRejected(_ json: String) {
		guard case .failure = decode(json) else {
			Issue.record("Malformed or ambiguous review outcome was accepted")
			return
		}
	}

	@Test(arguments: [
		ReviewSummary.supplied("Legacy outcome"),
		.createWorkout(name: "Endurance", date: "1998-06-14"),
		.createStrengthWorkout(name: "Core", date: "1998-06-14"),
		.deleteWorkout,
		.updateWorkout(date: nil, name: nil, descriptionChanged: false),
		.updateWorkout(date: "1998-06-14", name: "Endurance", descriptionChanged: true),
		.planSave(name: "Base"),
	])
	func reviewSummaryRoundTrips(_ summary: ReviewSummary) throws {
		let body = RecordBody.synced(
			.reviewApplied(ReviewAppliedBody(chatId: .main, summary: summary)))
		let encoded = try RecordCodec.encode(body)
		let decoded = RecordCodec.decode(
			kind: "reviewApplied", version: encoded.version, data: encoded.data,
			civilDate: "1998-06-14", ulid: fixedUlid(1).rawValue)
		#expect(try decoded.get() == body)
	}

	@Test func summaryDoesNotSyncTheWorkoutDescriptionOrEventID() throws {
		let summary = ReviewSummary(
			.updateWorkout(
				UpdateWorkoutInput(
					eventId: EventID(rawValue: 424242), date: nil, name: "Ride",
					description: "private workout structure")))
		let encoded = try RecordCodec.encode(
			.synced(
				.reviewApplied(
					ReviewAppliedBody(chatId: .main, summary: summary))))
		let json = String(decoding: encoded.data, as: UTF8.self)
		#expect(!json.contains("private workout structure"))
		#expect(!json.contains("424242"))
	}

	@Test func generatedFallbacksUseTheChosenLanguage() {
		let french = LanguageTag.fr.phrasebook
		#expect(
			ReviewSummary.deleteWorkout.sentence(in: displayLocale(.fr))
				== "Supprimer un entraînement")
		#expect(
			ReviewSummary.updateWorkout(date: nil, name: nil, descriptionChanged: true)
				.sentence(in: displayLocale(.fr)) == "Mettre à jour un entraînement — description")
		#expect(
			ReviewSummary.updateWorkout(date: nil, name: nil, descriptionChanged: false)
				.sentence(in: displayLocale(.fr))
				== "Mettre à jour un entraînement — champs sélectionnés")
	}

	private func decode(_ json: String) -> Result<RecordBody, SkippedRow> {
		RecordCodec.decode(
			kind: "reviewApplied", version: 2, data: Data(json.utf8),
			civilDate: "1998-06-14", ulid: fixedUlid(1).rawValue)
	}
}
