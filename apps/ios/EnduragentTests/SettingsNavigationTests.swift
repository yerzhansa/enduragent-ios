import EnduragentCoach
import Testing

@testable import Enduragent

extension FixtureLaunchTests {
	@Test(arguments: [false, true])
	func restoredSlashDraftShowsCommandsAfterSettingsRelaunch(connected: Bool) async throws {
		let draft: Draft
		do {
			let first = await model(try services())
			first.continueNotice()
			if connected {
				first.connectKey = "fixture"
				await first.connect()
				try #require(first.didConnect)
				first.continueConnect()
			} else {
				first.skipConnect()
			}
			await first.agreeAndStartChatting()
			first.draft.text = "/"
			first.draftChanged(from: "")
			try #require(first.slashListVisible)
			first.open(.settings)
			draft = first.draft
		}
		let (kept, keptDefaults) = try await relaunch(.keep)
		let reopened = await fixtureModel(
			environment: AppEnvironment(services: kept, defaults: keptDefaults))
		try await observed(reopened)
		#expect(reopened.route == .chat)
		#expect(reopened.navigation.isEmpty)
		#expect(reopened.draft == draft)
		try #require(reopened.slashListVisible)
		reopened.fillSlash(.review)
		#expect(reopened.draft.text == "/review ")
		#expect(!reopened.slashListVisible)
	}

	@Test(arguments: [false, true])
	func settingsAndHistoryKeepConversationDraftAndSetupAfterRelaunch(connected: Bool) async throws
	{
		let draft: Draft
		let snapshot: ChatSnapshot
		let training: TrainingStatus
		do {
			let services = try services()
			let first = await model(services)
			first.continueNotice()
			if connected {
				first.connectKey = "fixture"
				await first.connect()
				try #require(first.didConnect)
				first.continueConnect()
			} else {
				first.skipConnect()
			}
			await first.loadStarter()
			await first.agreeAndStartChatting()
			try await observed(first)
			first.draft.text = TutorialCopy.weekQuestion
			await first.send()
			_ = try await settledTurn(first)
			first.draft.text = "Is Thursday still on?"
			first.draftChanged(from: "")
			draft = first.draft
			snapshot = try #require(first.chat)
			training = try await services.coach.observedStatus().training
			try await proveSettingsNavigation(first, snapshot: snapshot, draft: draft)
			#expect(try await services.coach.observedStatus().training == training)
		}
		let (kept, keptDefaults) = try await relaunch(.keep)
		let reopened = await fixtureModel(
			environment: AppEnvironment(services: kept, defaults: keptDefaults))
		try await observed(reopened)
		#expect(reopened.navigation.isEmpty)
		#expect(reopened.chat?.turns == snapshot.turns)
		#expect(reopened.draft == draft)
		try await proveSettingsNavigation(
			reopened, snapshot: try #require(reopened.chat), draft: draft)
		#expect(try await kept.coach.observedStatus().training == training)
		#expect(FixtureBlockingURLProtocol.requestCount == 0)
	}

	private func proveSettingsNavigation(
		_ model: ShellModel, snapshot: ChatSnapshot, draft: Draft
	) async throws {
		let transport = try #require(model.services.fixtureTransport)
		let requestCount = transport.requestCount
		model.open(.settings)
		#expect(model.navigation == [.settings])
		await model.chooseLanguage(.fixed(.fr))
		try await model.waitForStatus { $0.language == .fixed(.fr) }
		#expect(model.navigation == [.settings])
		model.open(.credits)
		#expect(model.navigation == [.settings, .credits])
		await model.loadCredits()
		#expect(model.balance?.units == 200)
		#expect(model.catalog?.packs.count == 2)
		model.navigation.removeAll()
		model.open(.history)
		#expect(model.navigation == [.history])
		await model.loadHistory()
		#expect(model.history == .loaded([]))
		model.navigation.removeAll()
		#expect(model.route == .chat)
		#expect(model.chat == snapshot)
		#expect(model.draft == draft)
		#expect(transport.requestCount == requestCount)
	}

	@Test func newConversationAfterSettingsArchivesAndKeepsCommandDiscovery() async throws {
		let model = await model(try services())
		await model.agreeAndStartChatting()
		model.draft.text = TutorialCopy.weekQuestion
		await model.send()
		let turn = try await settledTurn(model)
		model.open(.settings)
		model.navigation.removeAll()
		await model.newConversation()
		try await until { model.chat?.opening.showsWelcome == true }
		model.open(.history)
		await model.loadHistory()
		guard case .loaded(let archived) = model.history else {
			Issue.record("History did not load")
			return
		}
		let ref = try #require(archived.first?.id)
		model.open(.archivedConversation(ref))
		#expect(model.navigation == [.history, .archivedConversation(ref)])
		guard case .loaded(let content) = await model.loadArchivedConversation(ref) else {
			Issue.record("Archived conversation did not open")
			return
		}
		#expect(content.turns.map(\.id) == [turn.id])
		model.navigation.removeAll()
		model.draft.text = "/"
		model.draftChanged(from: "")
		#expect(model.slashListVisible)
		model.fillSlash(.review)
		#expect(model.draft.text == "/review ")
	}

	@Test func creditsFromModelAccessReturnsToSettingsAfterOneBack() async throws {
		let model = await model(try services())
		await model.agreeAndStartChatting()
		model.open(.settings)
		model.open(.credits)
		try #require(model.navigation == [.settings, .credits])
		await model.loadCredits()
		model.navigation.removeLast()
		#expect(model.navigation == [.settings])
		#expect(model.route == .chat)
	}

	@Test(arguments: [
		ShellDestination.debugCredits, .debugRecords, .debugLanguage,
		.session, .debugLeases,
	])
	func debugDestinationsStayOnPathWhenSnapshotsChange(destination: ShellDestination) async throws
	{
		let model = await model(try services())
		await model.agreeAndStartChatting()
		model.open(.settings)
		model.open(.debug)
		model.open(destination)
		let path: [ShellDestination] = [.settings, .debug, destination]
		try #require(model.navigation == path)
		await model.chooseLanguage(.fixed(.fr))
		try await model.waitForStatus { $0.language == .fixed(.fr) }
		#expect(model.navigation == path)
		model.draft.text = TutorialCopy.weekQuestion
		await model.send()
		_ = try await settledTurn(model)
		#expect(model.navigation == path)
		#expect(model.route == .chat)
		model.navigation.removeLast()
		#expect(model.navigation == [.settings, .debug])
	}
}
