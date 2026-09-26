import Foundation

extension SendOutcome {
	package var acceptedTurn: TurnID? {
		if case .accepted(let turn) = self {
			return turn
		}
		return nil
	}
}

extension TurnState {
	package var isSettled: Bool {
		switch self {
		case .completed, .failed, .interrupted: true
		case .accepted, .processing: false
		}
	}
}

extension Coach {
	package func settledState(
		of turn: TurnID, in chat: ChatID, within limit: Duration = .seconds(30)
	) async -> TurnState? {
		let stream = await observe(chat)
		return await withTaskGroup(of: TurnState?.self) { group in
			group.addTask {
				for await snapshot in stream {
					guard let view = snapshot.turns.first(where: { $0.id == turn }),
						view.state.isSettled
					else {
						continue
					}
					return view.state
				}
				return nil
			}
			group.addTask {
				do {
					try await Task.sleep(for: limit)
				} catch is CancellationError {
					return nil
				} catch {
					fatalError("Task.sleep failed: \(error)")
				}
				return nil
			}
			let first = await group.next() ?? nil
			group.cancelAll()
			return first
		}
	}

	package func currentSnapshot(_ chat: ChatID) async -> ChatSnapshot? {
		var iterator = await observe(chat).makeAsyncIterator()
		return await iterator.next()
	}

	package func transcript(_ chat: ChatID) async -> [String] {
		guard let snapshot = await currentSnapshot(chat) else { return [] }
		return snapshot.turns.flatMap { turn -> [String] in
			let question = [turn.athleteText].compactMap { $0 }
			switch turn.state {
			case .completed(let completed):
				switch completed.reply {
				case .model(let text):
					return question + [text]
				}
			case .accepted, .processing, .failed, .interrupted:
				return question
			}
		}
	}
}
