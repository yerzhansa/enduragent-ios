import EnduragentCoachFixtures
import Foundation
import Testing

@testable import EnduragentCoach

extension IntervalsRESTClientTests {
	@Suite struct ChatCreateBodyTests {
		let today: CivilDate = "1998-06-13"

		@Test func theOldPathSendsTodaysRideBodyAsTheBulkArraysOneElement() async throws {
			let workout = try IntervalsSerializer.parseWorkout(
				try JSONValue.parse(
					#"{"name":"Z2 Endurance 90min","steps":[{"type":"steady","duration":{"value":70,"unit":"minutes"},"power":{"kind":"percent_ftp","low":56,"high":75}}]}"#
				)
			)
			let identity = try writeID()
			let sent = try await sentBody(
				.createWorkout(date: "1998-06-14", workout: workout), identity: identity)
			#expect(
				sent
					== .array([
						todaysBody(
							date: "1998-06-14", type: "Ride", name: "Z2 Endurance 90min",
							description: try IntervalsSerializer.serialize(workout).description,
							identity: identity)
					]), "\(canonicalJSON(sent))")
		}

		@Test func theOldPathSendsTodaysStrengthBodyAsTheBulkArraysOneElement() async throws {
			let identity = try writeID()
			let sent = try await sentBody(
				.createStrengthWorkout(
					date: "1998-06-14", name: "Core", description: "Planks and bridges."),
				identity: identity)
			#expect(
				sent
					== .array([
						todaysBody(
							date: "1998-06-14", type: "WeightTraining", name: "Core",
							description: "Planks and bridges.", identity: identity)
					]), "\(canonicalJSON(sent))")
		}

		@Test func parseCreateWorkoutAllowsTodayAndBuildsRide() throws {
			let arguments = try JSONValue.parse(
				#"{"date":"1998-06-13","workout":{"name":"Endurance","steps":[{"type":"warmup","duration":{"value":10,"unit":"minutes"},"power":{"kind":"percent_ftp","low":55,"high":65}}]}}"#
			)
			let parsed = try CyclingTools.parseCreateWorkoutInput(arguments, today: today)
			#expect(parsed.date == today)
			#expect(parsed.workout.name == "Endurance")
			#expect(parsed.description.hasPrefix("Warmup\n- 10m 55-65%"))
		}

		private func todaysBody(
			date: String, type: String, name: String, description: String,
			identity: CalendarWriteID
		) -> JSONValue {
			.object([
				"start_date_local": .string("\(date)T00:00:00"),
				"category": .string("WORKOUT"),
				"type": .string(type),
				"name": .string(name),
				"description": .string(description),
				"external_id": .string("cycling-coach:\(identity.uid)"),
				"tags": .array([.string("cycling-coach")]),
				"uid": .string(identity.uid),
			])
		}

		private func writeID() throws -> CalendarWriteID {
			CalendarWriteID(
				rawValue: try #require(UUID(uuidString: "6F1E2D3C-4B5A-4978-8796-A5B4C3D2E1F0")))
		}

		private func sentBody(_ input: GatedToolInput, identity: CalendarWriteID) async throws
			-> JSONValue
		{
			let client = try IntervalsRESTClientTests().makeClient()
			let operation = try await CalendarWriteOperation.prepare(
				oldPathProposal(input, writeID: identity), client: client, today: today)
			_ = try await operation.dispatch(on: client)
			let data = try #require(IntervalsURLProtocolStub.lastBody)
			return try JSONValue.parse(String(decoding: data, as: UTF8.self))
		}
	}
}

func oldPathProposal(_ input: GatedToolInput, writeID: CalendarWriteID?) throws -> LiveProposal {
	LiveProposal(
		cause: .legacy,
		body: ProposalBody(
			writeID: writeID, chatId: .main, nonce: Nonce(), tool: .intervalsCreateWorkout,
			toolInput: input, summary: "", description: "", expiresAt: .distantFuture),
		account: .unconnected,
		ulid: try #require(ULID(rawValue: "01J0000000000000000000000A")))
}
