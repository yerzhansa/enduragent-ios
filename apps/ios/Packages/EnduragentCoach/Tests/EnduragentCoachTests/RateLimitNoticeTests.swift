import Foundation
import Testing

@testable import EnduragentCoach

extension AthleteNoticesTests {
	@Test func unrepresentableRetryAfterUsesDefaultNotice() {
		let turn = TurnID(ulid: fixedUlid(1))
		let shown = AthleteNotices.notice(
			for: .model(.rateLimited(retryAfter: .seconds(Int.max))), turn: turn, waiting: false)
		#expect(shown.key == Catalog.coachErrorRateLimitDefault)
		#expect(shown.vars.isEmpty)
		#expect(shown.action == .tryAgain(turn))
	}

	@Test func largeRepresentableRetryAfterRoundsToMinutes() {
		let turn = TurnID(ulid: fixedUlid(1))
		let shown = AthleteNotices.notice(
			for: .model(.rateLimited(retryAfter: .seconds(Int.max - 2047))), turn: turn,
			waiting: false)
		#expect(shown.key == Catalog.coachErrorRateLimitMinutes)
		#expect(shown.count == 153_722_867_280_912_896)
		#expect(shown.vars == ["minutes": .integer(153_722_867_280_912_896)])
	}

}
