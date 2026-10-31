import Foundation

public struct TrainingService: Sendable {
	package typealias ClientFactory =
		@Sendable (IntervalsCredential, AthleteSelection) -> any TrainingClient

	package let makeClient: ClientFactory

	package init(makeClient: @escaping ClientFactory) {
		self.makeClient = makeClient
	}

	public static let intervalsREST = rest(session: nil)

	package static func rest(session: URLSession?) -> TrainingService {
		TrainingService { credential, athlete in
			IntervalsRESTClient(credential: credential, athlete: athlete, session: session)
		}
	}
}

package enum TrainingConnection: Sendable {
	case unconnected
	case connected(ConnectedTraining)

	package var account: TrainingAccount {
		switch self {
		case .unconnected: .unconnected
		case .connected(let training): training.account
		}
	}
}

package struct ConnectedTraining: Sendable {
	package let connection: ConnectionID
	package let athlete: IntervalsAthleteID
	package let client: any TrainingClient

	package init(
		connection: ConnectionID, athlete: IntervalsAthleteID, client: any TrainingClient
	) {
		self.connection = connection
		self.athlete = athlete
		self.client = client
	}

	package var account: TrainingAccount {
		.intervals(connection: connection, athlete: athlete)
	}
}
