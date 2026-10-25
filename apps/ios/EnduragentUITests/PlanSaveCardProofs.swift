import XCTest

@MainActor
final class PlanSaveCardEnProof: XCTestCase {
	func testWaitingSavedCanceledAndExpiredCardsAtDefaultSize() {
		PlanSaveCard.lifecycle(self, .en, .standard)
	}
	func testWaitingSavedCanceledAndExpiredCardsAtLargestText() {
		PlanSaveCard.lifecycle(self, .en, .largest)
	}
	func testSavingShowsNoControlsAtDefaultSize() { PlanSaveCard.saving(self, .en, .standard) }
	func testSavingShowsNoControlsAtLargestText() { PlanSaveCard.saving(self, .en, .largest) }
	func testStorageUnavailableShowsItsNoticeAndNoControlsAtDefaultSize() {
		PlanSaveCard.storage(self, .en, .standard)
	}
	func testStorageUnavailableShowsItsNoticeAndNoControlsAtLargestText() {
		PlanSaveCard.storage(self, .en, .largest)
	}
	func testAnExpiredTapIsAnsweredAtDefaultSize() {
		PlanSaveCard.refusedAsExpired(self, .en, .standard)
	}
	func testAnExpiredTapIsAnsweredAtLargestText() {
		PlanSaveCard.refusedAsExpired(self, .en, .largest)
	}
	func testAReplacedTapIsAnsweredAtDefaultSize() {
		PlanSaveCard.refusedAsReplaced(self, .en, .standard)
	}
	func testAReplacedTapIsAnsweredAtLargestText() {
		PlanSaveCard.refusedAsReplaced(self, .en, .largest)
	}
	func testATapForAnotherAthleteIsAnsweredAtDefaultSize() {
		PlanSaveCard.athleteChanged(self, .en, .standard)
	}
	func testATapForAnotherAthleteIsAnsweredAtLargestText() {
		PlanSaveCard.athleteChanged(self, .en, .largest)
	}
	func testALongNameWrapsAndValuesSitUnderLabelsAtDefaultSize() {
		PlanSaveCard.longName(self, .en, .standard)
	}
	func testALongNameWrapsAndValuesSitUnderLabelsAtLargestText() {
		PlanSaveCard.longName(self, .en, .largest)
	}
	func testATurnThatCouldNotPrepareAPlanShowsItsNoticeAtDefaultSize() {
		PlanSaveCard.notPrepared(self, .en, .standard)
	}
	func testATurnThatCouldNotPrepareAPlanShowsItsNoticeAtLargestText() {
		PlanSaveCard.notPrepared(self, .en, .largest)
	}
	func testACarriedCardIsDrawnOnceAtTheTopAtDefaultSize() {
		PlanSaveCard.carried(self, .en, .standard)
	}
	func testACarriedCardIsDrawnOnceAtTheTopAtLargestText() {
		PlanSaveCard.carried(self, .en, .largest)
	}
	func testControlsArmWhenTheTitleIsScrolledIntoViewAtDefaultSize() {
		PlanSaveCard.armsWhenScrolledIntoView(self, .en, .standard)
	}
	func testControlsArmWhenTheTitleIsScrolledIntoViewAtLargestText() {
		PlanSaveCard.armsWhenScrolledIntoView(self, .en, .largest)
	}
	func testApprovingTheReviewLeavesThePlanWaitingAtDefaultSize() {
		PlanSaveCard.reviewThenApprove(self, .en, .standard)
	}
	func testApprovingTheReviewLeavesThePlanWaitingAtLargestText() {
		PlanSaveCard.reviewThenApprove(self, .en, .largest)
	}
	func testSavingThePlanLeavesTheReviewWaitingAtDefaultSize() {
		PlanSaveCard.reviewThenSave(self, .en, .standard)
	}
	func testSavingThePlanLeavesTheReviewWaitingAtLargestText() {
		PlanSaveCard.reviewThenSave(self, .en, .largest)
	}
}

@MainActor
final class PlanSaveCardDeProof: XCTestCase {
	func testWaitingSavedCanceledAndExpiredCardsAtDefaultSize() {
		PlanSaveCard.lifecycle(self, .de, .standard)
	}
	func testWaitingSavedCanceledAndExpiredCardsAtLargestText() {
		PlanSaveCard.lifecycle(self, .de, .largest)
	}
	func testSavingShowsNoControlsAtDefaultSize() { PlanSaveCard.saving(self, .de, .standard) }
	func testSavingShowsNoControlsAtLargestText() { PlanSaveCard.saving(self, .de, .largest) }
	func testStorageUnavailableShowsItsNoticeAndNoControlsAtDefaultSize() {
		PlanSaveCard.storage(self, .de, .standard)
	}
	func testStorageUnavailableShowsItsNoticeAndNoControlsAtLargestText() {
		PlanSaveCard.storage(self, .de, .largest)
	}
	func testAnExpiredTapIsAnsweredAtDefaultSize() {
		PlanSaveCard.refusedAsExpired(self, .de, .standard)
	}
	func testAnExpiredTapIsAnsweredAtLargestText() {
		PlanSaveCard.refusedAsExpired(self, .de, .largest)
	}
	func testAReplacedTapIsAnsweredAtDefaultSize() {
		PlanSaveCard.refusedAsReplaced(self, .de, .standard)
	}
	func testAReplacedTapIsAnsweredAtLargestText() {
		PlanSaveCard.refusedAsReplaced(self, .de, .largest)
	}
	func testATapForAnotherAthleteIsAnsweredAtDefaultSize() {
		PlanSaveCard.athleteChanged(self, .de, .standard)
	}
	func testATapForAnotherAthleteIsAnsweredAtLargestText() {
		PlanSaveCard.athleteChanged(self, .de, .largest)
	}
	func testALongNameWrapsAndValuesSitUnderLabelsAtDefaultSize() {
		PlanSaveCard.longName(self, .de, .standard)
	}
	func testALongNameWrapsAndValuesSitUnderLabelsAtLargestText() {
		PlanSaveCard.longName(self, .de, .largest)
	}
	func testATurnThatCouldNotPrepareAPlanShowsItsNoticeAtDefaultSize() {
		PlanSaveCard.notPrepared(self, .de, .standard)
	}
	func testATurnThatCouldNotPrepareAPlanShowsItsNoticeAtLargestText() {
		PlanSaveCard.notPrepared(self, .de, .largest)
	}
	func testACarriedCardIsDrawnOnceAtTheTopAtDefaultSize() {
		PlanSaveCard.carried(self, .de, .standard)
	}
	func testACarriedCardIsDrawnOnceAtTheTopAtLargestText() {
		PlanSaveCard.carried(self, .de, .largest)
	}
	func testControlsArmWhenTheTitleIsScrolledIntoViewAtDefaultSize() {
		PlanSaveCard.armsWhenScrolledIntoView(self, .de, .standard)
	}
	func testControlsArmWhenTheTitleIsScrolledIntoViewAtLargestText() {
		PlanSaveCard.armsWhenScrolledIntoView(self, .de, .largest)
	}
	func testApprovingTheReviewLeavesThePlanWaitingAtDefaultSize() {
		PlanSaveCard.reviewThenApprove(self, .de, .standard)
	}
	func testApprovingTheReviewLeavesThePlanWaitingAtLargestText() {
		PlanSaveCard.reviewThenApprove(self, .de, .largest)
	}
	func testSavingThePlanLeavesTheReviewWaitingAtDefaultSize() {
		PlanSaveCard.reviewThenSave(self, .de, .standard)
	}
	func testSavingThePlanLeavesTheReviewWaitingAtLargestText() {
		PlanSaveCard.reviewThenSave(self, .de, .largest)
	}
}

@MainActor
final class PlanSaveCardPtPTProof: XCTestCase {
	func testWaitingSavedCanceledAndExpiredCardsAtDefaultSize() {
		PlanSaveCard.lifecycle(self, .ptPT, .standard)
	}
	func testWaitingSavedCanceledAndExpiredCardsAtLargestText() {
		PlanSaveCard.lifecycle(self, .ptPT, .largest)
	}
	func testSavingShowsNoControlsAtDefaultSize() { PlanSaveCard.saving(self, .ptPT, .standard) }
	func testSavingShowsNoControlsAtLargestText() { PlanSaveCard.saving(self, .ptPT, .largest) }
	func testStorageUnavailableShowsItsNoticeAndNoControlsAtDefaultSize() {
		PlanSaveCard.storage(self, .ptPT, .standard)
	}
	func testStorageUnavailableShowsItsNoticeAndNoControlsAtLargestText() {
		PlanSaveCard.storage(self, .ptPT, .largest)
	}
	func testAnExpiredTapIsAnsweredAtDefaultSize() {
		PlanSaveCard.refusedAsExpired(self, .ptPT, .standard)
	}
	func testAnExpiredTapIsAnsweredAtLargestText() {
		PlanSaveCard.refusedAsExpired(self, .ptPT, .largest)
	}
	func testAReplacedTapIsAnsweredAtDefaultSize() {
		PlanSaveCard.refusedAsReplaced(self, .ptPT, .standard)
	}
	func testAReplacedTapIsAnsweredAtLargestText() {
		PlanSaveCard.refusedAsReplaced(self, .ptPT, .largest)
	}
	func testATapForAnotherAthleteIsAnsweredAtDefaultSize() {
		PlanSaveCard.athleteChanged(self, .ptPT, .standard)
	}
	func testATapForAnotherAthleteIsAnsweredAtLargestText() {
		PlanSaveCard.athleteChanged(self, .ptPT, .largest)
	}
	func testALongNameWrapsAndValuesSitUnderLabelsAtDefaultSize() {
		PlanSaveCard.longName(self, .ptPT, .standard)
	}
	func testALongNameWrapsAndValuesSitUnderLabelsAtLargestText() {
		PlanSaveCard.longName(self, .ptPT, .largest)
	}
	func testATurnThatCouldNotPrepareAPlanShowsItsNoticeAtDefaultSize() {
		PlanSaveCard.notPrepared(self, .ptPT, .standard)
	}
	func testATurnThatCouldNotPrepareAPlanShowsItsNoticeAtLargestText() {
		PlanSaveCard.notPrepared(self, .ptPT, .largest)
	}
	func testACarriedCardIsDrawnOnceAtTheTopAtDefaultSize() {
		PlanSaveCard.carried(self, .ptPT, .standard)
	}
	func testACarriedCardIsDrawnOnceAtTheTopAtLargestText() {
		PlanSaveCard.carried(self, .ptPT, .largest)
	}
	func testControlsArmWhenTheTitleIsScrolledIntoViewAtDefaultSize() {
		PlanSaveCard.armsWhenScrolledIntoView(self, .ptPT, .standard)
	}
	func testControlsArmWhenTheTitleIsScrolledIntoViewAtLargestText() {
		PlanSaveCard.armsWhenScrolledIntoView(self, .ptPT, .largest)
	}
	func testApprovingTheReviewLeavesThePlanWaitingAtDefaultSize() {
		PlanSaveCard.reviewThenApprove(self, .ptPT, .standard)
	}
	func testApprovingTheReviewLeavesThePlanWaitingAtLargestText() {
		PlanSaveCard.reviewThenApprove(self, .ptPT, .largest)
	}
	func testSavingThePlanLeavesTheReviewWaitingAtDefaultSize() {
		PlanSaveCard.reviewThenSave(self, .ptPT, .standard)
	}
	func testSavingThePlanLeavesTheReviewWaitingAtLargestText() {
		PlanSaveCard.reviewThenSave(self, .ptPT, .largest)
	}
}

@MainActor
final class PlanSaveCardZhHantProof: XCTestCase {
	func testWaitingSavedCanceledAndExpiredCardsAtDefaultSize() {
		PlanSaveCard.lifecycle(self, .zhHant, .standard)
	}
	func testWaitingSavedCanceledAndExpiredCardsAtLargestText() {
		PlanSaveCard.lifecycle(self, .zhHant, .largest)
	}
	func testSavingShowsNoControlsAtDefaultSize() { PlanSaveCard.saving(self, .zhHant, .standard) }
	func testSavingShowsNoControlsAtLargestText() { PlanSaveCard.saving(self, .zhHant, .largest) }
	func testStorageUnavailableShowsItsNoticeAndNoControlsAtDefaultSize() {
		PlanSaveCard.storage(self, .zhHant, .standard)
	}
	func testStorageUnavailableShowsItsNoticeAndNoControlsAtLargestText() {
		PlanSaveCard.storage(self, .zhHant, .largest)
	}
	func testAnExpiredTapIsAnsweredAtDefaultSize() {
		PlanSaveCard.refusedAsExpired(self, .zhHant, .standard)
	}
	func testAnExpiredTapIsAnsweredAtLargestText() {
		PlanSaveCard.refusedAsExpired(self, .zhHant, .largest)
	}
	func testAReplacedTapIsAnsweredAtDefaultSize() {
		PlanSaveCard.refusedAsReplaced(self, .zhHant, .standard)
	}
	func testAReplacedTapIsAnsweredAtLargestText() {
		PlanSaveCard.refusedAsReplaced(self, .zhHant, .largest)
	}
	func testATapForAnotherAthleteIsAnsweredAtDefaultSize() {
		PlanSaveCard.athleteChanged(self, .zhHant, .standard)
	}
	func testATapForAnotherAthleteIsAnsweredAtLargestText() {
		PlanSaveCard.athleteChanged(self, .zhHant, .largest)
	}
	func testALongNameWrapsAndValuesSitUnderLabelsAtDefaultSize() {
		PlanSaveCard.longName(self, .zhHant, .standard)
	}
	func testALongNameWrapsAndValuesSitUnderLabelsAtLargestText() {
		PlanSaveCard.longName(self, .zhHant, .largest)
	}
	func testATurnThatCouldNotPrepareAPlanShowsItsNoticeAtDefaultSize() {
		PlanSaveCard.notPrepared(self, .zhHant, .standard)
	}
	func testATurnThatCouldNotPrepareAPlanShowsItsNoticeAtLargestText() {
		PlanSaveCard.notPrepared(self, .zhHant, .largest)
	}
	func testACarriedCardIsDrawnOnceAtTheTopAtDefaultSize() {
		PlanSaveCard.carried(self, .zhHant, .standard)
	}
	func testACarriedCardIsDrawnOnceAtTheTopAtLargestText() {
		PlanSaveCard.carried(self, .zhHant, .largest)
	}
	func testControlsArmWhenTheTitleIsScrolledIntoViewAtDefaultSize() {
		PlanSaveCard.armsWhenScrolledIntoView(self, .zhHant, .standard)
	}
	func testControlsArmWhenTheTitleIsScrolledIntoViewAtLargestText() {
		PlanSaveCard.armsWhenScrolledIntoView(self, .zhHant, .largest)
	}
	func testApprovingTheReviewLeavesThePlanWaitingAtDefaultSize() {
		PlanSaveCard.reviewThenApprove(self, .zhHant, .standard)
	}
	func testApprovingTheReviewLeavesThePlanWaitingAtLargestText() {
		PlanSaveCard.reviewThenApprove(self, .zhHant, .largest)
	}
	func testSavingThePlanLeavesTheReviewWaitingAtDefaultSize() {
		PlanSaveCard.reviewThenSave(self, .zhHant, .standard)
	}
	func testSavingThePlanLeavesTheReviewWaitingAtLargestText() {
		PlanSaveCard.reviewThenSave(self, .zhHant, .largest)
	}
}
