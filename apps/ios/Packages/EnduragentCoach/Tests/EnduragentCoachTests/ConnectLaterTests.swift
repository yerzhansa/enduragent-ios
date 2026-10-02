import EnduragentCoachFixtures
import Foundation
import Testing

@testable import EnduragentCoach

@Suite struct ConnectLaterTests {
	@Test func missingTrainingToolResultsThenSavedKeyOwnerReachTheModel() async throws {
		let transport = FakeModelTransport()
		let owner = FakeIntervalsClient(athleteName: "Key Owner", ftp: 250, athleteId: "i4242")
		owner.events = [
			CalendarEvent(
				id: EventID(rawValue: 17), startDateLocal: "1998-06-13T08:00:00",
				name: "Owner's ride", category: "WORKOUT", externalId: nil,
				uid: nil, tags: [], coachCreated: false)
		]
		let wrong = FakeIntervalsClient(athleteName: "Wrong Athlete", ftp: 200, athleteId: "i9090")
		let secrets = ICloudKeychainStore(backing: FixtureSecretStoreBacking())
		try secrets.storeCreditsAccount(CreditsAccount(appAccountToken: UUID(), key: testKey))
		let coach = await consentingCoach(
			Coach(
				sport: .cycling,
				ports: CoachPorts(
					records: .inMemory(deviceId: DeviceID(rawValue: "connect-later")),
					secrets: secrets,
					models: .scripted(transport),
					training: .fake { credential, selection in
						credential == .apiKey("synthetic-owner-key") && selection == .keyOwner
							? owner : wrong
					},
					credits: .fake(FakeCreditsClient()), host: ImmediateExecutionHost(),
					clock: FixedClock(
						now: "1998-06-13T08:00:00+02:00", timeZone: "Europe/Amsterdam")),
				builtInModel: testModel, deviceLanguage: .en, coalescing: quickWindow))
		let reads: [ScriptedEvent] = [
			.toolCall(name: ToolName.intervalsFetchAthlete.rawValue, arguments: "{}"),
			.toolCall(name: ToolName.intervalsListEvents.rawValue, arguments: #"{"days":7}"#),
			.finish(reason: .toolCalls), .text("Training checked."), .finish(reason: .stop),
		]
		transport.respond = ScriptedReply.sequence(reads)
		#expect(replyText(try await coach.sendAndSettle("Read my profile and calendar")) != nil)
		let missing = try results(in: #require(transport.requests.last))
		for name in [ToolName.intervalsFetchAthlete, .intervalsListEvents] {
			#expect(missing[name]?.objectFields["error"] == .string("not_connected"))
			#expect(
				missing[name]?.objectFields["details"]?.stringValue?.contains(
					"training data is unavailable") == true)
		}
		#expect(owner.profileReadCount == 0)
		#expect(owner.calls.isEmpty)
		#expect(wrong.profileReadCount == 0)
		let before = try #require(await coach.currentSnapshot(.main)?.turns.first)
		let saved = await coach.changeTraining(
			.replace(apiKey: "synthetic-owner-key", athlete: .keyOwner))
		guard case .replaced = saved else {
			Issue.record("the key owner connection was not saved")
			return
		}
		transport.respond = ScriptedReply.sequence(reads)
		_ = try await coach.sendAndSettle("Read my connected profile and calendar")
		let connected = try results(in: #require(transport.requests.last))
		#expect(connected[.intervalsFetchAthlete]?.objectFields["id"] == .string("i4242"))
		#expect(connected[.intervalsFetchAthlete]?.objectFields["name"] == .string("Key Owner"))
		let calendar = try #require(connected[.intervalsListEvents]?.arrayValue)
		#expect(calendar.count == 1)
		#expect(calendar.first?.objectFields["name"] == .string("Owner's ride"))
		#expect(owner.calls.contains(.events(oldest: "1998-06-07", newest: "1998-06-13")))
		#expect(wrong.profileReadCount == 0)
		#expect(wrong.calls.isEmpty)
		#expect(await coach.currentSnapshot(.main)?.turns.first == before)
	}

	private func results(in request: CompletionRequest) throws -> [ToolName: JSONValue] {
		let calls = request.messages.flatMap(\.toolCalls)
		var results: [ToolName: JSONValue] = [:]
		for message in request.messages where message.role == .tool {
			let call = try #require(calls.first { $0.id == message.toolCallId })
			let name = try #require(ToolName(rawValue: call.name))
			let envelope = try JSONValue.parse(message.content)
			results[name] = try #require(envelope.objectFields["data"])
		}
		return results
	}
}
