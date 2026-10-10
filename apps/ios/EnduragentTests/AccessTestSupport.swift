import EnduragentCoach
import EnduragentCoachFixtures
import Synchronization
import Testing

@testable import Enduragent

extension FixtureLaunchTests {
	func reopen(language: LanguageTag? = nil) async throws -> ShellModel {
		let (services, defaults) = try await relaunch(.keep, language: language)
		let model = await fixtureModel(
			environment: AppEnvironment(services: services, defaults: defaults))
		try await observed(model)
		return model
	}

	func proveToolTurn(
		_ shell: ShellModel, method: AccessMethod, key: String? = nil, model: ModelID
	) async throws {
		let transport = try #require(shell.services.fixtureTransport)
		let respond = transport.respond
		let requests = Mutex<[ScriptedRequest]>([])
		transport.respond = { request in
			requests.withLock { $0.append(request) }
			return respond(request)
		}
		let index = try #require(shell.chat).turns.count
		shell.draft.text = FirstWeekFixture.trainingDataDirective
		await shell.send()
		let turn = try await settledTurn(shell, at: index)
		#expect(replyText(turn.state) == "I can read Ada Kovač's training profile and calendar.")
		let sent = requests.withLock { $0.filter { $0.purpose == .chat } }
		try #require(sent.count >= 2)
		#expect(sent.contains { !$0.toolResults.isEmpty })
		#expect(sent.allSatisfy { $0.accessMethod == method && $0.model == model })
		if let key { #expect(sent.allSatisfy { $0.credential == key }) }
	}
}
