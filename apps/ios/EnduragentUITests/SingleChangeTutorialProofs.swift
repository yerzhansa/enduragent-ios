import XCTest

final class RecordsClockOrderProof: XCTestCase {
	func testRecordsClockOrder() {
		let app = XCUIApplication()
		TutorialHarness.launch(app)
		TutorialHarness.completeOnboarding(app)
		TutorialHarness.exchange(app, TutorialHarness.weekQuestion)
		TutorialHarness.waitForLabel(app, TutorialHarness.weekReply)
		TutorialHarness.exchange(app, TutorialHarness.workout)
		let add = TutorialHarness.named(app, "chat.preview.add")
		TutorialHarness.wait(add, until: .enabled)
		add.tap()
		TutorialHarness.waitForLabel(app, TutorialHarness.done)
		TutorialHarness.openRecords(app)
		TutorialHarness.attach(self, name: "records-clock-order", app: app)
		let labels = TutorialHarness.recordRowLabels(app)
		let rows = labels.map { $0.split(separator: " ").map(String.init) }
		XCTAssertTrue(
			rows.allSatisfy {
				$0.count == 4
					|| (["turnSettled", "turnClaim", "proposalCleared"].contains($0.first)
						&& $0.count > 4)
			},
			"every row shows kind, device, HLC, account, and any settlement, lease, or clear outcome: \(labels)"
		)
		let clocks = rows.compactMap { $0.dropLast().last }
		XCTAssertEqual(Set(clocks).count, clocks.count, "no two rows share an HLC: \(labels)")
		let causal = rows.compactMap(\.first).filter {
			["userMessage", "turnClaim", "turnSettled", "pendingProposal", "proposalCleared"]
				.contains($0)
		}
		XCTAssertEqual(
			causal,
			[
				"userMessage", "turnClaim", "turnSettled", "userMessage", "turnClaim",
				"pendingProposal", "turnSettled", "proposalCleared",
			],
			"rows in HLC order follow the order the app wrote them: \(labels)")
	}
}
