import EnduragentCoach
import XCTest

@MainActor
final class ReviewAccessibilityEnSweep: XCTestCase {
	func testApprovalControls() { ReviewAccessibility.approval(self, .en) }
	func testUncertainSaveControls() { ReviewAccessibility.uncertainSave(self, .en) }
}

@MainActor
final class ReviewAccessibilityEsSweep: XCTestCase {
	func testApprovalControls() { ReviewAccessibility.approval(self, .es) }
	func testUncertainSaveControls() { ReviewAccessibility.uncertainSave(self, .es) }
}

@MainActor
final class ReviewAccessibilityFrSweep: XCTestCase {
	func testApprovalControls() { ReviewAccessibility.approval(self, .fr) }
	func testUncertainSaveControls() { ReviewAccessibility.uncertainSave(self, .fr) }
}

@MainActor
final class ReviewAccessibilityItSweep: XCTestCase {
	func testApprovalControls() { ReviewAccessibility.approval(self, .it) }
	func testUncertainSaveControls() { ReviewAccessibility.uncertainSave(self, .it) }
}

@MainActor
final class ReviewAccessibilityDeProof: XCTestCase {
	func testApprovalControls() { ReviewAccessibility.approval(self, .de) }
	func testUncertainSaveControls() { ReviewAccessibility.uncertainSave(self, .de) }
}

@MainActor
final class ReviewAccessibilityNlSweep: XCTestCase {
	func testApprovalControls() { ReviewAccessibility.approval(self, .nl) }
	func testUncertainSaveControls() { ReviewAccessibility.uncertainSave(self, .nl) }
}

@MainActor
final class ReviewAccessibilityDaSweep: XCTestCase {
	func testApprovalControls() { ReviewAccessibility.approval(self, .da) }
	func testUncertainSaveControls() { ReviewAccessibility.uncertainSave(self, .da) }
}

@MainActor
final class ReviewAccessibilitySvSweep: XCTestCase {
	func testApprovalControls() { ReviewAccessibility.approval(self, .sv) }
	func testUncertainSaveControls() { ReviewAccessibility.uncertainSave(self, .sv) }
}

@MainActor
final class ReviewAccessibilityNbSweep: XCTestCase {
	func testApprovalControls() { ReviewAccessibility.approval(self, .nb) }
	func testUncertainSaveControls() { ReviewAccessibility.uncertainSave(self, .nb) }
}

@MainActor
final class ReviewAccessibilityFiSweep: XCTestCase {
	func testApprovalControls() { ReviewAccessibility.approval(self, .fi) }
	func testUncertainSaveControls() { ReviewAccessibility.uncertainSave(self, .fi) }
}

@MainActor
final class ReviewAccessibilityPtPTProof: XCTestCase {
	func testApprovalControls() { ReviewAccessibility.approval(self, .ptPT) }
	func testUncertainSaveControls() { ReviewAccessibility.uncertainSave(self, .ptPT) }
}

@MainActor
final class ReviewAccessibilityPtBRSweep: XCTestCase {
	func testApprovalControls() { ReviewAccessibility.approval(self, .ptBR) }
	func testUncertainSaveControls() { ReviewAccessibility.uncertainSave(self, .ptBR) }
}

@MainActor
final class ReviewAccessibilityPlSweep: XCTestCase {
	func testApprovalControls() { ReviewAccessibility.approval(self, .pl) }
	func testUncertainSaveControls() { ReviewAccessibility.uncertainSave(self, .pl) }
}

@MainActor
final class ReviewAccessibilityKoSweep: XCTestCase {
	func testApprovalControls() { ReviewAccessibility.approval(self, .ko) }
	func testUncertainSaveControls() { ReviewAccessibility.uncertainSave(self, .ko) }
}

@MainActor
final class ReviewAccessibilityJaSweep: XCTestCase {
	func testApprovalControls() { ReviewAccessibility.approval(self, .ja) }
	func testUncertainSaveControls() { ReviewAccessibility.uncertainSave(self, .ja) }
}

@MainActor
final class ReviewAccessibilityZhHansSweep: XCTestCase {
	func testApprovalControls() { ReviewAccessibility.approval(self, .zhHans) }
	func testUncertainSaveControls() { ReviewAccessibility.uncertainSave(self, .zhHans) }
}

@MainActor
final class ReviewAccessibilityZhHantProof: XCTestCase {
	func testApprovalControls() { ReviewAccessibility.approval(self, .zhHant) }
	func testUncertainSaveControls() { ReviewAccessibility.uncertainSave(self, .zhHant) }
}
