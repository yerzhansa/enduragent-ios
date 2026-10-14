import EnduragentCoachFixtures
import Foundation
import Testing

@testable import EnduragentCoach

extension IntervalsRESTClientTests {
	@Suite struct SnapshotWiderProfileTests {
		@Test func profileLineNamesOnlyTheSliceOneReadingsOfAFullProfile() async throws {
			let system = try await systemPrompt(athlete: try fixtureData("intervals-athlete"))

			#expect(
				profileLines(of: system) == [
					"Profile: FTP 250 W · LTHR 165 bpm · max HR 185 bpm · resting HR 48 bpm · weight 58 kg"
				])
		}

		@Test func profileHoldingOnlyAddedReadingsHasNoProfileLine() async throws {
			let athlete = """
				{"id":"i1001","name":"Ada","sportSettings":[{"types":["Ride"],"indoor_ftp":245,\
				"w_prime":20000,"p_max":1100,"sweet_spot_min":84,"sweet_spot_max":97}]}
				"""
			let clock = FixedClock(now: "1998-06-13T08:00:00+02:00", timeZone: "Europe/Amsterdam")
			let held = try await stubbedClient(clock: clock, athlete: Data(athlete.utf8)).profile()
			#expect(held.readings[.wPrime] == 20000)
			#expect(held.readings[.maxPower] == 1100)

			let system = try await systemPrompt(athlete: Data(athlete.utf8))

			#expect(system.contains(PromptStaticBlocks.snapshotHeading + "\n\nWellness "))
			#expect(profileLines(of: system) == [])
		}

		private func profileLines(of system: String) -> [String] {
			system.split(separator: "\n").map(String.init).filter { $0.hasPrefix("Profile:") }
		}

		private func systemPrompt(athlete: Data) async throws -> String {
			let transport = FakeModelTransport()
			let clock = FixedClock(now: "1998-06-13T08:00:00+02:00", timeZone: "Europe/Amsterdam")
			let coach = await makeCoach(
				transport: transport, intervals: try stubbedClient(clock: clock, athlete: athlete),
				store: InMemoryRecordLog(), clock: clock)
			_ = try await coach.sendAndSettle("How is my form?")
			return try #require(transport.requests.first?.messages.first?.content)
		}

		private func stubbedClient(clock: FixedClock, athlete: Data) throws -> IntervalsRESTClient {
			let client = try IntervalsRESTClientTests().makeClient(clock: clock)
			IntervalsURLProtocolStub.handler = { request in
				let path = try #require(request.url).path
				if path.contains("/wellness") {
					return (200, try fixtureData("intervals-wellness"))
				}
				return (200, athlete)
			}
			return client
		}
	}
}
