import EnduragentCoachFixtures
import Foundation
import Testing

@testable import EnduragentCoach

@Suite struct ReviewPresentationHandshakeTests {
	let turns = ReviewTurns()

	@Test func theCardArmsOnlyAfterItsDeliveryIsPresented() async throws {
		let coach = await turns.coach()
		_ = try await turns.committed(ReviewTurns.oneRide, on: coach)
		let shown = try #require(try await coach.desk.snapshot(chat: .main))
		#expect(shown.controls == .none)
		#expect(try await coach.desk.snapshot(chat: .main) == shown)

		#expect(await coach.desk.decide(.presented(shown.ref)) == .presentationRecorded)

		let armed = try #require(try await coach.desk.snapshot(chat: .main))
		guard case .armed(let set, let token) = armed.controls else {
			Issue.record("the presented card has no control")
			return
		}
		#expect(set == .approveOrCancel)
		#expect(token.ref == shown.ref)
	}

	@Test func aFailedPresentationDisarmsAndShowAgainStartsANewDelivery() async throws {
		let coach = await turns.coach()
		_ = try await turns.committed(ReviewTurns.oneRide, on: coach)
		let shown = try #require(try await coach.desk.snapshot(chat: .main))
		_ = await coach.desk.decide(.presented(shown.ref))
		let token = try armedToken(try #require(try await coach.desk.snapshot(chat: .main)))

		#expect(await coach.desk.decide(.presentationFailed(shown.ref)) == .presentationRecorded)
		#expect(try await coach.desk.snapshot(chat: .main)?.controls == ReviewControls.none)
		#expect(await coach.desk.decide(.approve(token)) == .staleControl(newer: shown.ref))

		#expect(await coach.desk.decide(.showAgain(shown.ref)) == .presentationRecorded)
		let again = try #require(try await coach.desk.snapshot(chat: .main))
		#expect(again.ref != shown.ref)
		#expect(again.ref.revision == shown.ref.revision)
		#expect(again.controls == .none)
		#expect(await coach.desk.decide(.presented(shown.ref)) == .staleControl(newer: again.ref))
		#expect(try await coach.desk.snapshot(chat: .main)?.controls == ReviewControls.none)
		#expect(await coach.desk.decide(.presented(again.ref)) == .presentationRecorded)
		#expect(
			try armedToken(try #require(try await coach.desk.snapshot(chat: .main))).ref
				== again.ref)
	}

	@Test func aPresentationOfAnOlderHeadArmsNothing() async throws {
		let coach = await turns.coach()
		let first = try await turns.committed(ReviewTurns.oneRide, on: coach)
		let older = try #require(try await coach.desk.snapshot(chat: .main))
		let ride = try #require(first.work.remaining.first)
		_ = try await turns.reply(
			after: [
				turns.prepare(
					turns.revise(
						first, [(ride.reference, PreparationFixture.ride(on: "1998-09-12"))]))
			], on: coach)

		let presentation = await coach.desk.decide(.presented(older.ref))

		let current = try #require(try await coach.desk.snapshot(chat: .main))
		#expect(presentation == .staleControl(newer: current.ref))
		#expect(current.ref.revision == ReviewRevision(rawValue: 2))
		#expect(current.controls == .none)
	}

	private func armedToken(_ snapshot: ReviewSnapshot) throws -> ReviewControlToken {
		guard case .armed(_, let token) = snapshot.controls else {
			throw UnarmedCard()
		}
		return token
	}

	private struct UnarmedCard: Error {}
}
