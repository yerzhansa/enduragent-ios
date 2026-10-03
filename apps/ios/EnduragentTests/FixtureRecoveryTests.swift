import EnduragentCoach
import EnduragentCoachFixtures
import Foundation
import Testing
import UIKit

@testable import Enduragent

extension FixtureLaunchTests {
	@Test(arguments: [false, true])
	func retryAfterRelaunchAnswersAHangingDirective(started: Bool) async throws {
		var launch = launch
		launch.coalescing = CoalescingPolicy(window: started ? .milliseconds(100) : .seconds(60))
		let accepted: TurnView
		do {
			let first = await model(try fixtureServices(launch, defaults: defaults))
			await first.agreeAndStartChatting()
			first.draft.text = "fixture:hang"
			await first.send()
			accepted = try await firstTurn(first)
			if started {
				_ = try await turn(accepted.id, in: first, where: isProcessing)
			}
			try await terminateWithoutWriting(first)
		}
		let reopened = await model(try await relaunch(.keep).0)
		await reopened.appear()
		await reopened.lifecycle.forward(.becameActive)
		let recovered = try await turn(accepted.id, in: reopened) { state in
			if started {
				guard case .interrupted(let interrupted) = state else { return false }
				return interrupted.notice.action == .tryAgain(accepted.id)
			}
			return state == .accepted(.awaitingRestart)
		}
		#expect(recovered.athleteText == "fixture:hang")
		await reopened.perform(.tryAgain(accepted.id))
		let answered = try await turn(accepted.id, in: reopened, where: isCompleted)
		await reopened.stop()
		#expect(replyText(answered.state) == FirstWeekFixture.weekSummary)
	}

	@Test func becameActiveRunsRecoveryOncePerProcess() async throws {
		let dead: TurnView
		do {
			let killed = await model(try services())
			await killed.agreeAndStartChatting()
			killed.draft.text = "fixture:hang"
			await killed.send()
			dead = try await turn(in: killed, where: isProcessing)
			try await terminateWithoutWriting(killed)
		}
		let relaunched = await model(try await relaunch(.keep).0)
		await relaunched.appear()
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
	}

	@Test func unreadableRecoveryHoldsADeadClaimWithoutTryAgainUntilItCanRead() async throws {
		let suite = "enduragent.fixture.recovery.arguments.test"
		let arguments = try #require(UserDefaults(suiteName: suite))
		defer { arguments.removePersistentDomain(forName: suite) }
		arguments.set(FixtureLaunch.firstWeekName, forKey: FixtureLaunch.nameArgumentKey)
		arguments.set("never", forKey: FixtureLaunch.recoveryArgumentKey)
		#expect(throws: FixtureLaunchError.self) { try FixtureLaunch.fromArguments(arguments) }
		arguments.set("unreadable", forKey: FixtureLaunch.recoveryArgumentKey)
		let parsed = try #require(try FixtureLaunch.fromArguments(arguments))
		let dead: TurnView
		do {
			let killed = await model(try services())
			await killed.agreeAndStartChatting()
			killed.draft.text = "fixture:hang"
			await killed.send()
			dead = try await turn(in: killed, where: isProcessing)
			try await terminateWithoutWriting(killed)
		}
		do {
			let (unreadableServices, _) = try await relaunch(.keep, recovery: parsed.recovery)
			let unreadable = await model(unreadableServices)
			await unreadable.appear()
			await unreadable.lifecycle.forward(.becameActive)
			let held = try await turn(dead.id, in: unreadable, where: isUnrecovered)
			guard case .unrecovered(let unrecovered) = held.state else {
				Issue.record("expected unrecovered, got \(held.state)")
				return
			}
			#expect(unrecovered.notice.key == Catalog.chatHistoryFailure)
			#expect(unrecovered.notice.action == nil)
			let transport = try #require(unreadableServices.fixtureTransport)
			await unreadable.perform(.tryAgain(dead.id))
			try await Task.sleep(for: .milliseconds(200))
			#expect(transport.requestCount == 0)
			#expect(unreadable.chat?.turns.first { $0.id == dead.id }?.state == held.state)
		}
		let readable = await model(try await relaunch(.keep).0)
		await readable.appear()
		await readable.lifecycle.forward(.becameActive)
		let recovered = try await turn(dead.id, in: readable, where: isInterrupted)
		#expect(cause(recovered.state) == .processEnded)
		guard case .interrupted(let interrupted) = recovered.state else {
			Issue.record("expected interrupted, got \(recovered.state)")
			return
		}
		#expect(interrupted.notice.action == .tryAgain(dead.id))
	}

	@Test(.timeLimit(.minutes(1)))
	func willTerminateSettlesTheRunningTurnBeforeItReturns() async throws {
		let streaming: TurnView
		do {
			let services = try services()
			let records = try #require(services.fixtureRecordFaults)
			let model = await model(services)
			await model.agreeAndStartChatting()
			model.draft.text = "fixture:slow"
			await model.send()
			streaming = try await turn(in: model, within: .hangGuard) { state in
				guard case .processing = state else { return false }
				return model.chat?.liveReply?.text.isEmpty == false
			}
			NotificationCenter.default.post(
				name: UIApplication.willTerminateNotification, object: nil)
			records.failSyncedAppends = true
		}
		let reopened = try #require(
			await firstSnapshot(try await relaunch(.keep).0, chat: .main))
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
		let dead: TurnView
		do {
			let services = try services()
			let records = services.coach.recordSyncProbe()
			let killed = await model(services)
			await killed.agreeAndStartChatting()
			killed.draft.text = "fixture:memory-then-hang"
			await killed.send()
			dead = try await turn(in: killed, where: isProcessing)
			let deadline = ContinuousClock.now + TestWaitLimit.hangGuard.duration
			while try await !records.snapshot().counts.contains(where: {
				$0.kind == "memorySection" && $0.count > 0
			}),
				ContinuousClock.now < deadline
			{
				try await Task.sleep(for: .milliseconds(20))
			}
			try await terminateWithoutWriting(killed)
		}
		let reopened = try #require(
			await firstSnapshot(try await relaunch(.keep).0, chat: .main))
		let state = try #require(reopened.turns.first { $0.id == dead.id }?.state)
		guard case .interrupted(let interrupted) = state else {
			Issue.record("expected interrupted, got \(state)")
			return
		}
		#expect(interrupted.cause == .processEnded)
		#expect(interrupted.saved.memorySections == 1)
		#expect(interrupted.notice.key == Catalog.chatTurnInterruptedSomeSaved)
		#expect(interrupted.notice.action == nil)
	}

	@Test func recoveryOfOneDeadClaimOverTwoHundredTurns() async throws {
		var quick = launch
		quick.coalescing = CoalescingPolicy(window: .milliseconds(1))
		let dead: TurnView
		do {
			let seeded = await model(try fixtureServices(quick, defaults: defaults))
			await seeded.agreeAndStartChatting()
			for index in 1...200 {
				seeded.draft.text = "Seed \(index)"
				await seeded.send()
				try await answered("Seed \(index)", in: seeded)
			}
			seeded.draft.text = "fixture:hang"
			await seeded.send()
			dead = try await turn(in: seeded, where: isProcessing)
			try await terminateWithoutWriting(seeded)
		}
		let snapshot: ChatSnapshot
		do {
			let (recovering, _) = try await relaunch(.keep)
			await recovering.coach.lifecycle(.becameActive)
			snapshot = try #require(await firstSnapshot(recovering, chat: .main))
			#expect(snapshot.turns.count == 201)
			let state = try #require(snapshot.turns.first { $0.id == dead.id }?.state)
			#expect(cause(state) == .processEnded)
			#expect(snapshot.turns.filter { isCompleted($0.state) }.count == 200)
			#expect(
				snapshot.turns.filter { cause($0.state) == .processEnded }.map(\.id) == [dead.id])
			let transport = try #require(recovering.fixtureTransport)
			#expect(transport.requestCount == 0)
		}
		let (clean, _) = try await relaunch(.keep)
		await clean.coach.lifecycle(.becameActive)
		let reopened = try #require(await firstSnapshot(clean, chat: .main))
		#expect(reopened.turns == snapshot.turns)
	}

	private func terminateWithoutWriting(_ model: ShellModel) async throws {
		let records = try #require(model.services.fixtureRecordFaults)
		records.failSyncedAppends = true
		try records.failAppends(ofKind: "pendingSettlement")
		await model.lifecycle.forward(.willTerminate)
	}

	private func answered(_ text: String, in model: ShellModel) async throws {
		let deadline = ContinuousClock.now + TestWaitLimit.hangGuard.duration
		while ContinuousClock.now < deadline {
			if let last = model.chat?.turns.last, last.athleteText == text, isCompleted(last.state)
			{
				return
			}
			try await Task.sleep(for: .milliseconds(5))
		}
		Issue.record("\(text) was not answered")
	}

	private func turn(
		_ id: TurnID? = nil, in model: ShellModel, within limit: TestWaitLimit = .hangGuard,
		where matches: (TurnState) -> Bool
	) async throws -> TurnView {
		let deadline = ContinuousClock.now + limit.duration
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

private func isUnrecovered(_ state: TurnState) -> Bool {
	if case .unrecovered = state { true } else { false }
}

private func isCompleted(_ state: TurnState) -> Bool {
	if case .completed = state { true } else { false }
}

private func isInterrupted(_ state: TurnState) -> Bool {
	if case .interrupted = state { true } else { false }
}

private func cause(_ state: TurnState) -> InterruptionCause? {
	guard case .interrupted(let interrupted) = state else { return nil }
	return interrupted.cause
}
