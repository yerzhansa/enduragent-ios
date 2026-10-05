#if KEYCHAIN_DEVICE_PROOF && !targetEnvironment(simulator)
	import EnduragentCoachFixtures
	import XCTest

	@MainActor
	final class TrainingKeychainDeviceProof: XCTestCase {
		private let app = XCUIApplication(bundleIdentifier: "icu.enduragent.keychainproof")

		func testSettingsCredentialSurvivesRelaunch() throws {
			continueAfterFailure = false
			let environment = ProcessInfo.processInfo.environment
			guard let rawBudget = environment["ENDURAGENT_PHONE_MESSAGE_BUDGET"],
				let budget = Int(rawBudget), budget >= 0,
				let updates = environment["ENDURAGENT_DEVICE_UPDATE_CHECK"],
				updates.hasPrefix("updated-together:"), updates.count > 18
			else {
				throw PhoneRunBlocked(
					reason:
						"Ask for this run's message budget and confirm build-3 and M1+ devices were updated together."
				)
			}
			attach(
				"Budget \(budget). Live messages used 0. Two scripted Sends. \(updates)",
				name: "operator-check")
			TutorialHarness.launch(app, arguments: FixtureArguments(keychain: .nativeProof))
			TutorialHarness.startUnconnected(app)
			TutorialHarness.openCredentials(app)
			TutorialHarness.named(app, "training.edit").tap()
			let key = TutorialHarness.named(app, "training.apiKey")
			TutorialHarness.wait(key, until: .hittable)
			XCTAssertEqual(key.elementType, .secureTextField)
			XCTAssertEqual(key.value as? String, key.placeholderValue)
			key.tap()
			key.typeText(NativeKeychainProof.syntheticKey)
			TutorialHarness.named(app, "training.save").tap()
			TutorialHarness.wait(TutorialHarness.named(app, "training.athlete"))
			TutorialHarness.wait(TutorialHarness.named(app, "training.fitness"))
			XCTAssertEqual(TutorialHarness.named(app, "training.athlete").label, "Ada Kovač")
			assertSecretAbsent()
			TutorialHarness.attach(self, name: "native-keychain-saved-settings", app: app)
			TutorialHarness.returnToChat(app)
			TutorialHarness.exchange(app, "fixture:training-data")
			let before = try receipts("native-keychain-before-relaunch")
			XCTAssertTrue(
				before.attempts.contains {
					$0.slot == "intervalsConnection" && $0.operation == "add" && $0.status == 0
				})
			XCTAssertEqual(before.turnAccounts.count, 1)
			TutorialHarness.relaunchKeepingStore(app)
			TutorialHarness.openCredentials(app)
			TutorialHarness.wait(TutorialHarness.named(app, "training.athlete"))
			TutorialHarness.wait(TutorialHarness.named(app, "training.fitness"))
			XCTAssertEqual(TutorialHarness.named(app, "training.athlete").label, "Ada Kovač")
			XCTAssertEqual(TutorialHarness.named(app, "training.athleteID").label, "Athlete i1001")
			assertSecretAbsent()
			TutorialHarness.attach(self, name: "native-keychain-relaunched-settings", app: app)
			TutorialHarness.returnToChat(app)
			TutorialHarness.exchange(app, "fixture:training-data")
			TutorialHarness.waitForLabel(
				app, "I can read Ada Kovač's training profile and calendar.")
			assertSecretAbsent()
			TutorialHarness.attach(self, name: "native-keychain-service-completed", app: app)
			let after = try receipts("native-keychain-after-relaunch")
			XCTAssertEqual(after.turnAccounts, before.turnAccounts + before.turnAccounts)
			XCTAssertFalse(
				after.attempts.contains { ["add", "update", "delete"].contains($0.operation) })
			TutorialHarness.openRecords(app)
			assertSecretAbsent()
			TutorialHarness.attach(self, name: "native-keychain-records", app: app)
			TutorialHarness.returnToChat(app)
		}

		private func receipts(_ name: String) throws -> Receipt {
			TutorialHarness.openDebug(app)
			let row = TutorialHarness.debugRow(app, "fixture.nativeKeychain")
			TutorialHarness.wait(
				until: { (row.value as? String ?? "waiting") != "waiting" },
				message: "Native receipts were not available")
			guard let raw = row.value as? String else {
				throw PhoneRunBlocked(reason: "Native Keychain receipts were missing.")
			}
			assertSecretAbsent()
			attach(raw, name: name)
			let receipt = try JSONDecoder().decode(Receipt.self, from: Data(raw.utf8))
			XCTAssertEqual(receipt.service, NativeKeychainProof.service)
			XCTAssertFalse(receipt.buildVersion.contains("missing"))
			XCTAssertFalse(receipt.attempts.isEmpty)
			XCTAssertTrue(
				receipt.attempts.contains {
					$0.slot == "intervalsConnection" && $0.operation == "copy" && $0.status == 0
				})
			for attempt in receipt.attempts {
				XCTAssertGreaterThanOrEqual(attempt.milliseconds, 0)
				XCTAssertLessThan(
					attempt.milliseconds, 50,
					"\(attempt.operation) \(attempt.slot) status \(attempt.status)")
			}
			XCTAssertFalse(receipt.bindings.isEmpty)
			XCTAssertTrue(receipt.bindings.allSatisfy { $0.credentialMatches && $0.keyOwner })
			XCTAssertEqual(receipt.athleteID, "i1001")
			XCTAssertGreaterThan(receipt.profileReads, 0)
			XCTAssertGreaterThan(receipt.wellnessReads, 0)
			XCTAssertGreaterThan(receipt.calendarReads, 0)
			XCTAssertGreaterThan(receipt.recordCount, 0)
			XCTAssertFalse(receipt.recordsContainSecret)
			XCTAssertFalse(receipt.diagnosticsContainSecret)
			TutorialHarness.returnToChat(app)
			return receipt
		}

		private func assertSecretAbsent() {
			let tree = app.debugDescription
			XCTAssertFalse(tree.contains(NativeKeychainProof.syntheticKey))
			XCTAssertFalse(tree.contains("fixture-credits-key"))
		}

		private func attach(_ text: String, name: String) {
			let attachment = XCTAttachment(string: text)
			attachment.name = name
			attachment.lifetime = .keepAlways
			add(attachment)
		}

		private struct Receipt: Decodable {
			let service: String
			let buildVersion: String
			let attempts: [Attempt]
			let bindings: [Binding]
			let athleteID: String
			let profileReads: Int
			let wellnessReads: Int
			let calendarReads: Int
			let recordCount: Int
			let turnAccounts: [String]
			let recordsContainSecret: Bool
			let diagnosticsContainSecret: Bool
		}

		private struct Attempt: Decodable {
			let operation: String
			let slot: String
			let status: Int
			let milliseconds: Double
		}

		private struct Binding: Decodable {
			let credentialMatches: Bool
			let keyOwner: Bool
		}
	}
#endif
