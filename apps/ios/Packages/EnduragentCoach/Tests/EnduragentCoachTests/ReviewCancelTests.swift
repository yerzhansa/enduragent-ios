import EnduragentCoachFixtures
import Foundation
import Testing

@testable import EnduragentCoach

@Suite struct ReviewCancelTests {
	enum DeadCancel: String, CaseIterable, CustomTestStringConvertible {
		case renewed, consumed

		var testDescription: String { rawValue }
	}

	@Test func cancelBeforeApprovalIsSavedSendsNothingAndItsTokenDiesAfterARelaunch()
		async throws
	{
		let rig = DeskRig()
		let review = try rig.mixed()
		try await rig.save(review)
		let desk = try rig.desk()
		let token = try await rig.token(on: desk)

		#expect(await desk.decide(.cancel(token)) == .canceled([]))

		#expect(
			try await rig.head().1?.stage
				== .canceled(Cancellation(givenUp: review.work.remaining, unconfirmed: nil)))
		let published = try await rig.outcomes()
		#expect(published.map(\.ending) == [.canceled])
		#expect(published.first?.lines.map(\.result) == Array(repeating: .givenUp, count: 4))
		#expect(rig.calendar.calls.isEmpty)
		let records = try await rig.chain().count
		let relaunched = try rig.desk()
		#expect(try await relaunched.snapshot(chat: .main) == nil)
		#expect(await relaunched.decide(.approve(token)) == .staleControl(newer: nil))
		#expect(await relaunched.decide(.cancel(token)) == .staleControl(newer: nil))
		#expect(rig.calendar.calls.isEmpty)
		#expect(try await rig.chain().count == records)
	}

	@Test(arguments: DeadCancel.allCases)
	func aStaleOrConsumedCancelSavesNothing(_ dead: DeadCancel) async throws {
		let rig = DeskRig()
		try await rig.save(try rig.mixed())
		let desk = try rig.desk()
		let token = try await rig.token(on: desk)
		switch dead {
		case .renewed:
			#expect(await desk.decide(.showAgain(token.ref)) == .presentationRecorded)
		case .consumed:
			#expect(await desk.decide(.cancel(token)) == .canceled([]))
		}
		let records = try await rig.chain().count
		let published = try await rig.outcomes().count

		guard case .staleControl = await desk.decide(.cancel(token)) else {
			Issue.record("a dead Cancel token was accepted")
			return
		}

		#expect(try await rig.chain().count == records)
		#expect(try await rig.outcomes().count == published)
	}

	@Test func cancelAfterTwoFinishedChangesKeepsBothReceipts() async throws {
		let rig = DeskRig()
		let review = try rig.mixed()
		try await rig.save(review)
		rig.calendar.answer { index, _ in index == 2 ? .httpStatus(400) : nil }
		let desk = try rig.desk()
		_ = await desk.decide(.approve(try await rig.token(on: desk)))

		let outcome = await desk.decide(.cancel(try await rig.token(on: desk)))

		let kept = [
			ReviewReceipt(index: 0, progress: .saved(EventID(rawValue: 204))),
			ReviewReceipt(index: 1, progress: .saved(EventID(rawValue: 205))),
		]
		#expect(outcome == .canceled(kept))
		let head = try #require(try await rig.head().1)
		#expect(head.work.finished.map(\.change) == Array(review.work.remaining.prefix(2)))
		#expect(
			head.stage
				== .canceled(
					Cancellation(givenUp: Array(review.work.remaining.suffix(2)), unconfirmed: nil))
		)
		#expect(
			try await rig.outcomes().first?.lines.map(\.result) == [
				.saved, .saved, .givenUp, .givenUp,
			])
		#expect(rig.calendar.writes.count == 3)
	}

	@Test func approveAndCancelRacedSaveOneHeadThatTheShownOutcomeMatches() async throws {
		let rig = DeskRig()
		try await rig.save(try rig.mixed())
		let desk = try rig.desk()
		let token = try await rig.token(on: desk)

		async let approval = desk.decide(.approve(token))
		async let cancellation = desk.decide(.cancel(token))
		let (approved, canceled) = await (approval, cancellation)

		let head = try #require(try await rig.head().1)
		switch (approved, canceled) {
		case (.completed, .staleControl(newer: nil)):
			#expect(head.stage == .completed)
			#expect(rig.calendar.writes.count == 4)
		case (.staleControl(newer: nil), .canceled([])):
			guard case .canceled = head.stage else {
				Issue.record("the shown cancel does not match the saved head \(head.stage)")
				return
			}
			#expect(rig.calendar.writes.isEmpty)
		default:
			Issue.record("approve gave \(approved) and cancel gave \(canceled)")
		}
		#expect(try await rig.outcomes().count == 1)
	}
}
