import EnduragentCoachFixtures
import Foundation
import Testing

@testable import EnduragentCoach

@Suite(.serialized) struct Build0f943324StoreSeed {
	static let remember = "Remember that I ride with a group on Saturdays"
	static let memory = "Rides with a group on Saturdays."

	@Test func generate() async throws {
		let destination = try #require(
			ProcessInfo.processInfo.environment["UPGRADE_STORE_DESTINATION"])
		let root = URL(filePath: destination, directoryHint: .isDirectory).appending(path: "filled")
		let log = SwiftDataRecordLog(
			deviceId: DeviceID(rawValue: "build-0f943324"),
			synced: try ModelContainerHandle.withoutCloudKit(
				storeURL: root.appending(path: ModelContainerHandle.syncedStoreFileName)),
			local: try ModelContainerHandle.withoutCloudKit(
				storeURL: root.appending(path: ModelContainerHandle.localStoreFileName)))
		let turns = PlanTurns()
		let settled = turns.clock.now
		let coach = await turns.coach(over: log)
		try await coach.setLanguage(.fixed(.fr))
		turns.script([
			.toolCall(
				name: ToolName.memoryWrite.rawValue,
				arguments:
					#"{"type":"memory","section":"schedule","content":"\#(Self.memory)"}"#),
			.finish(reason: .toolCalls), .text("Noted."), .finish(reason: .stop),
		])
		_ = try await coach.sendAndSettle(Self.remember)
		_ = try await turns.reply(
			after: [[turns.prepareWorkouts()]], on: coach, asking: "Add a strength session")
		let review = try #require(try await coach.desk.snapshot(chat: .main))
		#expect(await coach.decide(.presented(review.ref), in: .main) == .presentationRecorded)
		let armed = try #require(try await coach.desk.snapshot(chat: .main))
		guard case .armed(.approveOrCancel, let approve) = armed.controls else {
			Issue.record("the first workout review offers \(armed.controls)")
			return
		}
		guard case .completed = await coach.decide(.approve(approve), in: .main) else {
			Issue.record("the first workout review did not complete")
			return
		}
		let saved = try await turns.prepareAndArm(PlanTurns.threshold, on: coach)
		#expect(await coach.decide(.save(saved), in: .main) == .saved)
		_ = try await turns.reply(
			after: [
				[
					.toolCall(
						name: "prepare_workout_changes",
						arguments: WorkoutReviewFixture.strengthSessions(1, today: "1998-06-14"))
				],
				[turns.save(PlanTurns.baseBuild)],
			], on: coach, asking: "Add one more and save the base build")

		#expect(turns.clock.now == settled)
		let shown = try #require(await coach.currentSnapshot(.main))
		#expect(shown.turns.count == 4)
		#expect(shown.review?.cards.count == 1)
		#expect(shown.plans.map(\.state) == [.saved, .waiting(.unarmed)])
		#expect(shown.plans.last?.summary.replaces == "Threshold Block")
		#expect(try await turns.prepared(in: log).last?.expiresAt == settled + 600)
		#expect(turns.calendarWrites().count == 1)
		#expect(await coach.languagePreference() == .fixed(.fr))
	}
}
