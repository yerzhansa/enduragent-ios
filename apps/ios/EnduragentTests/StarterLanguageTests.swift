import EnduragentCoach
import Testing

@testable import Enduragent

extension FixtureLaunchTests {
	@Test(arguments: [
		(GrantOutcome.minted(Credits(units: 200)), "200 créditos"),
		(GrantOutcome.toppedUp(added: Credits(units: 200)), "Se añadieron 200 créditos"),
		(GrantOutcome.alreadyGranted, "200 créditos"),
	])
	func starterOutcomeUsesTheChosenLanguage(outcome: GrantOutcome, expected: String) async throws {
		let services = try services()
		let fixture = try #require(services.fixtureDirector)
		fixture.credits.grantResult = .success(outcome)
		try await services.coach.setLanguage(.fixed(.es))
		let model = ShellModel(
			environment: environment(services),
			initialLanguage: await services.coach.languagePreference())
		await model.loadStarter()
		#expect(model.starterResolved)
		#expect(model.starterLine == expected)
	}

	@Test func alreadyGrantedWithoutAKeyUsesTheChosenLanguage() async throws {
		let services = try services(keychain: .empty)
		let fixture = try #require(services.fixtureDirector)
		fixture.credits.grantResult = .success(.alreadyGranted)
		try await services.coach.setLanguage(.fixed(.es))
		let model = ShellModel(
			environment: environment(services),
			initialLanguage: await services.coach.languagePreference())
		await model.loadStarter()
		#expect(model.starterResolved)
		#expect(model.starterLine == "Este dispositivo ya utilizó sus créditos iniciales.")
	}
}
