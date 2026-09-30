import Foundation
import Testing

@testable import EnduragentCoach

@Suite struct SlashRoutingTests {
	@Test func parseReadsLeadingToken() {
		#expect(SlashRouting.parse("/review deep") == .review)
		#expect(SlashRouting.parse("/status") == .status)
		#expect(SlashRouting.parse("/workout tomorrow") == .workout)
		#expect(SlashRouting.parse("/start") == .start)
		#expect(SlashRouting.parse("/language") == .language)
		#expect(SlashRouting.parse("hello /review") == nil)
	}

	@Test(arguments: LanguageTag.allCases)
	func welcomeAdvertisesOnlySupportedCommands(tag: LanguageTag) {
		let phrasebook = CatalogPhrasebook(tag: tag, locale: tag.defaultLocale)
		let text = Welcome.text(in: phrasebook)
		let advertised = text.matches(of: /\/[a-z]+/).map { String($0.output) }
		#expect(advertised.count == SlashCommand.allCases.count)
		for command in advertised {
			#expect(SlashRouting.parse(command) != nil)
		}
		#expect(Set(advertised.compactMap(SlashRouting.parse)) == Set(SlashCommand.allCases))
		for command in SlashCommand.allCases {
			#expect(text.contains(phrasebook.say(command.menuTitle)))
		}
	}

	@Test func startRoutesToResetAndPlanIsFreeText() async throws {
		#expect(SlashRouting.parse("/start")?.route == .resetConversation)
		#expect(SlashRouting.parse("/language")?.route == .languagePicker)
		#expect(SlashRouting.parse("/review")?.route == .modelTurn)
		#expect(SlashRouting.parse("/plan") == nil)
		let transport = FakeModelTransport()
		let store = InMemoryRecordLog()
		let coach = makeCoach(transport: transport, store: store)
		transport.script = [.text("Plans come in a later release."), .finish(reason: .stop)]
		let plan = try await coach.sendAndSettle("/plan")
		#expect(replyText(plan) == "Plans come in a later release.")
		#expect(sent(.chatAttempt, by: transport).count == 1)
		let started = try await coach.send(draft("/start"), to: .main)
		#expect(started == .newConversation(.started(memory: .saved)))
		#expect(sent(.chatAttempt, by: transport).count == 1)
		let snapshot = try #require(await coach.currentSnapshot(.main))
		#expect(snapshot.turns.isEmpty)
		#expect(snapshot.opening == .afterNewConversation(memorySaved: true))
		let messages = try await store.fetch(RecordQuery(scope: .synced([.userMessage]))).records
		#expect(messages.map(messageText) == ["/plan"])
		#expect(
			messages.allSatisfy {
				guard case .synced(.userMessage(let body)) = $0.body else { return false }
				return body.slash == nil
			})
	}
}
