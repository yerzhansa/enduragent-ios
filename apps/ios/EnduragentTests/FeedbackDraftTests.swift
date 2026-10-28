import EnduragentCoach
import EnduragentCoachFixtures
import Foundation
import Testing

@testable import Enduragent

@MainActor
@Suite(.serialized, FixtureTestScope())
struct FeedbackDraftTests {
	private let harness = FixtureLaunchTests()

	@Test func receivedClearsOnlyTheDraftThatWasSent() async throws {
		let services = try harness.services()
		let server = try #require(services.fixture?.feedback)
		let model = await harness.model(services)
		let support = model.support
		let observing = Task { await support.appear() }
		defer { observing.cancel() }
		try await until { support.snapshot != nil }
		support.draft = "The plan card skipped Tuesday."
		await support.send()
		#expect(support.draft == "")
		try await until { support.line.sentence == Catalog.feedbackReceived }
		server.hold(onArrival: {})
		support.draft = "The lap table is cut off."
		let sending = Task { await support.send() }
		try await until { server.requestCount == 2 }
		try await until { support.line.sentence == Catalog.feedbackSending }
		support.draft = "The lap table is cut off on the right."
		server.release()
		await sending.value
		try await until { support.line.sentence == Catalog.feedbackReceived }
		#expect(server.storedCount == 2)
		#expect(support.draft == "The lap table is cut off on the right.")
	}
}
