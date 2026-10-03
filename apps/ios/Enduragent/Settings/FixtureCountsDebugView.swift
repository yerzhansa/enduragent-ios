#if DEBUG
	import EnduragentCoach
	import Foundation
	import SwiftUI

	struct FixtureCountsDebugView: View {
		var model: ShellModel
		var services: AppServices { model.services }
		@State private var reviewHookFailure: String?

		var body: some View {
			if let fixture = services.fixture {
				if let backing = fixture.secretBacking {
					Button("Fail next credential write") { backing.failNextWrite = true }
						.accessibilityIdentifier("fixture.failCredentialWrite")
					Button(backing.locked ? "Unlock keychain" : "Lock keychain") {
						backing.locked.toggle()
						Task { await model.sceneChanged(.becameActive) }
					}
					.accessibilityIdentifier("fixture.toggleKeychainLock")
					Button("Restore secure storage") {
						backing.unavailable = false
					}
					.accessibilityIdentifier("fixture.restoreSecureStorage")
					Button("Corrupt intervals credential") {
						do {
							try backing.corruptIntervalsConnection()
							Task { await model.sceneChanged(.becameActive) }
						} catch {
							reviewHookFailure = String(describing: error)
						}
					}
					.accessibilityIdentifier("fixture.corruptIntervals")
				}
				if let proof = fixture.nativeKeychain {
					NativeKeychainDebugView(proof: proof, fixture: fixture, coach: services.coach)
				}
				Text(connectionText)
					.accessibilityIdentifier("fixture.connection")
				Button("Fail next record append") { fixture.records.failNextAppend = true }
					.accessibilityIdentifier("fixture.failNextAppend")
				Button("Fail next review read") {
					Task {
						guard let review = model.chat?.review
						else { return }
						fixture.records.failNextReviewRead()
						_ = await services.coach.decide(.presented(review.ref), in: .main)
					}
				}
				.accessibilityIdentifier("fixture.failReviewRead")
				Button("Refresh review") {
					Task {
						guard let review = model.chat?.review
						else { return }
						_ = await services.coach.decide(.checkAgain(review.ref), in: .main)
					}
				}
				.accessibilityIdentifier("fixture.refreshReview")
				Button("Fail next calendar read") { fixture.intervals.failCalendarReadOnce = true }
					.accessibilityIdentifier("fixture.failCalendarRead")
				if let backing = fixture.secretBacking {
					Button("Lock intervals credential") { backing.locked = true }
						.accessibilityIdentifier("fixture.lockIntervals")
				}
				FixtureTrainingPeerDebugView(peer: fixture.trainingPeer)
				Text("\(fixture.intervals.calls.count) calendar calls")
					.accessibilityIdentifier("fixture.calendarCalls")
				Text(
					fixture.intervals.failCalendarReadOnce
						? "Calendar read fault armed" : "Calendar read fault consumed"
				)
				.accessibilityIdentifier("fixture.calendarReadFault")
				if let host = fixture.host {
					Button("Expire current lease") {
						Task { await host.expire(.systemExpired) }
					}
					.accessibilityIdentifier("fixture.expire")
				}
			}
			if let reviewHookFailure { Text(reviewHookFailure) }
			Text("\(FixtureBlockingURLProtocol.requestCount) requests")
				.accessibilityIdentifier("fixture.requestCount")
			Text("\(services.fixtureTransport?.requestCount ?? 0) model requests")
				.accessibilityIdentifier("fixture.modelRequestCount")
			Text(services.fixtureTransport?.lastChatHistoryHead ?? "—")
				.accessibilityIdentifier("fixture.historyHead")
			Text(services.fixtureTransport?.lastReplyLanguage ?? "—")
				.accessibilityIdentifier("fixture.replyLanguage")
		}
		private var connectionText: String {
			switch model.status.training {
			case .connected(_, .intervals(let connection, let athlete)):
				"intervals:\(connection.rawValue.uuidString):\(athlete?.rawValue ?? "unresolved")"
			case .connected(_, .unconnected), .unconnected: "unconnected"
			case .unavailable: "unavailable"
			}
		}

	}
#endif
