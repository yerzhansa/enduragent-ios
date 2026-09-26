import Foundation

public struct TrainingService: Sendable {
	package let makeClient: @Sendable (IntervalsCredential, any Clock) -> any IntervalsClient

	package init(
		makeClient: @escaping @Sendable (IntervalsCredential, any Clock) -> any IntervalsClient
	) {
		self.makeClient = makeClient
	}

	public static let intervalsREST = TrainingService { credential, clock in
		IntervalsRESTClient(credential: credential, clock: clock)
	}

	public static func fake(
		_ client: @escaping @Sendable (IntervalsCredential) -> FakeIntervalsClient
	) -> TrainingService {
		TrainingService { credential, _ in client(credential) }
	}
}

package struct TrainingConnection: Sendable {
	package let account: TrainingAccount
	package let client: any IntervalsClient

	package static let unconnected = TrainingConnection(
		account: .unconnected, client: UnconnectedIntervalsClient())
}
