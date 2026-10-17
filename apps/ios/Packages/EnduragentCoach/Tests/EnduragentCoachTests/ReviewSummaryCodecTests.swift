import EnduragentCoachFixtures
import Foundation
import Testing

@testable import EnduragentCoach

@Suite struct ReviewSummaryCodecTests {
	@Test func structuredReviewOutcomeDecodes() throws {
		let decoded = decode(#"{"chatId":"main","change":{"deleteWorkout":{}}}"#)
		guard case .success(.legacy(.reviewApplied)) = decoded else {
			Issue.record("Structured review outcome was rejected: \(decoded)")
			return
		}
	}

	@Test func legacyReviewOutcomeStillDecodes() throws {
		let decoded = decode(#"{"chatId":"main","summary":"Create a workout"}"#)
		guard case .success(.legacy(.reviewApplied)) = decoded else {
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
		(#"{"chatId":"main","summary":"Legacy outcome"}"#, ReviewSummary.supplied("Legacy outcome")),
		(
			#"{"chatId":"main","change":{"createWorkout":{"name":"Endurance","date":"1998-06-14"}}}"#,
			.createWorkout(name: "Endurance", date: "1998-06-14")
		),
		(
			#"{"chatId":"main","change":{"createStrengthWorkout":{"name":"Core","date":"1998-06-14"}}}"#,
			.createStrengthWorkout(name: "Core", date: "1998-06-14")
		),
		(#"{"chatId":"main","change":{"deleteWorkout":{}}}"#, .deleteWorkout),
		(
			#"{"chatId":"main","change":{"updateWorkout":{"descriptionChanged":false}}}"#,
			.updateWorkout(date: nil, name: nil, descriptionChanged: false)
		),
		(
			#"{"chatId":"main","change":{"updateWorkout":{"date":"1998-06-14","name":"Endurance","descriptionChanged":true}}}"#,
			.updateWorkout(date: "1998-06-14", name: "Endurance", descriptionChanged: true)
		),
		(#"{"chatId":"main","change":{"planSave":{"name":"Base"}}}"#, .planSave(name: "Base")),
	])
	func everyStoredSummaryShapeDecodes(_ json: String, _ summary: ReviewSummary) throws {
		#expect(
			try decode(json).get()
				== .legacy(.reviewApplied(ReviewAppliedBody(chatId: .main, summary: summary))))
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
