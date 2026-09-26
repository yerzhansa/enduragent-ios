import Foundation

package struct TryAgainWait: Sendable, Equatable {
	package let attempt: AttemptID
	package let remaining: Duration
}

final class RetryWaits {
	typealias Wake = @Sendable (TurnID, AttemptID) async -> Void

	private var alarms: [TurnID: Alarm] = [:]

	private struct Alarm {
		let attempt: AttemptID
		var sleeping: Task<Void, Never>?
	}

	var running: Set<TurnID> {
		Set(alarms.compactMap { $0.value.sleeping == nil ? nil : $0.key })
	}

	func track(_ turns: [TurnFacts], clock: any Clock, wake: @escaping Wake) {
		let now = clock.now
		let shown = Set(turns.map(\.turn))
		for turn in alarms.keys where !shown.contains(turn) {
			drop(turn)
		}
		for facts in turns {
			guard let wait = Self.wait(of: facts, now: now) else {
				drop(facts.turn)
				continue
			}
			guard alarms[facts.turn]?.attempt != wait.attempt else { continue }
			drop(facts.turn)
			alarms[facts.turn] = Alarm(
				attempt: wait.attempt,
				sleeping: sleep(wait, turn: facts.turn, clock: clock, wake: wake))
		}
	}

	func end(_ turn: TurnID, attempt: AttemptID) -> Bool {
		guard let alarm = alarms[turn], alarm.attempt == attempt, alarm.sleeping != nil else {
			return false
		}
		alarms[turn]?.sleeping = nil
		return true
	}

	package static func wait(of facts: TurnFacts, now: Date) -> TryAgainWait? {
		guard facts.openClaims.isEmpty, let latest = facts.latestSettlement,
			case .failed(let failure, _) = latest.settlement,
			TurnLifecycle.replayRefusal(after: latest.settlement) == nil,
			let hint = failure.tryAgainWait
		else { return nil }
		let started = min(latest.hlc.wallTime, now)
		let left = started.addingTimeInterval(hint.timeInterval).timeIntervalSince(now)
		return TryAgainWait(attempt: latest.attempt, remaining: .seconds(max(left, 0)))
	}

	private func sleep(_ wait: TryAgainWait, turn: TurnID, clock: any Clock, wake: @escaping Wake)
		-> Task<Void, Never>?
	{
		guard wait.remaining > .zero else { return nil }
		return Task {
			do {
				try await clock.sleep(for: wait.remaining)
			} catch is CancellationError {
				return
			} catch {
				fatalError("Clock.sleep failed: \(error)")
			}
			await wake(turn, wait.attempt)
		}
	}

	private func drop(_ turn: TurnID) {
		alarms.removeValue(forKey: turn)?.sleeping?.cancel()
	}
}
