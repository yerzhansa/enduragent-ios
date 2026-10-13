import EnduragentCoachFixtures
import Foundation
import Testing

@testable import EnduragentCoach

extension TrainingSnapshotTests {
	@Test func snapshotDiagnosticsCarryNoAddressAndNoMeasurement() async throws {
		let url = try #require(
			URL(
				string:
					"https://intervals.icu/api/v1/athlete/i424242/wellness?oldest=1998-06-07&newest=1998-06-13"
			))
		intervals.athlete = AthleteProfile(
			id: "i424242", name: "Ada", ftp: FTPReading(.number(251.37)),
			readings: Readings([.weight: 71.37]))
		let coach = try await coach()
		intervals.fail(
			.wellness, with: URLError(.timedOut, userInfo: [NSURLErrorFailingURLErrorKey: url]))
		_ = try await coach.sendAndSettle("How is my form?")
		let held = intervals.hold(.profile)
		let turn = try #require(try await coach.send(draft("And now?"), to: .main).acceptedTurn)
		try #require(try await entered(held))
		try await watchdog.waitUntilHeld(SnapshotPolicy.deadline)
		watchdog.release(SnapshotPolicy.deadline)
		_ = try #require(await coach.settledState(of: turn, in: .main, within: .hangGuard))

		let attempts = transport.requests.map(\.attempt)
		#expect(
			coach.diagnostics.entries.map(\.event) == [
				.snapshotReadFailed(
					try #require(attempts.first), .wellness, .temporarilyUnavailable),
				.snapshotReadFailed(
					try #require(attempts.last), .wellness, .temporarilyUnavailable),
				.snapshotDeadlineMissed(try #require(attempts.last)),
			])
		let detail = coach.diagnostics.entries.map { String(describing: $0.event) }.joined()
		for leaked in ["i424242", "1998-06-07", "1998-06-13", "intervals.icu", "251.37", "71.37"] {
			#expect(!detail.contains(leaked))
		}
		let system = try #require(transport.requests.first?.messages.first?.content)
		#expect(system.contains("Profile: FTP 251.4 W · weight 71.4 kg"))
		#expect(!system.contains("i424242"))
	}
}
