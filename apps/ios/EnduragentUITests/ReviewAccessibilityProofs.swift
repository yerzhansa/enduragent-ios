import EnduragentCoach
import XCTest

@MainActor
final class ReviewAccessibilityEnSweep: XCTestCase {
	func testApprovalControls() { ReviewAccessibility.approval(self, .en) }
	func testUnconfirmedChangeControls() { ReviewAccessibility.unconfirmedChange(self, .en) }
	func testBlockedReviewControls() { ReviewAccessibility.blockedReview(self, .en) }
}

@MainActor
final class ReviewAccessibilityEsSweep: XCTestCase {
	func testApprovalControls() { ReviewAccessibility.approval(self, .es) }
	func testUnconfirmedChangeControls() { ReviewAccessibility.unconfirmedChange(self, .es) }
	func testBlockedReviewControls() { ReviewAccessibility.blockedReview(self, .es) }
}

@MainActor
final class ReviewAccessibilityFrSweep: XCTestCase {
	func testApprovalControls() { ReviewAccessibility.approval(self, .fr) }
	func testUnconfirmedChangeControls() { ReviewAccessibility.unconfirmedChange(self, .fr) }
	func testBlockedReviewControls() { ReviewAccessibility.blockedReview(self, .fr) }
}

@MainActor
final class ReviewAccessibilityItSweep: XCTestCase {
	func testApprovalControls() { ReviewAccessibility.approval(self, .it) }
	func testUnconfirmedChangeControls() { ReviewAccessibility.unconfirmedChange(self, .it) }
	func testBlockedReviewControls() { ReviewAccessibility.blockedReview(self, .it) }
}

@MainActor
final class ReviewAccessibilityDeProof: XCTestCase {
	func testApprovalControls() { ReviewAccessibility.approval(self, .de) }
	func testUnconfirmedChangeControls() { ReviewAccessibility.unconfirmedChange(self, .de) }
	func testBlockedReviewControls() { ReviewAccessibility.blockedReview(self, .de) }
	func testChatOpensWithTheDisclaimerOnScreen() {
		ReviewAccessibility.disclaimerOnOpening(self, .de)
	}
}

@MainActor
final class ReviewAccessibilityNlSweep: XCTestCase {
	func testApprovalControls() { ReviewAccessibility.approval(self, .nl) }
	func testUnconfirmedChangeControls() { ReviewAccessibility.unconfirmedChange(self, .nl) }
	func testBlockedReviewControls() { ReviewAccessibility.blockedReview(self, .nl) }
}

@MainActor
final class ReviewAccessibilityDaSweep: XCTestCase {
	func testApprovalControls() { ReviewAccessibility.approval(self, .da) }
	func testUnconfirmedChangeControls() { ReviewAccessibility.unconfirmedChange(self, .da) }
	func testBlockedReviewControls() { ReviewAccessibility.blockedReview(self, .da) }
}

@MainActor
final class ReviewAccessibilitySvSweep: XCTestCase {
	func testApprovalControls() { ReviewAccessibility.approval(self, .sv) }
	func testUnconfirmedChangeControls() { ReviewAccessibility.unconfirmedChange(self, .sv) }
	func testBlockedReviewControls() { ReviewAccessibility.blockedReview(self, .sv) }
}

@MainActor
final class ReviewAccessibilityNbSweep: XCTestCase {
	func testApprovalControls() { ReviewAccessibility.approval(self, .nb) }
	func testUnconfirmedChangeControls() { ReviewAccessibility.unconfirmedChange(self, .nb) }
	func testBlockedReviewControls() { ReviewAccessibility.blockedReview(self, .nb) }
}

@MainActor
final class ReviewAccessibilityFiSweep: XCTestCase {
	func testApprovalControls() { ReviewAccessibility.approval(self, .fi) }
	func testUnconfirmedChangeControls() { ReviewAccessibility.unconfirmedChange(self, .fi) }
	func testBlockedReviewControls() { ReviewAccessibility.blockedReview(self, .fi) }
}

@MainActor
final class ReviewAccessibilityPtPTProof: XCTestCase {
	func testApprovalControls() { ReviewAccessibility.approval(self, .ptPT) }
	func testUnconfirmedChangeControls() { ReviewAccessibility.unconfirmedChange(self, .ptPT) }
	func testBlockedReviewControls() { ReviewAccessibility.blockedReview(self, .ptPT) }
	func testChatOpensWithTheDisclaimerOnScreen() {
		ReviewAccessibility.disclaimerOnOpening(self, .ptPT)
	}
}

@MainActor
final class ReviewAccessibilityPtBRSweep: XCTestCase {
	func testApprovalControls() { ReviewAccessibility.approval(self, .ptBR) }
	func testUnconfirmedChangeControls() { ReviewAccessibility.unconfirmedChange(self, .ptBR) }
	func testBlockedReviewControls() { ReviewAccessibility.blockedReview(self, .ptBR) }
}

@MainActor
final class ReviewAccessibilityPlSweep: XCTestCase {
	func testApprovalControls() { ReviewAccessibility.approval(self, .pl) }
	func testUnconfirmedChangeControls() { ReviewAccessibility.unconfirmedChange(self, .pl) }
	func testBlockedReviewControls() { ReviewAccessibility.blockedReview(self, .pl) }
}

@MainActor
final class ReviewAccessibilityKoSweep: XCTestCase {
	func testApprovalControls() { ReviewAccessibility.approval(self, .ko) }
	func testUnconfirmedChangeControls() { ReviewAccessibility.unconfirmedChange(self, .ko) }
	func testBlockedReviewControls() { ReviewAccessibility.blockedReview(self, .ko) }
}

@MainActor
final class ReviewAccessibilityJaSweep: XCTestCase {
	func testApprovalControls() { ReviewAccessibility.approval(self, .ja) }
	func testUnconfirmedChangeControls() { ReviewAccessibility.unconfirmedChange(self, .ja) }
	func testBlockedReviewControls() { ReviewAccessibility.blockedReview(self, .ja) }
}

@MainActor
final class ReviewAccessibilityZhHansSweep: XCTestCase {
	func testApprovalControls() { ReviewAccessibility.approval(self, .zhHans) }
	func testUnconfirmedChangeControls() { ReviewAccessibility.unconfirmedChange(self, .zhHans) }
	func testBlockedReviewControls() { ReviewAccessibility.blockedReview(self, .zhHans) }
}

@MainActor
final class ReviewAccessibilityZhHantProof: XCTestCase {
	func testApprovalControls() { ReviewAccessibility.approval(self, .zhHant) }
	func testUnconfirmedChangeControls() { ReviewAccessibility.unconfirmedChange(self, .zhHant) }
	func testBlockedReviewControls() { ReviewAccessibility.blockedReview(self, .zhHant) }
	func testChatOpensWithTheDisclaimerOnScreen() {
		ReviewAccessibility.disclaimerOnOpening(self, .zhHant)
	}
}
