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
		_ client: @escaping @Sendable (IntervalsCredential, AthleteSelection) -> FakeIntervalsClient
	) -> TrainingService {
		TrainingService { credential, athlete, _ in client(credential, athlete) }
	}
}

package struct TrainingConnection: Sendable {
	package let account: TrainingAccount
	package let client: any IntervalsClient

	package static let unconnected = TrainingConnection(
		account: .unconnected, client: UnconnectedIntervalsClient())
}
