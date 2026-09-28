import Foundation

package struct AutomaticReset: Sendable {
	package let chat: ChatID
	package let ledger: Ledger
	package let flushes: FlushWork
	package let clock: any Clock

	package func run(
		before turn: TurnID, in conversation: Conversation, session: SessionSettings,
		stamp: OperationStamp
	) async -> (kind: ResetKind, boundary: [AthleteRecord])? {
		guard let opened = conversation.turn(turn)?.firstFragment else { return nil }
		let zone = AthleteCalendar(clock: clock).zone(for: session.timeZone)
		let freshness = SessionFreshness.evaluate(
			last: conversation.lastExchange(before: turn), now: clock.now, zone: zone,
			settings: session)
		guard case .reset(let kind) = freshness else { return nil }
		let jobs = await flushes.jobs(in: conversation)
		let archived =
			(conversation.outstandingRows(jobs)
			+ conversation.messagesSinceLastFlush(jobs, excluding: turn, before: opened))
			.filter { $0.ulid < opened }
		do {
			if !archived.isEmpty {
				_ = try await flushes.open(
					.staleReset, covering: archived.map(\.ulid), stamp: stamp)
			}
			let boundary = try await ledger.commit(
				synced: [
					.windowStart(
						WindowStartBody(
							chatId: chat, firstIncludedUlid: opened, reason: .reset(kind)))
				],
				stamp: stamp)
			return (kind, boundary)
		} catch {
			flushes.diagnostics.record(.automaticResetUnsaved(chat, error))
			return nil
		}
	}
}
