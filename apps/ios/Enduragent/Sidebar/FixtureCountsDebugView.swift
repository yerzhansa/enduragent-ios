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
				Button("Lock intervals credential") { fixture.secretBacking.locked = true }
					.accessibilityIdentifier("fixture.lockIntervals")
				Button("Switch fixture athlete") {
					Task {
						do {
							try fixture.secrets.storeIntervalsConnection(
								IntervalsConnection(
									id: ConnectionID(), credential: .apiKey("fixture-athlete-b"),
									selection: .keyOwner,
									resolvedAthlete: IntervalsAthleteID(rawValue: "i2002")))
							if let review = model.chat?.review {
								_ = await services.coach.decide(.presented(review.ref), in: .main)
							}
						} catch {
							reviewHookFailure = String(describing: error)
						}
					}
				}
				.accessibilityIdentifier("fixture.switchAthlete")
				Text("\(fixture.intervals.calls.count) calendar calls")
					.accessibilityIdentifier("fixture.calendarCalls")
				Text(
					fixture.intervals.failCalendarReadOnce
						? "Calendar read fault armed" : "Calendar read fault consumed"
				)
				.accessibilityIdentifier("fixture.calendarReadFault")
				Button("Expire current lease") {
					Task { await fixture.host.expire(.systemExpired) }
				}
				.accessibilityIdentifier("fixture.expire")
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
	}
#endif
