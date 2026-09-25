import Foundation

public enum OperationID: Hashable, Sendable {
	case turn(TurnID)
	case memoryFlush(FlushJobID)
	case conversationReset(ResetID)
	case preferenceChange(PreferenceChangeID)
	case credentialChange(CredentialChangeID)
	case launchRecovery(LaunchID)
	case workoutChangeSet(ChangeSetID, ChangeSetRevision)
	case planningCommand(PlanningCommandID)
	case referenceRefresh(RefreshID)
	case debugSample(DebugSampleID)
}

public struct OperationStamp: Hashable, Sendable {
	public let operation: OperationID
	public let attempt: AttemptID
	public let binding: ActionBinding

	package init(operation: OperationID, attempt: AttemptID, binding: ActionBinding) {
		self.operation = operation
		self.attempt = attempt
		self.binding = binding
	}
}

public struct ActionBinding: Hashable, Sendable {
	public let account: TrainingAccount
	public let zone: IANATimeZone

	package init(account: TrainingAccount, zone: IANATimeZone) {
		self.account = account
		self.zone = zone
	}
}

public struct ConnectionID: Hashable, Sendable {
	public let rawValue: UUID

	public init(rawValue: UUID) {
		self.rawValue = rawValue
	}

	public init() {
		self.rawValue = UUID()
	}
}

public struct IntervalsAthleteID: Hashable, Sendable {
	public let rawValue: String

	public init?(rawValue: String) {
		guard !rawValue.isEmpty, rawValue != "0" else { return nil }
		self.rawValue = rawValue
	}
}

public enum TrainingAccount: Hashable, Sendable {
	case unconnected
	case intervals(connection: ConnectionID, athlete: IntervalsAthleteID?)

	public func authority(under current: TrainingAccount) -> AccountAuthority {
		switch (self, current) {
		case (.unconnected, .unconnected):
			return .same
		case (.unconnected, .intervals), (.intervals, .unconnected):
			return .changed
		case (.intervals(let bound, let boundAthlete), .intervals(let now, let nowAthlete)):
			if bound == now {
				return .same
			}
			guard let boundAthlete, let nowAthlete else {
				return .unverifiable
			}
			return boundAthlete == nowAthlete ? .sameAthlete : .changed
		}
	}
}

public enum AccountAuthority: Sendable, Equatable {
	case same
	case sameAthlete
	case changed
	case unverifiable
}

public struct AthleteTime: Hashable, Sendable {
	public let instant: Date
	public let zone: IANATimeZone

	package init(instant: Date, zone: IANATimeZone) {
		self.instant = instant
		self.zone = zone
	}

	public var civilDate: CivilDate {
		CivilDate(date: instant, timeZone: zone.timeZone)
	}
}

package struct AthleteCalendar: Sendable {
	package let clock: any Clock

	package init(clock: any Clock) {
		self.clock = clock
	}

	package var deviceZone: IANATimeZone {
		IANATimeZone(current: clock.timeZone)
	}

	package func now(in zone: IANATimeZone) -> AthleteTime {
		AthleteTime(instant: clock.now, zone: zone)
	}
}
