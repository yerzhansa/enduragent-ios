import Foundation
import Testing

@testable import EnduragentCoach

@Suite struct TrainingSnapshotTests {
	let clock = FixedClock(now: "1998-06-13T08:00:00+02:00", timeZone: "Europe/Amsterdam")
	let client = FakeIntervalsClient(athleteName: "Ada", ftp: 250)

	@Test func wellnessCancellationPropagatesWithoutAnOutageDiagnostic() async throws {
		client.loadFailure = CancellationError()
		let diagnostics = DiagnosticsLog(clock: clock)
		await #expect(throws: CancellationError.self) {
			try await connection().loadSnapshot(
				clock: clock, attempt: AttemptID(ulid: fixedUlid(1)), diagnostics: diagnostics)
		}
		#expect(diagnostics.entries.isEmpty)
	}

	@Test(arguments: [
		(401, TrainingFailure.credentialRejected), (403, .credentialRejected),
		(422, .requestRejected), (503, .temporarilyUnavailable),
	])
	func wellnessDiagnosticPreservesTheFailureClassification(
		status: Int, failure: TrainingFailure
	) async throws {
		client.loadFailure = IntervalsError(
			code: "failed", details: "private upstream detail", status: status)
		let diagnostics = DiagnosticsLog(clock: clock)
		let attempt = AttemptID(ulid: fixedUlid(1))
		#expect(
			try await connection().loadSnapshot(
				clock: clock, attempt: attempt, diagnostics: diagnostics) == nil)
		#expect(diagnostics.entries.map(\.event) == [.trainingUnavailable(attempt, failure)])
	}

	private func connection() throws -> TrainingConnection {
		TrainingConnection(
			account: .intervals(
				connection: try #require(testConnection.id), athlete: testConnection.resolvedAthlete
			),
			client: client)
	}
}
