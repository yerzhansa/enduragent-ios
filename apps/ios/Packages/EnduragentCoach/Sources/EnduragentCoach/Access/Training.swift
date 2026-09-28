import Foundation

public struct TrainingService: Sendable {
	package typealias ClientFactory =
		@Sendable (IntervalsCredential, AthleteSelection, any Clock) -> any IntervalsClient

	package let makeClient: ClientFactory

	package init(makeClient: @escaping ClientFactory) {
		self.makeClient = makeClient
	}

	public static let intervalsREST = rest(session: nil)

	package static func rest(session: URLSession?) -> TrainingService {
		TrainingService { credential, athlete, clock in
			IntervalsRESTClient(
				credential: credential, athlete: athlete, session: session, clock: clock)
		}
	}

	public static func fake(
		_ client: @escaping @Sendable (IntervalsCredential, AthleteSelection) -> any IntervalsClient
	) -> TrainingService {
		TrainingService { credential, athlete, _ in client(credential, athlete) }
	}
}

package struct TrainingConnection: Sendable {
	package let account: TrainingAccount
	package let client: any IntervalsClient

	package static let unconnected = TrainingConnection(
		account: .unconnected, client: UnconnectedIntervalsClient())

	package func loadSnapshot(clock: any Clock, attempt: AttemptID, diagnostics: DiagnosticsLog)
		async throws(CancellationError) -> AthleteSnapshot?
	{
		guard account != .unconnected else { return nil }
		let today = IntervalsPolicy.today(now: clock.now, timeZone: clock.timeZone)
		let oldest = today.adding(days: -(7 - 1))
		let days: [WellnessDay]
		do {
			days = try await client.fetchWellness(oldest: oldest, newest: today)
		} catch is CancellationError {
			throw CancellationError()
		} catch {
			diagnostics.record(.trainingUnavailable(attempt, TrainingFailure(error)))
			return nil
		}
		guard let latest = days.last else {
			return nil
		}
		return AthleteSnapshot(fitness: latest.fitness, fatigue: latest.fatigue, form: latest.form)
	}

}
