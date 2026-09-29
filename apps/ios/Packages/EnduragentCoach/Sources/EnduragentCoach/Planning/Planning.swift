import Foundation

package enum PlanningCommandName: String, Sendable {
	case creationStart = "plan_creation.start"
	case creationAnswer = "plan_creation.answer"
	case creationPreview = "plan_creation.preview"
	case creationActivate = "plan_creation.activate"
	case creationDiscard = "plan_creation.discard"
	case changePreview = "plan_change.preview"
	case changeApply = "plan_change.apply"
	case planClose = "plan.close"
}

package enum PlanningCommandStatus: String, Sendable {
	case pending
	case succeeded
	case conflict
	case failed
}

package enum PlanStatus: String, Sendable {
	case active
	case closed
}

package enum CreationStatus: String, Sendable {
	case inProgress = "in-progress"
	case review
	case activated
	case discarded
}

package enum MirrorJobKind: String, Sendable {
	case mirror
	case cleanup
}

package enum MatchDecision: String, Sendable {
	case suggested
	case confirmed
	case rejected
	case unpaired
}

package struct PlanningCommandRequest: Sendable, Equatable {
	package var name: PlanningCommandName
	package var commandId: String
	package var payload: JSONValue
	package var expectedVersion: Int?
}

package enum PlanningCommandResult: Sendable, Equatable {
	case applied(PlanningView)
	case replayed(PlanningView)
	case commandConflict
	case refused(String)
}

package struct PlanningView: Sendable, Equatable {
	package var access: Access
	package var unfinishedCreation: CreationSummary?
	package var activePlan: PlanHeadline?
	package var previewChange: PlanChangePreview?
	package var cards: [PlanCard]

	package enum Access: Sendable, Equatable {
		case owner
		case readOnly(planningDeviceId: DeviceID)
		case none
	}
}

package struct CreationSummary: Sendable, Equatable {
	package var id: ULID
	package var status: CreationStatus
	package var version: Int
}

package struct PlanChangePreview: Sendable, Equatable {
	package var changeId: ULID
	package var confidence: String
}

package enum PlanCard: Sendable, Equatable {
	case creation(CreationSummary)
	case activationConfirm(name: String, closesIncumbent: String?)
	case changePreview(PlanChangePreview)
	case readOnlyPlan(headline: PlanHeadline, planningDeviceId: DeviceID)
}

package struct PlanningAggregate: Sendable, Equatable {
	package var creation: CreationSummary?
	package var plan: PlanRevisionBody?
	package var previewChange: PlanChangePreview?
	package var commandLedger: [PlanningCommandBody]
	package var mirrorJobs: [MirrorJobBody]
}

package enum PlanningPolicy {
	package static let mirrorDays = 7
	package static let staleAfterHours = 24
	package static let raceWindowDays = 7
	package static let maxMirrorFailures = 5
	package static let drainLease: Duration = .seconds(300)
	package static let uidPrefix = "cycling-coach:plan:"
	package static let builderId = "cycling-creation-draft"
	package static let builderVersion = "1"
	package static let confidenceCopy =
		"Moderate confidence. Based on your confirmed limits and the available training record."

	package static func mirrorUID(plan: ULID, workout: ULID) -> PlanMirrorUID {
		PlanMirrorUID(planId: plan, workoutId: workout)
	}

	package static func mirrorWindow(today: DateKey) -> (DateKey, DateKey) {
		fatalError("not implemented")
	}

	package static func fold(_ records: [AthleteRecord]) -> PlanningAggregate {
		fatalError("not implemented")
	}
}

package actor Planning {
	private let clock: any Clock

	package init(clock: any Clock) {
		self.clock = clock
	}

	package func dispatch(_ request: PlanningCommandRequest) async throws -> PlanningCommandResult {
		fatalError("not implemented")
	}

	package func read() async throws -> PlanningView {
		fatalError("not implemented")
	}

	package func drainMirror(plan: ULID) async throws {
		fatalError("not implemented")
	}

	package func isPlanningDevice() async throws -> Bool {
		fatalError("not implemented")
	}
}

package enum CreationDraftBuilder {
	package static func build(answers: JSONValue, today: DateKey) throws -> JSONValue {
		fatalError("not implemented")
	}
}
