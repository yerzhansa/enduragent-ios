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
