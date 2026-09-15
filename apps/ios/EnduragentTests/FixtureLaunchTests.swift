import EnduragentCoach
import Foundation
import Testing
@testable import Enduragent

@MainActor
struct FixtureLaunchTests {
	@Test func fixtureArgumentBuildsCoachFromFakes() async throws {
		let services = try #require(AppServices.fixture(named: "first-week"))
		#expect(services.isFixture)
		#expect(try await services.intervals.fetchAthlete().name == "Ada Kovač")
		let language = Language.uiTag(systemLanguages: Locale.preferredLanguages)
		let model = ShellModel(builder: ServicesBuilder(fixture: services, language: language))
		await model.send("/plan")
		#expect(model.errorLine == "Plans arrive in the next TestFlight.")
		#expect(model.seam.transcript.isEmpty)
	}

	@Test func starterScreenResolvesOnlyAfterGrant() async throws {
		let services = try #require(AppServices.fixture(named: "first-week"))
		let language = Language.uiTag(systemLanguages: Locale.preferredLanguages)
		let model = ShellModel(builder: ServicesBuilder(fixture: services, language: language))
		#expect(model.starterResolved == false)
		await model.loadStarter()
		#expect(model.starterResolved)
		#expect(model.starterLine == "200 credits")
	}

	@Test func skippingConnectMovesToStarterWithoutAthlete() throws {
		let services = try #require(AppServices.fixture(named: "first-week"))
		let language = Language.uiTag(systemLanguages: Locale.preferredLanguages)
		let model = ShellModel(builder: ServicesBuilder(fixture: services, language: language))
		model.continueNotice()
		model.skipConnect()
		#expect(model.route == .onboarding(.starter))
		#expect(model.athlete == nil)
		#expect(model.athleteFirstName.isEmpty)
	}

	@Test func alreadyGrantedWithStoredKeyShowsBalance() async throws {
		let services = try #require(AppServices.fixture(named: "first-week"))
		let credits = try #require(services.credits as? FakeCreditsClient)
		credits.grantResult = .success(.alreadyGranted)
		try services.secrets.storeOpenRouterKey("sk-or-test-0000")
		let language = Language.uiTag(systemLanguages: Locale.preferredLanguages)
		let model = ShellModel(builder: ServicesBuilder(fixture: services, language: language))
		await model.loadStarter()
		#expect(model.starterLine == "200 credits")
	}
}
