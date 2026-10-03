#if KEYCHAIN_DEVICE_PROOF && !targetEnvironment(simulator)
	import EnduragentCoachFixtures
	import XCTest

	@MainActor
	final class TwoPhoneReconnectCheck: XCTestCase {
		private let app = XCUIApplication(bundleIdentifier: "icu.enduragent.keychainproof")
		private let changedAthlete =
			"This workout was prepared for a different intervals.icu athlete. Ask me again to prepare it for the connected athlete."

		func testTwoPhoneReconnectStep() throws {
			continueAfterFailure = false
			let environment = ProcessInfo.processInfo.environment
			guard let rawBudget = environment["ENDURAGENT_PHONE_MESSAGE_BUDGET"],
				let budget = Int(rawBudget), budget >= 0,
				let updates = environment["ENDURAGENT_DEVICE_UPDATE_CHECK"],
				updates.hasPrefix("updated-together:"), updates.count > 18,
				let otherBuild = environment["ENDURAGENT_OTHER_PHONE_BUILD"],
				!otherBuild.isEmpty, !otherBuild.contains("missing"),
				let rawStep = environment["ENDURAGENT_RECONNECT_STEP"],
				let step = Step(rawValue: rawStep)
			else {
				throw PhoneRunBlocked(
					reason:
						"Ask for this invocation's budget, both build versions, the device-update check and reconnect step."
				)
			}
			attach(
				"Step \(step.rawValue). Budget \(budget). Live messages used 0. Other phone build \(otherBuild). \(updates)",
				name: "operator-check")
			let fresh = step == .preparePeer || step == .prepareReceiver
			TutorialHarness.launch(
				app,
				arguments: FixtureArguments(store: fresh ? .fresh : .keep, keychain: .nativeProof))
			if fresh { TutorialHarness.startUnconnected(app) }
			TutorialHarness.wait(TutorialHarness.named(app, "chat.settings"), until: .hittable)
			switch step {
			case .preparePeer:
				TutorialHarness.openDebug(app)
			case .prepareReceiver:
				TutorialHarness.fixtureControl(app, "fixture.peerA")
				TutorialHarness.exchange(app, TutorialHarness.workout)
				TutorialHarness.wait(
					TutorialHarness.named(app, "chat.preview.add"), until: .enabled)
				TutorialHarness.attach(self, name: "receiver-a-review", app: app)
				TutorialHarness.openDebug(app)
			case .peerB:
				TutorialHarness.openDebug(app)
				try waitForKey("athleteA")
				TutorialHarness.debugRow(app, "fixture.switchAthlete").tap()
				try waitForKey("athleteB")
			case .peerDelete:
				TutorialHarness.openDebug(app)
				try waitForKey("athleteB")
				TutorialHarness.debugRow(app, "fixture.peerDelete").tap()
				try waitForKey("deleted")
			case .receiveForeground:
				TutorialHarness.wait(
					TutorialHarness.named(app, "chat.preview.add"), until: .enabled)
				TutorialHarness.openDebug(app)
				try waitForKey("athleteA")
				attach(
					"Receiver remains in the foreground. Publish B on the peer now.",
					name: "waiting-for-peer")
				try waitForKey("athleteB")
				XCTAssertEqual(app.state, .runningForeground)
				TutorialHarness.returnToChat(app)
				TutorialHarness.named(app, "chat.preview.add").tap()
				TutorialHarness.waitForLabel(app, changedAthlete)
				TutorialHarness.wait(TutorialHarness.named(app, "chat.preview.add"), until: .absent)
				TutorialHarness.attach(self, name: "foreground-old-approval-blocked", app: app)
				TutorialHarness.exchange(app, "fixture:training-data")
				TutorialHarness.waitForLabel(
					app, "I can read Bo Lind's training profile and calendar.")
				TutorialHarness.openDebug(app)
			case .receiveResume:
				TutorialHarness.openDebug(app)
				try waitForKey("athleteA")
				try receiveAfterResume("athleteB")
				TutorialHarness.returnToChat(app)
				TutorialHarness.waitForLabel(app, changedAthlete)
				TutorialHarness.wait(TutorialHarness.named(app, "chat.preview.add"), until: .absent)
				TutorialHarness.openCredentials(app)
				TutorialHarness.wait(TutorialHarness.named(app, "training.athlete"))
				XCTAssertEqual(TutorialHarness.named(app, "training.athlete").label, "Bo Lind")
				TutorialHarness.attach(self, name: "resume-resolved-b", app: app)
				TutorialHarness.returnToChat(app)
				TutorialHarness.openDebug(app)
			case .receiveDeletion:
				TutorialHarness.openDebug(app)
				try waitForKey("athleteB")
				try receiveAfterResume("deleted")
				TutorialHarness.returnToChat(app)
				TutorialHarness.wait(TutorialHarness.named(app, "chat.preview.add"), until: .absent)
				TutorialHarness.exchange(app, "fixture:training-data")
				TutorialHarness.waitForLabel(
					app,
					"intervals.icu is not connected, so I can't read your training profile or calendar."
				)
				TutorialHarness.wait(TutorialHarness.named(app, "chat.preview.notice"))
				TutorialHarness.attach(self, name: "synced-deletion-keeps-review", app: app)
				TutorialHarness.openDebug(app)
			}
			try captureReceipts(step.rawValue, otherBuild: otherBuild)
			TutorialHarness.returnToChat(app)
		}

		private func receiveAfterResume(_ key: String) throws {
			let deadline = ProcessInfo.processInfo.systemUptime + 180
			attach(
				"Receiver backgrounds now. Publish \(key) on the peer.", name: "waiting-for-peer")
			while ProcessInfo.processInfo.systemUptime < deadline {
				XCUIDevice.shared.press(.home)
				RunLoop.current.run(until: Date(timeIntervalSinceNow: 1))
				app.activate()
				let receipt = TutorialHarness.debugRow(app, "fixture.peerReceipt")
				try waitForReceipt(receipt)
				let state = try decode(PeerReceipt.self, row: receipt)
				if state.key == key { return }
			}
			throw PhoneRunBlocked(
				reason:
					"The peer item did not arrive within 180 seconds. Preserve this run and obtain a fresh budget."
			)
		}

		private func waitForKey(_ expected: String) throws {
			let row = TutorialHarness.debugRow(app, "fixture.peerReceipt")
			let deadline = ProcessInfo.processInfo.systemUptime + 180
			while ProcessInfo.processInfo.systemUptime < deadline {
				try waitForReceipt(row)
				if try decode(PeerReceipt.self, row: row).key == expected { return }
				RunLoop.current.run(until: Date(timeIntervalSinceNow: 0.5))
			}
			throw PhoneRunBlocked(
				reason: "Expected peer state \(expected) did not arrive within 180 seconds.")
		}

		private func waitForReceipt(_ row: XCUIElement) throws {
			guard
				TutorialHarness.wait(
					until: { (row.value as? String ?? "waiting") != "waiting" }, required: false,
					message: "Peer receipts missing")
			else {
				throw PhoneRunBlocked(reason: "Peer receipts did not load.")
			}
		}

		private func captureReceipts(_ name: String, otherBuild: String) throws {
			let peerRow = TutorialHarness.debugRow(app, "fixture.peerReceipt")
			try waitForReceipt(peerRow)
			let peer = try decode(PeerReceipt.self, row: peerRow)
			XCTAssertEqual(peer.athleteAWrites, 0)
			XCTAssertEqual(peer.athleteBWrites, 0)
			attach(peerRow.value as? String ?? "missing", name: "\(name)-peer-receipt")
			let nativeRow = TutorialHarness.debugRow(app, "fixture.nativeKeychain")
			try waitForReceipt(nativeRow)
			let native = try decode(NativeReceipt.self, row: nativeRow)
			XCTAssertEqual(native.service, NativeKeychainProof.service)
			XCTAssertFalse(native.buildVersion.contains("missing"))
			XCTAssertFalse(native.recordsContainSecret)
			XCTAssertFalse(native.diagnosticsContainSecret)
			attach(nativeRow.value as? String ?? "missing", name: "\(name)-native-receipt")
			attach(
				"This phone \(native.buildVersion). Other phone \(otherBuild).", name: "both-builds"
			)
			XCTAssertEqual(
				TutorialHarness.debugRow(app, "fixture.requestCount").label, "0 requests")
			TutorialHarness.attach(self, name: "\(name)-receipts", app: app)
		}

		private func decode<Value: Decodable>(_ type: Value.Type, row: XCUIElement) throws -> Value
		{
			guard let raw = row.value as? String else {
				throw PhoneRunBlocked(reason: "Missing receipt value.")
			}
			return try JSONDecoder().decode(type, from: Data(raw.utf8))
		}

		private func attach(_ text: String, name: String) {
			let attachment = XCTAttachment(string: text)
			attachment.name = name
			attachment.lifetime = .keepAlways
			add(attachment)
		}

		private enum Step: String {
			case preparePeer = "prepare-peer"
			case prepareReceiver = "prepare-receiver"
			case peerB = "peer-b"
			case peerDelete = "peer-delete"
			case receiveForeground = "receive-foreground"
			case receiveResume = "receive-resume"
			case receiveDeletion = "receive-deletion"
		}

		private struct PeerReceipt: Decodable {
			let key: String
			let athleteAWrites: Int
			let athleteBWrites: Int
		}

		private struct NativeReceipt: Decodable {
			let service: String
			let buildVersion: String
			let recordsContainSecret: Bool
			let diagnosticsContainSecret: Bool
		}
	}
#endif
