import EnduragentCoachFixtures
import Foundation
import Testing

@testable import EnduragentCoach

@Suite struct ReviewProjectionCardTests {
	let turns = ReviewTurns()
	let today: CivilDate = "1998-09-08"
	let english = displayLocale()

	@Test func everyCardShowsTheDateNameDurationStepsAndLoadThatItsWriteSends() async throws {
		let (coach, calendar) = await seededCoach()
		let cards = try await committed(WorkoutReviewFixture.mixed(today: today), on: coach)
		let writes = try await approved(on: coach, calendar: calendar)

		#expect(writes.count == 4)
		#expect(cards.map(\.action) == [.add, .add, .edit(previousName: "Endurance"), .delete])
		for (card, write) in zip(cards, writes) {
			switch write {
			case .create(let payload, let identity):
				let body = payload.requestBody(identity).objectFields
				#expect(body["start_date_local"] == .string("\(card.date.rawValue)T00:00:00"))
				#expect(body["name"] == .string(card.title(in: english)))
				#expect(
					body["moving_time"]
						== card.durationMinutes.map { JSONValue.number(Double($0 * 60)) })
				#expect(
					body["icu_training_load"]
						== card.estimatedLoad.map { JSONValue.number(Double($0)) })
				#expect(
					body["description"] == .string(card.lines(in: english).joined(separator: "\n")))
			case .update(let event, let patch):
				let body = patch.requestBody.objectFields
				let target = try #require(turns.intervals.events.first { $0.id == event })
				#expect(event == WorkoutReviewFixture.editedEvent)
				#expect(
					body["moving_time"]
						== card.durationMinutes.map { JSONValue.number(Double($0 * 60)) })
				#expect(
					body["description"] == .string(card.lines(in: english).joined(separator: "\n")))
				#expect(body["start_date_local"] == nil)
				#expect(target.startDateLocal == "\(card.date.rawValue)T00:00:00")
				#expect(body["name"] == nil)
				#expect(target.name == card.title(in: english))
				#expect(
					body["icu_training_load"]
						== card.estimatedLoad.map { JSONValue.number(Double($0)) })
			case .delete(let event):
				#expect(event == WorkoutReviewFixture.deletedEvent)
				#expect(card.title(in: english) == "Recovery spin")
			}
		}
		#expect(
			cards.map { $0.heading(of: cards.count, in: english) } == [
				"Add · 1 of 4 · 9/9/1998 · 50 min", "Add · 2 of 4 · 9/10/1998 · 30 min",
				"Edit · 3 of 4 · 9/11/1998 · 75 min", "Delete · 4 of 4 · 9/12/1998 · 30 min",
			])
		#expect(
			cards[0].lines(in: english) == [
				"Warmup", "- 10m 55%", "", "Main set", "- 30m 65-75%", "", "Cooldown", "- 10m 50%",
			])
		#expect(cards[1].lines(in: english) == ["Moderate", "", strengthDescription])
		#expect(
			cards.map { $0.load(in: english) } == [
				"Estimated training load: 42", "Estimated training load: 18",
				"Estimated training load: 60", nil,
			])
		#expect(cards[2].changes(in: english).contains("Estimated training load: 40 → 60"))
		#expect(
			cards[0].chart
				== WorkoutChartModel(
					unit: .percentOfFTP, durationSeconds: 3000,
					segments: [
						.steady(durationSeconds: 600, target: 55),
						.range(durationSeconds: 1800, low: 65, high: 75),
						.steady(durationSeconds: 600, target: 50),
					]))
		#expect(cards[1].chart == nil)
		#expect(cards[3].chart == nil)
	}

	@Test func theEditShowsBothDurationsAndARenameKeepsItsChartAndSteps() async throws {
		let (coach, _) = await seededCoach()
		let first = try await committed(WorkoutReviewFixture.mixed(today: today), on: coach)
		let edit = first[2]

		#expect(
			edit.changes(in: english) == [
				"Duration: 60 min → 75 min", "Estimated training load: 40 → 60",
				"The workout steps change.",
			])
		#expect(edit.heading(of: 4, in: english) == "Edit · 3 of 4 · 9/11/1998 · 75 min")
		#expect(edit.chart?.durationSeconds == 4500)
		#expect(edit.chart?.segments.count == 8)
		#expect(
			edit.lines(in: english) == [
				"Warmup", "- 15m 55%", "", "Main set 3x", "- 10m 95%", "- 5m 50%", "", "Cooldown",
				"- 15m 50%",
			])

		_ = try await turns.reply(
			after: [.toolCall(name: "get_pending_workout_changes", arguments: "{}")], on: coach)
		let results = try #require(turns.transport.requests.last).messages
			.filter { $0.role == .tool }.map(\.content)
		let renamed = try await committed(
			try #require(try WorkoutReviewFixture.rename(after: results)), on: coach)

		#expect(try await turns.head(of: coach).1?.revision == ReviewRevision(rawValue: 2))
		#expect(renamed[2].title(in: english) == WorkoutReviewFixture.renamed)
		#expect(renamed[2].chart == edit.chart)
		#expect(renamed[2].lines(in: english) == edit.lines(in: english))
		#expect(
			renamed[2].changes(in: english) == [
				"Name: Endurance → Threshold 3x10", "Duration: 60 min → 75 min",
				"Estimated training load: 40 → 60", "The workout steps change.",
			])
	}

	@Test func aRenameOrADateMoveAloneIsOneCompactLine() async throws {
		let (coach, _) = await seededCoach()
		let cards = try await committed(
			#"{"preparation":{"kind":"complete","changes":[{"kind":"edit","eventId":201,"patch":{"name":"Long endurance"}},{"kind":"edit","eventId":202,"patch":{"date":"1998-09-13"}}]}}"#,
			on: coach)

		#expect(
			cards.map { $0.changes(in: english) } == [
				["Name: Endurance → Long endurance"], ["Date: 9/11/1998 → 9/13/1998"],
			])
		#expect(cards.map { $0.lines(in: english) } == [["Steady ride"], ["Steady ride"]])
	}

	@Test func aDeleteCardSaysItWillBeRemovedAndTheReviewOffersNoAdd() async throws {
		let (coach, _) = await seededCoach()
		let cards = try await committed(WorkoutReviewFixture.deleteOnly, on: coach)
		let shown = try #require(try await coach.desk.snapshot(chat: .main))

		#expect(cards.count == 1)
		#expect(cards[0].title(in: english) == "Recovery spin")
		#expect(cards[0].heading(of: 1, in: english) == "Delete · 1 of 1 · 9/12/1998 · 30 min")
		#expect(
			cards[0].changes(in: english) == ["This workout will be removed from the calendar."])
		#expect(cards[0].load(in: english) == nil)
		#expect(shown.content.approveTitle == Catalog.workoutsApprove)
		#expect(english.say(shown.content.approveTitle) == "Apply changes")
		let mixed = try await committedElsewhere(WorkoutReviewFixture.mixed(today: today))
		#expect(mixed.approveTitle == Catalog.workoutsApprove)
		let add = try await committedElsewhere(ReviewTurns.oneRide.preparationArguments)
		#expect(add.approveTitle == Catalog.reviewAdd)
	}

	@Test func aCardWithNoKnownDurationSaysUnknownNeverZero() async throws {
		turns.intervals.events = [
			PreparationFixture.workout(401, on: "1998-09-10", name: "Open ride", minutes: nil),
			PreparationFixture.workout(402, on: "1998-09-11", name: "Free spin", minutes: nil),
			PreparationFixture.workout(403, on: "1998-09-12", name: "Spin", minutes: nil),
		]
		let cards = try await committed(
			#"{"preparation":{"kind":"complete","changes":[{"kind":"edit","eventId":401,"patch":{"name":"Long open ride"}},{"kind":"edit","eventId":402,"patch":{"durationSeconds":3600}},{"kind":"delete","eventId":403}]}}"#,
			on: await turns.coach())

		#expect(cards.map(\.durationMinutes) == [nil, 60, nil])
		#expect(
			cards.map { $0.heading(of: 3, in: english) } == [
				"Edit · 1 of 3 · 9/10/1998 · duration unknown",
				"Edit · 2 of 3 · 9/11/1998 · 60 min",
				"Delete · 3 of 3 · 9/12/1998 · duration unknown",
			])
		#expect(cards[1].changes(in: english) == ["Duration: unknown → 60 min"])
	}

	@Test func eachCardShowsItsProgressAfterApproval() async throws {
		let (coach, calendar) = await seededCoach()
		let before = try await committed(WorkoutReviewFixture.mixed(today: today), on: coach)
		calendar.answer { index, _ in index == 2 ? .httpStatus(400) : nil }

		let outcome = await coach.desk.decide(.approve(try await armed(coach)))

		#expect(before.map { $0.status(in: english) } == [nil, nil, nil, nil])
		guard case .stopped = outcome else {
			Issue.record("the refused edit ended \(outcome)")
			return
		}
		let cards = try #require(try await coach.desk.snapshot(chat: .main)).cards
		#expect(cards.map { $0.status(in: english) } == ["Saved", "Saved", "Not saved", nil])
	}

	private var strengthDescription: String {
		"3 rounds: plank 45s, side plank 30s, glute bridge 12"
	}

	private func seededCoach() async -> (Coach, ScriptedCalendar) {
		WorkoutReviewFixture.seed(turns.intervals, today: today)
		let calendar = ScriptedCalendar(turns.intervals)
		let coach = await makeCoach(
			transport: turns.transport, intervals: calendar, store: turns.store,
			clock: turns.clock)
		return (coach, calendar)
	}

	private func committed(_ arguments: String, on coach: Coach) async throws -> [ReviewCard] {
		_ = try await turns.reply(
			after: [.toolCall(name: "prepare_workout_changes", arguments: arguments)], on: coach)
		return try #require(try await coach.desk.snapshot(chat: .main)).cards
	}

	private func committedElsewhere(_ arguments: String) async throws -> ReviewContent {
		let other = ReviewTurns()
		WorkoutReviewFixture.seed(other.intervals, today: today)
		let coach = await other.coach()
		_ = try await other.reply(
			after: [.toolCall(name: "prepare_workout_changes", arguments: arguments)], on: coach)
		return try #require(try await coach.desk.snapshot(chat: .main)).content
	}

	private func approved(on coach: Coach, calendar: ScriptedCalendar) async throws
		-> [CalendarWrite]
	{
		guard case .completed = await coach.desk.decide(.approve(try await armed(coach))) else {
			Issue.record("the approval did not complete")
			return []
		}
		return calendar.writes
	}

	private func armed(_ coach: Coach) async throws -> ReviewControlToken {
		let shown = try #require(try await coach.desk.snapshot(chat: .main))
		#expect(await coach.desk.decide(.presented(shown.ref)) == .presentationRecorded)
		let controls = try #require(try await coach.desk.snapshot(chat: .main)).controls
		guard case .armed(.approveOrCancel, let token) = controls else {
			throw ArmingFailure(controls: controls)
		}
		return token
	}

	private struct ArmingFailure: Error {
		let controls: ReviewControls
	}
}

extension String {
	fileprivate var preparationArguments: String { #"{"preparation":\#(self)}"# }
}
