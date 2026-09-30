import Foundation
import Testing

@testable import EnduragentCoach

@Suite struct TurnEvidenceTests {
	let transport = FakeModelTransport()
	let intervals = FakeIntervalsClient(athleteName: "Ada", ftp: 250)
	let clock = FixedClock(now: "1998-06-13T08:00:00+02:00", timeZone: "Europe/Amsterdam")

	@Test func failedWellnessReadOmitsLineAndLogsDiagnostics() async throws {
		let failure = IntervalsError(code: "http", details: "status 503", status: 503)
		intervals.loadFailure = failure
		transport.script = [.text("Easy spin today."), .finish(reason: .stop)]
		let coach = await makeCoach(
			transport: transport, intervals: intervals, store: InMemoryRecordLog(), clock: clock)

		let settled = try await coach.sendAndSettle("How is my form?")

		guard case .completed = settled else {
			Issue.record("expected the reply, got \(settled)")
			return
		}
		let request = try #require(transport.requests.first)
		let system = try #require(request.messages.first?.content)
		#expect(system.contains(PromptStaticBlocks.snapshotFallback))
		#expect(!system.contains(" · Fatigue "))
		#expect(
			coach.diagnostics.entries.map(\.event).contains(
				.evidenceUnavailable(request.attempt, .temporarilyUnavailable)))
	}

	@Test func wellnessLineCarriesTheLatestDay() async throws {
		intervals.wellness = [
			WellnessDay(date: "1998-06-12", fitness: 50, fatigue: 40, form: 10),
			WellnessDay(date: "1998-06-13", fitness: 55.2, fatigue: 42.1, form: 13.1),
		]
		transport.script = [.text("Easy spin today."), .finish(reason: .stop)]
		let coach = await makeCoach(
			transport: transport, intervals: intervals, store: InMemoryRecordLog(), clock: clock)

		_ = try await coach.sendAndSettle("How is my form?")

		let system = try #require(transport.requests.first?.messages.first?.content)
		#expect(system.contains("Fitness 55.2 · Fatigue 42.1 · Form +13.1"))
		#expect(!system.contains(PromptStaticBlocks.snapshotFallback))
		#expect(coach.diagnostics.entries.isEmpty)
	}

	@Test func unconnectedAthleteReadsNoWellnessAndLogsNothing() async throws {
		let secrets = FakeSecretStore()
		try secrets.storeCreditsAccount(
			CreditsAccount(appAccountToken: UUID(), key: testKey))
		transport.script = [.text("Easy spin today."), .finish(reason: .stop)]
		let coach = await makeCoach(
			transport: transport, intervals: intervals, store: InMemoryRecordLog(), clock: clock,
			secrets: secrets)

		_ = try await coach.sendAndSettle("How is my form?")

		let system = try #require(transport.requests.first?.messages.first?.content)
		#expect(system.contains(PromptStaticBlocks.snapshotFallback))
		#expect(coach.diagnostics.entries.isEmpty)
	}
}
