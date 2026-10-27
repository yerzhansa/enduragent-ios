import EnduragentCoachFixtures
import Foundation
import Testing

@testable import EnduragentCoach

@Suite struct SlashRoutingTests {
	@Test func parseReadsLeadingToken() {
		#expect(SlashRouting.parse("/review deep") == .review)
		#expect(SlashRouting.parse("/status") == .status)
		#expect(SlashRouting.parse("/workout tomorrow") == .workout)
		#expect(SlashRouting.parse("/plan for my gran fondo in June") == .plan)
		#expect(SlashRouting.parse("/plan") == .plan)
		#expect(SlashRouting.parse("/start") == .start)
		#expect(SlashRouting.parse("/language") == .language)
		#expect(SlashRouting.parse("  /language  ") == .language)
		#expect(SlashRouting.parse("/language it") == .language)
		#expect(SlashRouting.parse("hello /review") == nil)
	}

	@Test(arguments: LanguageTag.allCases)
	func welcomeAdvertisesOnlySupportedCommands(tag: LanguageTag) {
		let phrasebook = CatalogPhrasebook(tag: tag)
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

	@Test(arguments: LanguageTag.allCases)
	func welcomeListsPlanAfterWorkoutWithItsTitle(tag: LanguageTag) throws {
		let phrasebook = CatalogPhrasebook(tag: tag)
		let lines = Welcome.text(in: phrasebook).split(separator: "\n").map(String.init)
		let title = phrasebook.say(Catalog.telegramMenuPlan)
		let workout = try #require(lines.firstIndex { $0.hasPrefix("/workout") })

		#expect(
			lines.dropFirst(workout + 1).first
				== phrasebook.say(
					Catalog.chatWelcomeCommand, ["command": "/plan", "description": title]))
		#expect(!title.isEmpty)
		#expect(
			tag == .en ? title == "Generate a training plan" : title != "Generate a training plan")
	}

	@Test func startRoutesToResetAndPlanIsAModelTurn() async throws {
		#expect(SlashRouting.parse("/start")?.route == .resetConversation)
		#expect(SlashRouting.parse("/language")?.route == .languagePicker)
		#expect(SlashRouting.parse("/review")?.route == .modelTurn)
		#expect(SlashRouting.parse("/plan for my gran fondo in June")?.route == .modelTurn)
		let transport = FakeModelTransport()
		let store = InMemoryRecordLog()
		let coach = await makeCoach(transport: transport, store: store)
		transport.respond = ScriptedReply.sequence(
			[.text("Tell me your FTP and weekly hours."), .finish(reason: .stop)], for: .chat,
			otherwise: transport.respond)
		let plan = try await coach.sendAndSettle("/plan for my gran fondo in June")
		#expect(replyText(plan) == "Tell me your FTP and weekly hours.")
		#expect(sent(.chatAttempt, by: transport).count == 1)
		let started = try await coach.send(draft("/start"), to: .main)
		guard case .newConversation(let admission) = started else {
			Issue.record("Expected reset admission")
			return
		}
		#expect(await coach.resetCompletion(admission, in: .main) == .started(memory: .saved))
		#expect(sent(.chatAttempt, by: transport).count == 1)
		let snapshot = try #require(await coach.currentSnapshot(.main))
		#expect(snapshot.turns.isEmpty)
		#expect(snapshot.opening.notice == Catalog.chatNoticeNewConversationSuccess)
		let messages = try await store.fetch(RecordQuery(scope: .synced([.userMessage]))).records
		#expect(messages.map(messageText) == ["/plan for my gran fondo in June"])
		#expect(
			messages.allSatisfy {
				guard case .synced(.userMessage(let body)) = $0.body else { return false }
				return body.slash == .plan
			})
	}
}
