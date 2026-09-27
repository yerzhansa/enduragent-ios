import Foundation

public struct ArchivedConversation: Sendable, Equatable, Identifiable {
	public let id: ArchivedConversationRef
	public let startedOn: CivilDate
	public let reason: ArchiveReason
	public let turns: [TurnView]
}

public struct ArchivedConversationRef: Hashable, Sendable {
	package let chat: ChatID
	package let segment: SegmentID

	public var rawValue: String {
		segment.boundary?.rawValue ?? chat.rawValue
	}
}

public enum ArchiveReason: Sendable, Equatable {
	case newConversation
	case closedAfterBreak
	case earlierChat

	public var title: CatalogKey {
		switch self {
		case .newConversation: Catalog.archiveReasonExplicit
		case .closedAfterBreak: Catalog.archiveReasonStale
		case .earlierChat: Catalog.archiveReasonEarlierChat
		}
	}

	init(closedBy reset: ResetKind) {
		switch reset {
		case .explicit: self = .newConversation
		case .daily, .idle: self = .closedAfterBreak
		}
	}
}

public enum HistoryUnavailable: Error, Sendable, Equatable {
	case storageUnavailable
}

extension Ledger {
	package func archivedConversations(process: ProcessID, today: CivilDate)
		async throws(LedgerFailure) -> [ArchivedConversation]
	{
		let synced = try await read(RecordQuery(scope: ConversationFold.syncedScope)).records
		let local = try await read(RecordQuery(scope: ConversationFold.localScope)).records
		var archived: [(started: HybridLogicalClock, conversation: ArchivedConversation)] = []
		for chat in Set(synced.compactMap(\.chatId)) {
			let conversation = ConversationFold.fold(
				chat: chat, synced: synced, local: local, device: deviceId)
			let closed: [(segment: Segment, reason: ArchiveReason)]
			if chat == .main {
				closed = zip(conversation.segments, conversation.segments.dropFirst()).compactMap {
					guard case .reset(let kind) = $1.openedBy else { return nil }
					return ($0, ArchiveReason(closedBy: kind))
				}
			} else {
				closed = [(conversation.earlierChat, .earlierChat)]
			}
			for (segment, reason) in closed {
				let views = segment.turnViews(
					live: nil, window: nil, queued: [], waiting: [], device: deviceId,
					process: process, today: today)
				guard let first = segment.turns.first?.fragments.first, let opened = views.first
				else { continue }
				archived.append(
					(
						first.hlc,
						ArchivedConversation(
							id: ArchivedConversationRef(chat: chat, segment: segment.id),
							startedOn: opened.sentOn, reason: reason, turns: views)
					))
			}
		}
		return archived.sorted { $0.started > $1.started }.map(\.conversation)
	}
}

extension Conversation {
	fileprivate var earlierChat: Segment {
		Segment(
			id: SegmentID(boundary: nil), openedBy: .chatStart,
			turns: segments.flatMap(\.turns))
	}
}
