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
}
