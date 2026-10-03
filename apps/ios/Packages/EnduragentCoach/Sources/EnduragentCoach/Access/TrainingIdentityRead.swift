import Foundation

struct TrainingIdentityRead: Sendable {
	let id: UUID
	let connection: IntervalsConnection
	let state: State

	enum State: Sendable {
		case reading(Task<IntervalsProfileState, Never>)
		case checked(IntervalsProfileState)
	}

	init(connection: IntervalsConnection, state: State, id: UUID = UUID()) {
		self.id = id
		self.connection = connection
		self.state = state
	}

	var profile: IntervalsProfileState {
		guard case .checked(let profile) = state else { return .waiting }
		return profile
	}
}
