import EnduragentCoach
import EnduragentCoachFixtures
import Testing

@testable import Enduragent

extension FixtureLaunchTests {
	@Test(arguments: ["fixture:step-limit", "fixture:memory-then-step-limit"])
	func stepLimitDirectiveUsesTheChosenLanguage(directive: String) async throws {
		let services = try services()
		try await services.coach.setLanguage(.fixed(.fr))
		let model = fixtureModel(
			environment: environment(services), initialLanguage: .fixed(.fr))
		await model.agreeAndStartChatting()
		model.draft.text = directive
		await model.send()
		let turn = try await settledTurn(model)
		guard case .completed(let completed) = turn.state else {
			Issue.record("Expected the step-limit reply, got \(turn.state)")
			return
		}
		#expect(completed.reply == .catalog(Catalog.coachFallbackStepLimit))
		let source = completed.reply.sentence(in: model.phrasebook)
		#expect(
			source
				== "J’ai atteint ma limite d’étapes en recueillant les données — demande-moi de continuer et je reprendrai là où je me suis arrêté."
		)
		#expect(services.replyParser.document(source).accessibilityText == source)
		#expect(!turn.state.retryable)
		#expect(try #require(services.fixtureTransport).requestCount == 11)
	}
}
