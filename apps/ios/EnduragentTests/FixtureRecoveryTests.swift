import EnduragentCoach
import Foundation
import Testing
import UIKit

@testable import Enduragent

extension FixtureLaunchTests {
	@Test func becameActiveRunsRecoveryOncePerProcess() async throws {
		let killed = model(try services())
		killed.startChatting()
		killed.draft.text = "fixture:hang"
		await killed.send()
		let dead = try await turn(in: killed, where: isProcessing)
		let relaunched = model(try relaunch(.keep).0)
		await relaunched.lifecycle.forward(.becameActive)
		let recovered = try await turn(dead.id, in: relaunched, where: isInterrupted)
		#expect(cause(recovered.state) == .processEnded)
		relaunched.draft.text = "fixture:hang"
		await relaunched.send()
		let running = try await turn(in: relaunched, where: isProcessing)
		await relaunched.lifecycle.forward(.becameActive)
		try await Task.sleep(for: .milliseconds(200))
		let stillRunning = try #require(relaunched.chat?.turns.first { $0.id == running.id })
		#expect(isProcessing(stillRunning.state))
		#expect(relaunched.chat?.turns.first { $0.id == dead.id }?.state == recovered.state)
		await relaunched.stop()
		await killed.stop()
	}

	@Test func willTerminateSettlesTheRunningTurnBeforeItReturns() async throws {
		let services = try services()
		let records = try #require(services.fixtureRecordLog)
		let model = model(services)
		model.startChatting()
		model.draft.text = "fixture:slow"
		await model.send()
		let streaming = try await turn(in: model, within: .seconds(10)) { state in
			guard case .processing(let processing) = state else { return false }
			return !processing.liveText.isEmpty
		}
		NotificationCenter.default.post(name: UIApplication.willTerminateNotification, object: nil)
		for kind in SyncedKind.allCases {
			records.failAppends(ofKind: kind)
		}
		let reopened = try #require(
			await firstSnapshot(try relaunch(.keep).0, chat: model.chatId))
		let state = try #require(reopened.turns.first { $0.id == streaming.id }?.state)
		guard case .interrupted(let interrupted) = state else {
			Issue.record("expected interrupted, got \(state)")
			return
		}
		#expect(interrupted.cause == .appTerminating)
		#expect(!interrupted.partial.isEmpty)
		#expect(interrupted.notice.key == Catalog.chatTurnInterruptedNothingChanged)
		#expect(interrupted.notice.action == .tryAgain(streaming.id))
	}

	@Test func memoryThenHangLeavesSavedWorkForRecovery() async throws {
		let services = try services()
		let records = try #require(services.fixtureRecordLog)
		let killed = model(services)
		killed.startChatting()
		killed.draft.text = "fixture:memory-then-hang"
		await killed.send()
		let dead = try await turn(in: killed, where: isProcessing)
		let deadline = ContinuousClock.now + .seconds(5)
		while try await records.fetch(RecordQuery(scope: .synced([.memorySection]))).records
			.isEmpty,
			ContinuousClock.now < deadline
		{
			try await Task.sleep(for: .milliseconds(20))
		}
		let reopened = try #require(
			await firstSnapshot(try relaunch(.keep).0, chat: killed.chatId))
		let state = try #require(reopened.turns.first { $0.id == dead.id }?.state)
		guard case .interrupted(let interrupted) = state else {
			Issue.record("expected interrupted, got \(state)")
			return
		}
		#expect(interrupted.cause == .processEnded)
		#expect(interrupted.saved.memorySections == 1)
		#expect(interrupted.notice.key == Catalog.chatTurnInterruptedSomeSaved)
		#expect(interrupted.notice.action == nil)
		#expect(!state.retryable)
		await killed.stop()
	}

	private func turn(
		_ id: TurnID? = nil, in model: ShellModel, within limit: Duration = .seconds(5),
		where matches: (TurnState) -> Bool
	) async throws -> TurnView {
		let deadline = ContinuousClock.now + limit
		while ContinuousClock.now < deadline {
			let candidate =
				id.map { id in model.chat?.turns.first { $0.id == id } }
				?? model.chat?.turns.last
			if let candidate, matches(candidate.state) {
				return candidate
			}
			try await Task.sleep(for: .milliseconds(20))
		}
		Issue.record("no turn reached the expected state in \(limit)")
		return try #require(id.flatMap { id in model.chat?.turns.first { $0.id == id } })
	}
}

private func isProcessing(_ state: TurnState) -> Bool {
	if case .processing = state { true } else { false }
}

private func isInterrupted(_ state: TurnState) -> Bool {
	if case .interrupted = state { true } else { false }
}

private func cause(_ state: TurnState) -> InterruptionCause? {
	guard case .interrupted(let interrupted) = state else { return nil }
	return interrupted.cause
}
