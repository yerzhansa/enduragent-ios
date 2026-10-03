import Foundation

public struct ArchivedConversationSummary: Sendable, Equatable, Identifiable {
	public let id: ArchivedConversationRef
	public let startedOn: CivilDate
	public let reason: ArchiveReason
	public let firstQuestion: String?
	public let attribution: AthleteAttribution
}

public struct ArchivedConversation: Sendable, Equatable, Identifiable {
	public let id: ArchivedConversationRef
	public let startedOn: CivilDate
	public let reason: ArchiveReason
	public let turns: [TurnView]
	public let notes: [TranscriptNote]
	public let attribution: AthleteAttribution
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
	case earlierChat

	public var title: CatalogKey {
		switch self {
		case .newConversation: Catalog.archiveReasonExplicit
		case .earlierChat: Catalog.archiveReasonEarlierChat
		}
	}

	init?(closedBy opening: SegmentOpening) {
		switch opening {
		case .chatStart: return nil
		case .reset: self = .newConversation
		case .legacyBoundary: self = .earlierChat
		}
	}
}

public enum HistoryUnavailable: Error, Sendable, Equatable {
	case storageUnavailable
}

extension Ledger {
	private static let archiveMetadataScope: RecordQuery.Scope = .synced(
		[
			.userMessage, .attemptQuestion, .trainingIdentityObserved, .windowStart, .reviewApplied,
			.reviewWrite, .reviewCancelledUnknown,
		],
		includeLegacy: [.userMessage, .assistantMessage, .windowStart])

	package func history() async throws(LedgerFailure) -> [ArchivedConversationSummary] {
		let records = try await read(RecordQuery(scope: Self.archiveMetadataScope)).records
		let claims = try await read(RecordQuery(scope: .deviceLocal([.turnClaim]))).records
		let ownership = InformationOwnership(records: records + claims)
		let chats = Dictionary(grouping: records, by: \.chatId)
		var summaries: [(started: HybridLogicalClock, summary: ArchivedConversationSummary)] = []
		for (chat, records) in chats {
			guard let chat else { continue }
			let conversation = ConversationFold.fold(
				chat: chat, synced: records, local: claims, device: deviceId, ownership: ownership)
			for (segment, reason) in conversation.archivedSegments {
				guard
					let summary = segment.archiveSummary(
						chat: chat, reason: reason, ownership: ownership, device: deviceId)
				else {
					continue
				}
				summaries.append(summary)
			}
		}
		return summaries.sorted { $0.started > $1.started }.map(\.summary)
	}

	package func archivedConversation(
		_ ref: ArchivedConversationRef, process: ProcessID, today: CivilDate
	) async throws(LedgerFailure) -> ArchivedConversation? {
		let metadata = try await read(RecordQuery(scope: Self.archiveMetadataScope)).records
		let claims = try await read(RecordQuery(scope: .deviceLocal([.turnClaim]))).records
		let ownership = InformationOwnership(records: metadata + claims)
		let conversation = ConversationFold.fold(
			chat: ref.chat, synced: metadata, local: claims, device: deviceId, ownership: ownership)
		guard
			let (segment, reason) = conversation.archivedSegments.first(where: {
				$0.segment.id == ref.segment
			}),
			let summary = segment.archiveSummary(
				chat: ref.chat, reason: reason, ownership: ownership, device: deviceId)?.summary
		else { return nil }
		let turns = Set(segment.turns.map(\.turn))
		let settled = try await read(
			RecordQuery(scope: .synced([.turnSettled]), chatId: ref.chat, turns: turns)
		).records
		let local = try await read(
			RecordQuery(scope: ConversationFold.localScope, chatId: ref.chat, turns: turns)
		).records
		var archive = Conversation(chat: ref.chat, segments: [segment], ownership: ownership)
		archive.apply(settled + local, device: deviceId)
		let loaded = archive.current
		var projection = TurnProjection()
		let views = projection.turns(
			in: loaded, live: nil, device: deviceId, process: process, today: today)
		return ArchivedConversation(
			id: ref, startedOn: summary.startedOn, reason: reason,
			turns: views, notes: loaded.transcriptNotes(among: views),
			attribution: loaded.attribution(using: archive.ownership, device: deviceId))
	}
}

extension Segment {
	fileprivate func archiveSummary(
		chat: ChatID, reason: ArchiveReason, ownership: InformationOwnership, device: DeviceID
	)
		-> (started: HybridLogicalClock, summary: ArchivedConversationSummary)?
	{
		let first = turns.first?.fragments.first
		let note = notes.first
		guard let started = [first?.hlc, note?.hlc].compactMap({ $0 }).min(),
			let date = turns.first(where: { !hidesWholly($0) })?.fragments.first?.civilDate
				?? note?.date
		else { return nil }
		return (
			started,
			ArchivedConversationSummary(
				id: ArchivedConversationRef(chat: chat, segment: id), startedOn: date,
				reason: reason,
				firstQuestion: turns.first(where: { !hidesQuestion(of: $0) })?.requestText,
				attribution: attribution(using: ownership, device: device))
		)
	}
}

extension Conversation {
	fileprivate var archivedSegments: [(segment: Segment, reason: ArchiveReason)] {
		if chat == .main {
			return zip(segments, segments.dropFirst()).compactMap { segment, next in
				ArchiveReason(closedBy: next.openedBy).map { (segment, $0) }
			}
		}
		return [(earlierChat, .earlierChat)]
	}

	fileprivate var earlierChat: Segment {
		Segment(
			id: SegmentID(boundary: nil), openedBy: .chatStart,
			turns: segments.flatMap(\.turns), notes: segments.flatMap(\.notes))
	}
}

extension Coach {
	public func history() async throws(HistoryUnavailable) -> [ArchivedConversationSummary] {
		do {
			return try await ledger.history()
		} catch {
			throw .storageUnavailable
		}
	}

}
