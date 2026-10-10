import EnduragentCoachFixtures
import Testing

@testable import EnduragentCoach

extension SwiftDataSuites {
	struct ResetAdmissionPersistenceTests {
		@Test func aMeanwhileMessageSurvivesReopenOutsideHistory() async throws {
			let directory = try TestTemporaryFolders.make()
			let device = DeviceID()
			let transport = FakeModelTransport()
			transport.respond = ScriptedReply.sequence(
				[
					.text("Old answer"), .finish(reason: .stop), .text("New answer"),
					.finish(reason: .stop),
				],
				otherwise: transport.respond)
			do {
				let fixture = try FixtureRecordStore(directory: directory, deviceId: device)
				let held = HeldAppendLog(
					inner: fixture.faults.log, holding: "turnSettled", occurrence: 1)
				defer { held.release() }
				let coach = await makeCoach(transport: transport, store: held)
				_ = try await coach.send(draft("Old question"), to: .main)
				try await held.waitUntilReached()
				_ = try #require(
					try await beforeDeadline(within: .hangGuard, onTimeout: held.release) {
						try await coach.send(draft("/start"), to: .main)
					})
				let next = try #require(
					try await coach.send(draft("New question"), to: .main).acceptedTurn)
				held.release()
				_ = try #require(await coach.settledState(of: next, in: .main, within: .hangGuard))
				await coach.lifecycle(.willTerminate)
			}
			let fixture = try FixtureRecordStore(directory: directory, deviceId: device)
			let reopened = await makeCoach(transport: transport, store: fixture.faults.log)
			#expect(await reopened.transcript(.main) == ["New question", "New answer"])
			let archived = try #require(try await reopened.history().first?.id)
			#expect(
				try await reopened.archivedConversation(archived)?.turns.map(\.athleteText) == [
					"Old question"
				])
			await reopened.lifecycle(.willTerminate)
		}
	}
}
