import Foundation
import Testing

@testable import EnduragentCoach

extension DurableCalendarWriteTests {
	@Test(arguments: [
		"null",
		"{}",
		"[null]",
		"[{}]",
		#"[{"id":1,"name":"Ride","category":"WORKOUT"}]"#,
		#"[{"id":1,"name":"Ride","category":"WORKOUT","start_date_local":"invalid"}]"#,
		#"[{"id":1,"name":"Ride","category":"WORKOUT","start_date_local":"1998-06-14T00:00:00","tags":[42]}]"#,
		#"[{"id":1,"name":"Ride","category":"WORKOUT","start_date_local":"1998-06-14T00:00:00"},{}]"#,
	])
	func malformedCalendarListNeverBecomesAnEmptyObservation(body: String) async throws {
		let server = try CalendarWriteServer()
		let url = try await server.start()
		defer { server.stop() }
		server.state.withLock {
			$0.response = .status(503)
			$0.readResponse = .body(body)
		}
		let fixture = await fixture(url: url)
		let (turn, token) = try await proposal(on: fixture.coach, model: fixture.model)
		_ = await fixture.coach.decide(.approve(token), in: .main)
		await fixture.coach.stop(.main)
		await #expect(throws: (any Error).self) {
			_ = try await fixture.client.listEvents(oldest: "1998-06-14", newest: "1998-06-14")
		}
		let review = try #require(await fixture.coach.currentSnapshot(.main)?.review)
		_ = await fixture.coach.decide(.checkAgain(review.ref), in: .main)
		let pending = try #require(await fixture.coach.currentSnapshot(.main)?.review)
		#expect(pending.controls == .checkAgain(pending.ref))
		#expect(pending.notice?.key.rawValue == "review.writeReadFailed")
		#expect(turnNotice(of: try #require(await fixture.coach.state(of: turn)))?.action == nil)
		#expect(server.posts.count == 1)
	}
}
