import Foundation

struct TurnProjection {
	private var cached: [TurnID: ProjectedTurn] = [:]
	private var published: [TurnView] = []

	mutating func turns(
		in segment: Segment,
		live: LiveAttempt?, window: OpenWindow? = nil, queued: [TurnID] = [],
		waiting: Set<TurnID> = [], finishedAway: Set<TurnID> = [],
		device: DeviceID, process: ProcessID, unsavedTurns: Set<TurnID> = [], today: CivilDate
	) -> [TurnView] {
		var next: [TurnID: ProjectedTurn] = [:]
		let turns = segment.turns.compactMap { facts -> TurnView? in
			guard !segment.hidesWholly(facts) else { return nil }
			let input = Input(
				facts: facts,
				live: live?.turn == facts.turn ? live : nil,
				overlay: TurnOverlay(
					of: facts.turn, window: window, queued: queued, waiting: waiting),
				hidesQuestion: segment.hidesQuestion(of: facts),
				completedInBackground: finishedAway.contains(facts.turn),
				unsaved: unsavedTurns.contains(facts.turn),
				device: device, process: process,
				sentOn: facts.fragments.first?.civilDate ?? today)
			let projected: ProjectedTurn
			if let previous = cached[facts.turn], previous.input == input {
				projected = previous
			} else {
				projected = ProjectedTurn(input: input, view: input.view)
			}
			next[facts.turn] = projected
			return projected.view
		}
		cached = next
		if turns != published { published = turns }
		return published
	}

	private struct ProjectedTurn {
		let input: Input
		let view: TurnView
	}

	private struct Input: Equatable {
		let facts: TurnFacts
		let live: LiveAttempt?
		let overlay: TurnOverlay
		let hidesQuestion: Bool
		let completedInBackground: Bool
		let unsaved: Bool
		let device: DeviceID
		let process: ProcessID
		let sentOn: CivilDate

		var view: TurnView {
			TurnView(
				id: facts.turn,
				athleteText: hidesQuestion ? nil : facts.requestText,
				sentOn: sentOn,
				state: TurnLifecycle.state(
					of: facts, live: live, overlay: overlay, device: device, process: process),
				completedInBackground: completedInBackground,
				saveFailure: unsaved ? Catalog.chatNoticeReplyUnsaved : nil)
		}
	}
}
