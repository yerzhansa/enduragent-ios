import XCTest

@MainActor
final class PlanSaveCardEnProof: XCTestCase {
	func testWaitingSavedCanceledAndExpiredCardsAtDefaultSize() {
		PlanSaveCard.lifecycle(self, .en)
	}
	func testSavingShowsNoControlsAtDefaultSize() { PlanSaveCard.saving(self, .en) }
	func testStorageUnavailableShowsItsNoticeAndNoControlsAtDefaultSize() {
		PlanSaveCard.storage(self, .en)
	}
	func testAnExpiredTapIsAnsweredAtDefaultSize() {
		PlanSaveCard.refusedAsExpired(self, .en)
	}
	func testAReplacedTapIsAnsweredAtDefaultSize() {
		PlanSaveCard.refusedAsReplaced(self, .en)
	}
	func testATapForAnotherAthleteIsAnsweredAtDefaultSize() {
		PlanSaveCard.athleteChanged(self, .en)
	}
	func testALongNameWrapsAndValuesSitUnderLabelsAtDefaultSize() {
		PlanSaveCard.longName(self, .en)
	}
	func testATurnThatCouldNotPrepareAPlanShowsItsNoticeAtDefaultSize() {
		PlanSaveCard.notPrepared(self, .en)
	}
	func testACarriedCardIsDrawnOnceAtTheTopAtDefaultSize() {
		PlanSaveCard.carried(self, .en)
	}
	func testControlsArmWhenTheTitleIsScrolledIntoViewAtDefaultSize() {
		PlanSaveCard.armsWhenScrolledIntoView(self, .en)
	}
	func testApprovingTheReviewLeavesThePlanWaitingAtDefaultSize() {
		PlanSaveCard.reviewThenApprove(self, .en)
	}
	func testSavingThePlanLeavesTheReviewWaitingAtDefaultSize() {
		PlanSaveCard.reviewThenSave(self, .en)
	}
}

@MainActor
final class PlanSaveCardDeProof: XCTestCase {
	func testWaitingSavedCanceledAndExpiredCardsAtDefaultSize() {
		PlanSaveCard.lifecycle(self, .de)
	}
	func testSavingShowsNoControlsAtDefaultSize() { PlanSaveCard.saving(self, .de) }
	func testStorageUnavailableShowsItsNoticeAndNoControlsAtDefaultSize() {
		PlanSaveCard.storage(self, .de)
	}
	func testAnExpiredTapIsAnsweredAtDefaultSize() {
		PlanSaveCard.refusedAsExpired(self, .de)
	}
	func testAReplacedTapIsAnsweredAtDefaultSize() {
		PlanSaveCard.refusedAsReplaced(self, .de)
	}
	func testATapForAnotherAthleteIsAnsweredAtDefaultSize() {
		PlanSaveCard.athleteChanged(self, .de)
	}
	func testALongNameWrapsAndValuesSitUnderLabelsAtDefaultSize() {
		PlanSaveCard.longName(self, .de)
	}
	func testATurnThatCouldNotPrepareAPlanShowsItsNoticeAtDefaultSize() {
		PlanSaveCard.notPrepared(self, .de)
	}
	func testACarriedCardIsDrawnOnceAtTheTopAtDefaultSize() {
		PlanSaveCard.carried(self, .de)
	}
	func testControlsArmWhenTheTitleIsScrolledIntoViewAtDefaultSize() {
		PlanSaveCard.armsWhenScrolledIntoView(self, .de)
	}
	func testApprovingTheReviewLeavesThePlanWaitingAtDefaultSize() {
		PlanSaveCard.reviewThenApprove(self, .de)
	}
	func testSavingThePlanLeavesTheReviewWaitingAtDefaultSize() {
		PlanSaveCard.reviewThenSave(self, .de)
	}
}

@MainActor
final class PlanSaveCardPtPTProof: XCTestCase {
	func testWaitingSavedCanceledAndExpiredCardsAtDefaultSize() {
		PlanSaveCard.lifecycle(self, .ptPT)
	}
	func testSavingShowsNoControlsAtDefaultSize() { PlanSaveCard.saving(self, .ptPT) }
	func testStorageUnavailableShowsItsNoticeAndNoControlsAtDefaultSize() {
		PlanSaveCard.storage(self, .ptPT)
	}
	func testAnExpiredTapIsAnsweredAtDefaultSize() {
		PlanSaveCard.refusedAsExpired(self, .ptPT)
	}
	func testAReplacedTapIsAnsweredAtDefaultSize() {
		PlanSaveCard.refusedAsReplaced(self, .ptPT)
	}
	func testATapForAnotherAthleteIsAnsweredAtDefaultSize() {
		PlanSaveCard.athleteChanged(self, .ptPT)
	}
	func testALongNameWrapsAndValuesSitUnderLabelsAtDefaultSize() {
		PlanSaveCard.longName(self, .ptPT)
	}
	func testATurnThatCouldNotPrepareAPlanShowsItsNoticeAtDefaultSize() {
		PlanSaveCard.notPrepared(self, .ptPT)
	}
	func testACarriedCardIsDrawnOnceAtTheTopAtDefaultSize() {
		PlanSaveCard.carried(self, .ptPT)
	}
	func testControlsArmWhenTheTitleIsScrolledIntoViewAtDefaultSize() {
		PlanSaveCard.armsWhenScrolledIntoView(self, .ptPT)
	}
	func testApprovingTheReviewLeavesThePlanWaitingAtDefaultSize() {
		PlanSaveCard.reviewThenApprove(self, .ptPT)
	}
	func testSavingThePlanLeavesTheReviewWaitingAtDefaultSize() {
		PlanSaveCard.reviewThenSave(self, .ptPT)
	}
}

@MainActor
final class PlanSaveCardZhHantProof: XCTestCase {
	func testWaitingSavedCanceledAndExpiredCardsAtDefaultSize() {
		PlanSaveCard.lifecycle(self, .zhHant)
	}
	func testSavingShowsNoControlsAtDefaultSize() { PlanSaveCard.saving(self, .zhHant) }
	func testStorageUnavailableShowsItsNoticeAndNoControlsAtDefaultSize() {
		PlanSaveCard.storage(self, .zhHant)
	}
	func testAnExpiredTapIsAnsweredAtDefaultSize() {
		PlanSaveCard.refusedAsExpired(self, .zhHant)
	}
	func testAReplacedTapIsAnsweredAtDefaultSize() {
		PlanSaveCard.refusedAsReplaced(self, .zhHant)
	}
	func testATapForAnotherAthleteIsAnsweredAtDefaultSize() {
		PlanSaveCard.athleteChanged(self, .zhHant)
	}
	func testALongNameWrapsAndValuesSitUnderLabelsAtDefaultSize() {
		PlanSaveCard.longName(self, .zhHant)
	}
	func testATurnThatCouldNotPrepareAPlanShowsItsNoticeAtDefaultSize() {
		PlanSaveCard.notPrepared(self, .zhHant)
	}
	func testACarriedCardIsDrawnOnceAtTheTopAtDefaultSize() {
		PlanSaveCard.carried(self, .zhHant)
	}
	func testControlsArmWhenTheTitleIsScrolledIntoViewAtDefaultSize() {
		PlanSaveCard.armsWhenScrolledIntoView(self, .zhHant)
	}
	func testApprovingTheReviewLeavesThePlanWaitingAtDefaultSize() {
		PlanSaveCard.reviewThenApprove(self, .zhHant)
	}
	func testSavingThePlanLeavesTheReviewWaitingAtDefaultSize() {
		PlanSaveCard.reviewThenSave(self, .zhHant)
	}
}
