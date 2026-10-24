import Foundation

public struct PlanCardRef: Hashable, Sendable {
	public let chat: ChatID
	public let confirmation: PlanConfirmationID
	public let digest: PlanDigest
	public let delivery: UUID
}

public struct PlanSaveToken: Hashable, Sendable {
	public let ref: PlanCardRef
	let secret: UUID

	fileprivate init(ref: PlanCardRef, secret: UUID) {
		self.ref = ref
		self.secret = secret
	}
}

public enum PlanControls: Hashable, Sendable {
	case unarmed
	case armed(PlanSaveToken)
}

public enum PlanCardState: Hashable, Sendable {
	case waiting(PlanControls)
	case saving
	case saved
	case canceled
	case expired
	case storageUnavailable
}

public enum PlanCardPlacement: Hashable, Sendable {
	case afterTurn(TurnID)
	case preparedEarlier
}

public struct PlanPhaseRow: Hashable, Sendable {
	public let focus: String?
	public let weeks: Int?
	public let hours: Double?
}

public struct PlanSummary: Hashable, Sendable {
	public let name: String
	public let goal: String?
	public let weeks: Int?
	public let phases: [PlanPhaseRow]
	public let replaces: String?
}

public struct PlanCard: Hashable, Sendable, Identifiable {
	public let ref: PlanCardRef
	public let placement: PlanCardPlacement
	public let summary: PlanSummary
	public let state: PlanCardState

	public var id: PlanConfirmationID { ref.confirmation }
}

public enum PlanDecision: Hashable, Sendable {
	case presented(PlanCardRef)
	case save(PlanSaveToken)
	case cancel(PlanSaveToken)
}

public enum PlanDecisionOutcome: Hashable, Sendable {
	case presented
	case saved
	case canceled
	case notSaved(PlanNotSaved)
	case storageUnavailable
}

public enum PlanNotSaved: Error, Hashable, Sendable {
	case expired
	case replaced
	case alreadyDecided
	case athleteChanged
	case notPresented
}

struct PlanDelivery: Sendable, Equatable {
	enum Presence: Sendable, Equatable {
		case shown
		case armed(UUID)
	}

	let ref: PlanCardRef
	let head: ULID
	var presence: Presence

	static func fresh(for confirmation: FoldedConfirmation, chat: ChatID) -> PlanDelivery {
		PlanDelivery(
			ref: PlanCardRef(
				chat: chat, confirmation: confirmation.id,
				digest: confirmation.prepared.document.digest, delivery: UUID()),
			head: confirmation.newest.ulid, presence: .shown)
	}

	mutating func acknowledge() {
		guard case .shown = presence else { return }
		presence = .armed(UUID())
	}

	var controls: PlanControls {
		switch presence {
		case .shown: .unarmed
		case .armed(let secret): .armed(PlanSaveToken(ref: ref, secret: secret))
		}
	}

	func admits(_ token: PlanSaveToken) -> Bool {
		presence == .armed(token.secret) && ref == token.ref
	}
}

enum PlanCardProjection {
	static func cards(
		chain: PlanChain, saved: SavedPlans, conversation: Conversation, delivery: PlanDelivery?,
		stalled: Set<PlanConfirmationID>, at now: Date
	) -> [PlanCard] {
		guard let delivery else { return [] }
		let segment = conversation.current
		let carried = segment.boundary.flatMap { boundary in
			chain.confirmations.last { !boundary.includes($0.created.ulid, at: $0.created.hlc) }
				.flatMap { undecided($0, at: boundary) ? $0 : nil }
		}
		let current = chain.confirmations.filter { confirmation in
			segment.turns.contains { $0.turn == confirmation.origin.turn }
		}
		let shown =
			[carried].compactMap(\.self).map { ($0, PlanCardPlacement.preparedEarlier) }
			+ current.map { ($0, PlanCardPlacement.afterTurn($0.origin.turn)) }
		return shown.map { confirmation, placement in
			let own = delivery.ref.confirmation == confirmation.id
			let phase = chain.phase(of: confirmation, at: now)
			return PlanCard(
				ref: own
					? delivery.ref
					: PlanCardRef(
						chat: conversation.chat, confirmation: confirmation.id,
						digest: confirmation.prepared.document.digest,
						delivery: delivery.ref.delivery),
				placement: placement,
				summary: confirmation.prepared.document.summary(
					replacing: replaced(by: confirmation, in: phase, of: chain, saved: saved)),
				state: state(
					phase, controls: own ? delivery.controls : nil,
					stalled: stalled.contains(confirmation.id)))
		}
	}

	private static func replaced(
		by confirmation: FoldedConfirmation, in phase: ConfirmationPhase, of chain: PlanChain,
		saved: SavedPlans
	) -> PlanDocument? {
		switch phase {
		case .live: saved.newest
		case .saving, .saved, .canceled, .expired, .replaced:
			saved.newest(decidedBefore: chain.end(of: confirmation))
		}
	}

	private static func undecided(_ confirmation: FoldedConfirmation, at boundary: SegmentBoundary)
		-> Bool
	{
		let decidedBefore = confirmation.decided.map { !boundary.includes($0.ulid, at: $0.hlc) }
		return decidedBefore != true
			&& confirmation.expiry > boundary.clock.wallTime
	}

	private static func state(_ phase: ConfirmationPhase, controls: PlanControls?, stalled: Bool)
		-> PlanCardState
	{
		switch phase {
		case .live(let live):
			if case .unreadable = live.head { return .storageUnavailable }
			return .waiting(controls ?? .unarmed)
		case .saving: return stalled ? .storageUnavailable : .saving
		case .saved: return .saved
		case .canceled: return .canceled
		case .expired, .replaced: return .expired
		}
	}
}
