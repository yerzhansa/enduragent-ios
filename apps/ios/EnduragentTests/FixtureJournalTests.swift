import EnduragentCoach
import EnduragentCoachFixtures
import Foundation
import Testing

@testable import Enduragent

@MainActor
@Suite(.serialized, FixtureTestScope())
struct FixtureJournalTests {
	private let harness = FixtureLaunchTests()

	@Test func theFirstRecordedEventIsWrittenIntoTheFixtureDirectory() async throws {
		let file = harness.launch.directory.appending(path: "diagnostics.jsonl")
		let services = try harness.services(keychain: .unavailable)
		#expect(!FileManager.default.fileExists(atPath: file.path))
		let model = await harness.model(services)
		await model.appear()
		let deadline = ContinuousClock.now + TestWaitLimit.hangGuard.duration
		while !FileManager.default.fileExists(atPath: file.path), ContinuousClock.now < deadline {
			try await Task.sleep(for: .milliseconds(20))
		}
		let written = String(decoding: try Data(contentsOf: file), as: UTF8.self)
		#expect(written.hasSuffix("\n"))
		#expect(written.contains(#""kind":"secureStorageFailed""#))
	}
}
