import Foundation

public struct ReviewPresentation: Sendable, Equatable {
	public private(set) var failure: Int?
	public private(set) var round = 0
	private let chat: ChatID
	private let review: WorkoutReviewID
	private let revision: ReviewRevision
	private var shown: Set<Int> = []
	private var reported: ReviewRef?

	public init(of snapshot: ReviewSnapshot) {
		chat = snapshot.ref.chat
		review = snapshot.ref.review
		revision = snapshot.ref.revision
	}

	public func belongs(to snapshot: ReviewSnapshot) -> Bool {
		snapshot.ref.chat == chat && snapshot.ref.review == review
			&& snapshot.ref.revision == revision
	}

	public mutating func appeared(
		_ card: ReviewCard, of snapshot: ReviewSnapshot, in display: DisplayLocale
	) -> ReviewDecision? {
		guard !card.title(in: display).isEmpty || !card.lines(in: display).isEmpty else {
			return failed(card, of: snapshot)
		}
		guard failure == nil else { return nil }
		shown.insert(card.index)
		return delivered(snapshot)
	}

	public mutating func failed(_ card: ReviewCard, of snapshot: ReviewSnapshot)
		-> ReviewDecision?
	{
		guard failure == nil else { return nil }
		failure = card.index
		reported = nil
		return .presentationFailed(snapshot.ref)
	}

	public mutating func delivered(_ snapshot: ReviewSnapshot) -> ReviewDecision? {
		guard failure == nil, reported != snapshot.ref, case .available = snapshot.state,
			!snapshot.cards.isEmpty, snapshot.cards.allSatisfy({ shown.contains($0.index) })
		else { return nil }
		reported = snapshot.ref
		return .presented(snapshot.ref)
	}

	public mutating func showAgain(_ snapshot: ReviewSnapshot) -> ReviewDecision {
		failure = nil
		shown = []
		reported = nil
		round += 1
		return .showAgain(snapshot.ref)
	}

	public func status(of snapshot: ReviewSnapshot, in display: DisplayLocale) -> String? {
		if let failure {
			return display.say(
				Catalog.workoutsBarCardFailed,
				["position": .integer(failure + 1), "count": .integer(snapshot.cards.count)])
		}
		guard case .available(_, .none) = snapshot.state, snapshot.offered != nil else {
			return nil
		}
		return display.say(Catalog.workoutsBarUnseen)
	}
}
