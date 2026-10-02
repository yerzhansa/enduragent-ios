import Foundation

public struct IntervalsSummary: Sendable, Equatable {
	public let connectionID: ConnectionID
	public let keySuffix: String
	public let profile: IntervalsProfileState

	var needsDisplayRead: Bool {
		switch profile {
		case .waiting: true
		case .available(let athlete): athlete.wellness == .waiting
		case .failed: false
		}
	}

	public var wellness: IntervalsWellnessState {
		guard case .available(let profile) = profile else { return .waiting }
		return profile.wellness
	}

	public var athleteName: String? {
		guard case .available(let profile) = profile else { return nil }
		return profile.name
	}

	public var today: WellnessDay? {
		guard case .available(.day(let day)) = wellness else { return nil }
		return day
	}
}

public enum IntervalsProfileState: Sendable, Equatable {
	case waiting
	case available(IntervalsProfile)
	case failed(TrainingFailure)
}

public struct IntervalsProfile: Sendable, Equatable {
	public let athleteID: IntervalsAthleteID
	public let name: String
	public let wellness: IntervalsWellnessState
}

public enum IntervalsWellnessState: Sendable, Equatable {
	case waiting
	case available(IntervalsWellnessResult)
	case failed(IntervalsWellnessFailure)
}

public enum IntervalsWellnessResult: Sendable, Equatable {
	case day(WellnessDay)
	case noData(on: CivilDate)
}

public enum IntervalsWellnessFailure: Sendable, Equatable {
	case requestRejected
	case temporarilyUnavailable
}

public enum TrainingDisplayAction: Sendable, Equatable {
	case reviewConnection
	case retry(ConnectionID)

	public var title: CatalogKey {
		switch self {
		case .reviewConnection: Catalog.connectReview
		case .retry: Catalog.chatTranscriptRetry
		}
	}
}

struct TrainingDisplayReadID: Sendable, Equatable {
	let connectionID: ConnectionID
	let generation: UInt64
}
