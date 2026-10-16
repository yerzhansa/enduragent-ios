import Foundation
import Testing

@testable import EnduragentCoach

@Suite struct CalendarWriterTests {
	enum Written: String, CaseIterable, Sendable {
		case add, edit, delete, editWithSteps, loadOnlyWithSteps

		var attempt: SendAttempt {
			get throws {
				switch self {
				case .add:
					try Self.running("workout-review-approval", .approve, seen: [:])
				case .edit:
					try Self.running(
						"workout-review-approval", .approve,
						seen: [reviewChange(401): EventID(rawValue: 301)])
				case .delete:
					try Self.running(
						"workout-review-interrupted-before-writing", .approve, seen: [:])
				case .editWithSteps:
					try Self.running("workout-review-try-again", .tryAgain, seen: [:])
				case .loadOnlyWithSteps:
					try Self.running("workout-review-try-again-load-only", .tryAgain, seen: [:])
				}
			}
		}

		private static func running(
			_ fixture: String, _ action: ClaimedAction, seen: [ChangeID: EventID]
		) throws -> SendAttempt {
			let review = try reviewFixture(fixture).claimed(Claim(id: claimID(9), action: action))
				.sending(at: reviewClock, seen: seen)
			guard case .running(let run) = review.stage, let attempt = run.sending else {
				throw UnexpectedReview(detail: "\(fixture) started no send attempt")
			}
			return attempt
		}
	}

	enum Classified: Equatable, Sendable, CustomStringConvertible {
		case saved(Int)
		case gone
		case refused(Int)
		case lost(LostAnswer)

		init(_ answer: SendAnswer) {
			switch answer {
			case .saved(let receipt): self = .saved(receipt.event.rawValue)
			case .gone: self = .gone
			case .refused(let status): self = .refused(status.rawValue)
			case .lost(let loss): self = .lost(loss)
			}
		}

		var description: String {
			switch self {
			case .saved(let event): "saved \(event)"
			case .gone: "gone"
			case .refused(let status): "refused \(status)"
			case .lost(let loss): "lost \(loss)"
			}
		}
	}

	struct SendRow: Sendable, CustomTestStringConvertible {
		let written: Written
		let answer: StubAnswer
		let expected: Classified
		let note: String

		var testDescription: String { "\(written) answered \(note) is \(expected)" }
	}

	struct SettleRow: Sendable, CustomTestStringConvertible {
		let written: Written
		let answer: StubAnswer
		let expected: SettleRead
		let note: String

		var testDescription: String { "settle of \(written) reading \(note) is \(expected)" }
	}

	static func json(_ fields: [String: JSONValue], _ changes: [String: JSONValue] = [:])
		-> JSONValue
	{
		.object(fields.merging(changes) { _, changed in changed })
	}

	static func ok(_ value: JSONValue) -> StubAnswer {
		.status(200, value.canonicalDigestInput())
	}

	static func echo(_ changes: [String: JSONValue] = [:]) -> StubAnswer {
		ok(.array([json(tempoRide, changes)]))
	}

	static let sendRows: [SendRow] =
		[
			SendRow(written: .add, answer: echo(), expected: .saved(301), note: "its echo"),
			SendRow(
				written: .add,
				answer: echo([
					"icu_training_load": .number(41),
					"workout_doc": .object([
						"duration": .number(3000),
						"steps": .array([.object(["duration": .number(600)])]),
					]),
				]),
				expected: .saved(301), note: "intervals.icu's own Load and derived workout_doc"),
			SendRow(
				written: .add,
				answer: echo([
					"external_id": .string("cycling-coach:00000000-0000-4000-8000-000000000000"),
					"uid": .string("E621E1F8-C36C-495A-93FC-0C247A3E6E5F"),
				]),
				expected: .lost(.answerNamesOtherEvent),
				note: "another external_id and the add's uid"),
			SendRow(
				written: .add, answer: echo(["external_id": .null]),
				expected: .lost(.answerNamesOtherEvent), note: "no external_id"),
			SendRow(
				written: .add, answer: echo(["start_date_local": .string("1998-06-17T00:00:00")]),
				expected: .lost(.answerNamesOtherEvent), note: "another date"),
			SendRow(
				written: .add, answer: echo(["name": .string("Tempo ride 2")]),
				expected: .lost(.answerNamesOtherEvent), note: "another name"),
			SendRow(
				written: .add, answer: echo(["type": .string("VirtualRide")]),
				expected: .lost(.answerNamesOtherEvent), note: "another type"),
			SendRow(
				written: .add, answer: echo(["description": .string("Warmup\n- 10m 60%")]),
				expected: .lost(.answerNamesOtherEvent), note: "another description"),
			SendRow(
				written: .edit, answer: ok(json(endurance)), expected: .saved(101),
				note: "its target"),
			SendRow(
				written: .edit, answer: ok(json(endurance, ["id": .number(102)])),
				expected: .lost(.answerNamesOtherEvent), note: "another event"),
			SendRow(
				written: .editWithSteps, answer: ok(json(sweetSpot)), expected: .saved(104),
				note: "its target"),
			SendRow(written: .delete, answer: .status(200, ""), expected: .saved(112), note: "2xx"),
			SendRow(written: .delete, answer: .status(204, ""), expected: .saved(112), note: "204"),
			SendRow(written: .delete, answer: .status(404, "{}"), expected: .gone, note: "404"),
		]
		+ [Written.add, .edit].flatMap { written in
			[400, 401, 403, 404, 429].map { status in
				SendRow(
					written: written, answer: .status(status, "{}"), expected: .refused(status),
					note: "\(status)")
			}
		}
		+ [400, 401, 403, 429].map { status in
			SendRow(
				written: .delete, answer: .status(status, "{}"), expected: .refused(status),
				note: "\(status)")
		}
		+ [Written.add, .edit, .delete].flatMap { written in
			[
				SendRow(
					written: written, answer: .status(500, "{}"),
					expected: .lost(.serverStatus(500)), note: "500"),
				SendRow(
					written: written, answer: .status(502, ""), expected: .lost(.serverStatus(502)),
					note: "502"),
				SendRow(
					written: written, answer: .failure(.timedOut), expected: .lost(.transport),
					note: "a timeout"),
				SendRow(
					written: written, answer: .failure(.cancelled), expected: .lost(.canceled),
					note: "a cancellation"),
			]
		}
		+ [Written.add, .edit].map { written in
			SendRow(
				written: written, answer: .status(200, "not json"),
				expected: .lost(.unreadableBody), note: "an unreadable body")
		}

	static let settleRows: [SettleRow] = [
		SettleRow(
			written: .add,
			answer: ok(
				.array([
					json(recoverySpin),
					json(tempoRide, ["external_id": .string("cycling-coach:x")]),
					json(tempoRide, ["id": .number(305)]),
				])),
			expected: .seen(EventID(rawValue: 305)), note: "one event with its external_id"),
		SettleRow(
			written: .add,
			answer: ok(
				.array([json(tempoRide, ["start_date_local": .string("1998-09-30T00:00:00")])])),
			expected: .seen(EventID(rawValue: 301)), note: "it moved to another day"),
		SettleRow(
			written: .add,
			answer: ok(
				.array([
					json(
						tempoRide,
						[
							"external_id": .string("cycling-coach:other"),
							"uid": .string("E621E1F8-C36C-495A-93FC-0C247A3E6E5F"),
						]), json(recoverySpin),
				])),
			expected: .notSaved, note: "only its uid on another event"),
		SettleRow(written: .add, answer: ok(.array([])), expected: .notSaved, note: "nothing"),
		SettleRow(
			written: .add,
			answer: ok(.array([json(tempoRide), json(tempoRide, ["id": .number(302)])])),
			expected: .readFailed, note: "two events with its external_id"),
		SettleRow(written: .add, answer: .status(500, "{}"), expected: .readFailed, note: "500"),
		SettleRow(
			written: .add, answer: .failure(.timedOut), expected: .readFailed, note: "a timeout"),
		SettleRow(
			written: .add, answer: .status(200, "not json"), expected: .readFailed,
			note: "an unreadable body"),
		SettleRow(
			written: .edit, answer: ok(json(endurance)), expected: .seen(EventID(rawValue: 101)),
			note: "the patch applied"),
		SettleRow(
			written: .edit, answer: ok(json(endurance, ["moving_time": .number(3600)])),
			expected: .notSaved, note: "the patch not applied"),
		SettleRow(
			written: .edit, answer: .status(404, "{}"), expected: .notSaved, note: "404"),
		SettleRow(written: .edit, answer: .status(500, "{}"), expected: .readFailed, note: "500"),
		SettleRow(
			written: .edit, answer: .failure(.timedOut), expected: .readFailed, note: "a timeout"),
		SettleRow(
			written: .editWithSteps, answer: ok(json(sweetSpot)),
			expected: .seen(EventID(rawValue: 104)),
			note: "intervals.icu's own Load from the steps and a derived workout_doc"),
		SettleRow(
			written: .editWithSteps,
			answer: ok(json(sweetSpot, ["workout_doc": .object(["steps": .array([])])])),
			expected: .notSaved, note: "another Load and no steps"),
		SettleRow(
			written: .editWithSteps,
			answer: ok(json(sweetSpot, ["start_date_local": .string("1998-06-25T00:00:00")])),
			expected: .notSaved, note: "another date beside intervals.icu's own Load"),
		SettleRow(
			written: .loadOnlyWithSteps, answer: ok(json(sweetSpot)), expected: .notSaved,
			note: "its old Load beside steps, with no description sent"),
		SettleRow(
			written: .loadOnlyWithSteps,
			answer: ok(json(sweetSpot, ["icu_training_load": .number(75)])),
			expected: .seen(EventID(rawValue: 104)),
			note: "the sent Load beside steps, with no description sent"),
		SettleRow(written: .delete, answer: .status(404, "{}"), expected: .gone, note: "404"),
		SettleRow(
			written: .delete, answer: ok(json(recoverySpin)), expected: .notSaved,
			note: "it is still there"),
		SettleRow(
			written: .delete, answer: .status(500, "{}"), expected: .readFailed, note: "500"),
		SettleRow(
			written: .delete, answer: .failure(.timedOut), expected: .readFailed,
			note: "a timeout"),
	]

	@Test func eachChangeSendsOneRequestWithItsReviewedBodyAndNoOther() async throws {
		let expected: [Written: (SentRequest, JSONValue?)] = [
			.add: (
				SentRequest(
					method: "POST", path: "/api/v1/athlete/0/events/bulk",
					query: "upsert=true&upsertOnUid=false&updatePlanApplied=false", body: nil),
				.array([
					.object([
						"start_date_local": .string("1998-06-16T00:00:00"),
						"category": .string("WORKOUT"), "type": .string("Ride"),
						"name": .string("Tempo ride"),
						"description": .string("Warmup\n- 10m 60%\nMain set\n- 3x10m 85%"),
						"moving_time": .number(3000), "icu_training_load": .number(55),
						"external_id": .string(
							"cycling-coach:E621E1F8-C36C-495A-93FC-0C247A3E6E5F"),
						"uid": .string("E621E1F8-C36C-495A-93FC-0C247A3E6E5F"),
						"tags": .array([.string(IntervalsPolicy.coachTag)]),
					])
				])
			),
			.edit: (
				SentRequest(
					method: "PUT", path: "/api/v1/athlete/0/events/101", query: nil, body: nil),
				.object(["moving_time": .number(4500)])
			),
			.editWithSteps: (
				SentRequest(
					method: "PUT", path: "/api/v1/athlete/0/events/104", query: nil, body: nil),
				.object([
					"start_date_local": .string("1998-06-24T00:00:00"),
					"description": .string("Warmup\n- 10m 60%\nMain set\n- 3x15m 90%"),
					"icu_training_load": .number(75),
				])
			),
			.loadOnlyWithSteps: (
				SentRequest(
					method: "PUT", path: "/api/v1/athlete/0/events/104", query: nil, body: nil),
				.object(["icu_training_load": .number(75)])
			),
			.delete: (
				SentRequest(
					method: "DELETE", path: "/api/v1/athlete/0/events/112", query: nil, body: nil),
				nil
			),
		]
		let answers: [Written: StubAnswer] = [
			.add: Self.echo(), .edit: Self.ok(Self.json(Self.endurance)),
			.editWithSteps: Self.ok(Self.json(Self.sweetSpot)),
			.loadOnlyWithSteps: Self.ok(Self.json(Self.sweetSpot)), .delete: .status(200, ""),
		]
		for written in Written.allCases {
			let attempt = try written.attempt
			let (answer, sent) = await CalendarWriterLine.answering(try #require(answers[written]))
			{
				await CalendarWriter.send(attempt, on: $0, now: reviewClock)
			}
			let request = try #require(expected[written])
			#expect(sent.count == 1, "\(written) sent \(sent)")
			let only = try #require(sent.first)
			#expect(
				SentRequest(method: only.method, path: only.path, query: only.query, body: nil)
					== request.0)
			#expect(try only.json == request.1)
			guard case .saved(let receipt) = answer else {
				Issue.record("\(written) answered \(answer)")
				continue
			}
			#expect(receipt.answeredAt == reviewClock)
		}
	}

	@Test(arguments: sendRows)
	func eachAnswerOfEachWriteKindIsClassifiedOnce(row: SendRow) async throws {
		let attempt = try row.written.attempt
		let later = reviewClock.addingTimeInterval(45)

		let (answer, sent) = await CalendarWriterLine.answering(row.answer) {
			await CalendarWriter.send(attempt, on: $0, now: later)
		}

		#expect(Classified(answer) == row.expected)
		#expect(sent.count == 1, "sent \(sent)")
		#expect(sent.allSatisfy { $0.method != "GET" })
		if case .saved(let receipt) = answer {
			#expect(receipt.answeredAt == later)
		}
	}

	@Test(arguments: settleRows)
	func eachSettleReadsOnceAndGivesWhatTheCalendarShows(row: SettleRow) async throws {
		let attempt = try row.written.attempt
		let reads: [Written: SentRequest] = [
			.add: SentRequest(
				method: "GET", path: "/api/v1/athlete/0/events",
				query: "oldest=1997-12-15&newest=1998-12-15", body: nil),
			.edit: SentRequest(
				method: "GET", path: "/api/v1/athlete/0/events/101", query: nil, body: nil),
			.editWithSteps: SentRequest(
				method: "GET", path: "/api/v1/athlete/0/events/104", query: nil, body: nil),
			.loadOnlyWithSteps: SentRequest(
				method: "GET", path: "/api/v1/athlete/0/events/104", query: nil, body: nil),
			.delete: SentRequest(
				method: "GET", path: "/api/v1/athlete/0/events/112", query: nil, body: nil),
		]

		let (read, sent) = await CalendarWriterLine.answering(row.answer) {
			await CalendarWriter.settle(attempt, on: $0)
		}

		#expect(read == row.expected)
		#expect(sent == [try #require(reads[row.written])])
	}
}
