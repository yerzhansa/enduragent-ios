import EnduragentCoachFixtures
import Foundation
import Testing

@testable import EnduragentCoach

@Suite
struct GatedToolsTests {
	let intervals = FakeIntervalsClient(athleteName: "Ada", ftp: 250)
	let clock = FixedClock(now: "1998-06-13T08:00:00+02:00", timeZone: "Europe/Amsterdam")

	@Test func planSaveIsRefused() async throws {
		let transport = FakeModelTransport()
		let store = InMemoryRecordLog()
		transport.respond = ScriptedReply.sequence(
			[
				.toolCall(
					name: ToolName.planSave.rawValue, arguments: #"{"plan":{"name":"Base"}}"#),
				.finish(reason: .toolCalls), .text("Not saved."), .finish(reason: .stop),
			], otherwise: transport.respond)
		let coach = await makeCoach(
			transport: transport, intervals: intervals, store: store, clock: clock)

		_ = try await coach.sendAndSettle("Save my base plan")

		let result = try #require(transport.requests.last?.messages.last { $0.role == .tool })
		#expect(try JSONValue.parse(result.content) == ToolRuntime.unknownTool)
		#expect(
			try await store.fetch(RecordQuery(scope: .deviceLocal([.pendingProposal]))).records
				.isEmpty)
	}

	@Test func strengthDeleteAndUpdateAreGated() async throws {
		let tools = runtime()
		let strength = try await tools.execute(
			name: .intervalsCreateStrengthWorkout,
			arguments: try JSONValue.parse(
				#"{"date":"1998-06-14","name":"Core","description":"20 min floor"}"#
			),
			scope: turnScope()
		).outcome
		guard case .pending(let strengthProposal) = strength else {
			Issue.record("expected strength pending")
			return
		}
		#expect(strengthProposal.summary == "Create strength workout \"Core\" on 1998-06-14")

		let deleted = try await tools.execute(
			name: .intervalsDeleteWorkout,
			arguments: try JSONValue.parse(#"{"eventId":42}"#),
			scope: turnScope()
		).outcome
		guard case .pending = deleted else {
			Issue.record("expected delete pending")
			return
		}

		let updated = try await tools.execute(
			name: .intervalsUpdateWorkout,
			arguments: try JSONValue.parse(#"{"eventId":42,"name":"Endurance 2"}"#),
			scope: turnScope()
		).outcome
		guard case .pending = updated else {
			Issue.record("expected update pending")
			return
		}
		#expect(
			!intervals.calls.contains { call in
				switch call {
				case .createEvent, .updateEvent, .deleteEvent:
					return true
				default:
					return false
				}
			}
		)
	}

	@Test func toolErrorsReachTheModelWithoutSwiftTypeNames() async throws {
		let invalid = try await runtime().execute(
			name: .intervalsCreateWorkout,
			arguments: try JSONValue.parse(
				#"{"date":"1998-06-14","workout":{"name":"Endurance","steps":[{"type":"ramp","duration":{"value":10,"unit":"minutes"}}]}}"#
			),
			scope: turnScope()
		).outcome
		intervals.fail(
			.wellness, with: IntervalsError(code: "http", details: "status 503", status: 503))
		let unavailable = try await runtime().execute(
			name: .intervalsFetchWellness,
			arguments: try JSONValue.parse(#"{"oldest":"1998-06-07","newest":"1998-06-13"}"#),
			scope: turnScope()
		).outcome
		for outcome in [invalid, unavailable] {
			guard case .result(let json) = outcome else {
				Issue.record("expected a tool result, got \(outcome)")
				continue
			}
			let text = json.canonicalDigestInput()
			for typeName in ["IntervalsError", "InvalidWorkout", "EnduragentCoach", "Optional("] {
				#expect(!text.contains(typeName), "\(typeName) in \(text)")
			}
		}
		#expect(
			unwrapData(try #require(invalid.resultJSON)).objectFields["details"]?.stringValue
				== "steps[0]: ramp step requires a power target")
		#expect(
			unwrapData(try #require(unavailable.resultJSON)).objectFields["details"]?.stringValue
				== "status 503")
	}

	@Test func pastDateIsRefusedAtTheBoundary() async throws {
		let outcome = try await runtime().execute(
			name: .intervalsCreateWorkout,
			arguments: try JSONValue.parse(
				#"{"date":"1998-06-12","workout":{"name":"Endurance","steps":[{"type":"steady","duration":{"value":10,"unit":"minutes"},"power":{"kind":"percent_ftp","value":60}}]}}"#
			),
			scope: turnScope()
		).outcome
		guard case .result(let json) = outcome else {
			Issue.record("expected error result")
			return
		}
		#expect(unwrapData(json).objectFields["error"]?.stringValue == "past_date_refused")
		let details = try #require(unwrapData(json).objectFields["details"]?.stringValue)
		#expect(details.contains("1998-06-12"))
		#expect(details.contains("1998-06-13"))
	}

	private func unwrapData(_ json: JSONValue) -> JSONValue {
		json.objectFields["data"] ?? json
	}

	private func runtime() -> OfferedTools {
		let store = InMemoryRecordLog()
		return makeOfferedTools(
			intervals: intervals,
			ledger: Ledger(log: store, clock: clock, diagnostics: DiagnosticsLog(clock: clock)),
			clock: clock
		)
	}

	private func turnScope() -> TurnScope {
		TurnScope(stamp: testStamp(), policy: .npm, ladder: .npm, uptime: .zero)
	}
}

extension ToolOutcome {
	fileprivate var resultJSON: JSONValue? {
		guard case .result(let json) = self else { return nil }
		return json
	}
}
