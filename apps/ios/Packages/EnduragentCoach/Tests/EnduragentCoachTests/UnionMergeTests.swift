import Foundation
import Testing

@testable import EnduragentCoach

@Suite struct UnionMergeTests {
	let phoneA = DeviceID(rawValue: "phone-a")
	let phoneB = DeviceID(rawValue: "phone-b")

	@Test func sectionHighestHLC() {
		let earlier = record(
			device: phoneA,
			wall: 1,
			ulid: ulid(1),
			body: .synced(.memorySection(MemorySectionBody(name: .person, content: "Ada, older")))
		)
		let later = record(
			device: phoneB,
			wall: 2,
			ulid: ulid(2),
			body: .synced(.memorySection(MemorySectionBody(name: .person, content: "Ada Kovač")))
		)
		let other = record(
			device: phoneA,
			wall: 3,
			ulid: ulid(3),
			body: .synced(
				.memorySection(MemorySectionBody(name: .schedule, content: "Saturdays free")))
		)
		#expect(UnionMerge.sectionText([earlier, later, other], name: .person) == "Ada Kovač")
		#expect(
			UnionMerge.sectionText([earlier, later, other], name: .schedule) == "Saturdays free")
		#expect(UnionMerge.sectionText([earlier, later, other], name: .goals) == nil)
	}

	@Test func ledgerDedupeAcrossDevices() {
		let first = record(
			device: phoneA,
			wall: 1,
			ulid: ulid(1),
			body: .synced(
				.ledgerEvent(
					LedgerEventBody(
						date: "1998-06-13", kind: .decision, text: "Keep Saturdays free.",
						source: .chat)))
		)
		let duplicate = record(
			device: phoneB,
			wall: 2,
			ulid: ulid(2),
			body: .synced(
				.ledgerEvent(
					LedgerEventBody(
						date: "1998-06-13", kind: .decision, text: "  Keep Saturdays   free.  ",
						source: .flush)))
		)
		let extra = record(
			device: phoneA,
			wall: 3,
			ulid: ulid(3),
			body: .synced(
				.ledgerEvent(
					LedgerEventBody(
						date: "1998-06-14", kind: .illness, text: "Knee niggle.", source: .chat)))
		)
		let events = UnionMerge.ledger([duplicate, extra, first])
		#expect(events == [first, extra])
	}

	@Test func proposalClearedThenAbsent() {
		let nonce = Nonce()
		let now = Date(timeIntervalSince1970: 899_164_800)
		let live = record(
			device: phoneA,
			wall: 1,
			ulid: ulid(1),
			body: .deviceLocal(
				.pendingProposal(
					sampleProposal(
						chatId: .main, nonce: nonce, expiresAt: now.addingTimeInterval(600))))
		)
		#expect(UnionMerge.pendingProposal([live], chatId: .main, now: now)?.nonce == nonce)
		let cleared = record(
			device: phoneA,
			wall: 2,
			ulid: ulid(2),
			body: .deviceLocal(
				.proposalCleared(
					ProposalClearedBody(chatId: .main, nonce: nonce, reason: .executed)))
		)
		#expect(UnionMerge.pendingProposal([live, cleared], chatId: .main, now: now) == nil)
		let expired = record(
			device: phoneA,
			wall: 3,
			ulid: ulid(3),
			body: .deviceLocal(
				.pendingProposal(sampleProposal(chatId: .main, nonce: Nonce(), expiresAt: now)))
		)
		#expect(UnionMerge.pendingProposal([expired], chatId: .main, now: now) == nil)
	}

	@Test func canceledClearHidesTheProposalAndTheLiveRecordKeepsItsIdentity() {
		let nonce = Nonce()
		let now = Date(timeIntervalSince1970: 899_164_800)
		let live = record(
			device: phoneA,
			wall: 1,
			ulid: ulid(1),
			body: .deviceLocal(
				.pendingProposal(
					sampleProposal(
						chatId: .main, nonce: nonce, expiresAt: now.addingTimeInterval(600))))
		)
		let found = UnionMerge.pendingProposalRecord([live], chatId: .main, now: now)
		#expect(found?.ulid == live.ulid)
		#expect(found?.account == live.account)
		let canceled = record(
			device: phoneA,
			wall: 2,
			ulid: ulid(2),
			body: .deviceLocal(
				.proposalCleared(
					ProposalClearedBody(chatId: .main, nonce: nonce, reason: .canceled)))
		)
		#expect(UnionMerge.pendingProposalRecord([live, canceled], chatId: .main, now: now) == nil)
	}

	@Test func replyLanguageHighestHLC() {
		let italian = record(
			device: phoneA,
			wall: 3,
			ulid: ulid(3),
			body: .synced(.coachReplyLanguage(CoachReplyLanguageBody(tag: .it)))
		)
		let automatic = record(
			device: phoneB,
			wall: 4,
			ulid: ulid(4),
			body: .synced(.coachReplyLanguage(CoachReplyLanguageBody(tag: nil)))
		)
		#expect(Preferences.fold([italian]).language == .fixed(.it))
		#expect(Preferences.fold([automatic, italian]).language == .automatic)
	}

	@Test func ledgerDigestMatchesDesktop() throws {
		let rows = try loadLedgerDigestTable()
		for row in rows {
			let kind = try #require(LedgerKind(rawValue: row.kind))
			let date = try #require(CivilDate(rawValue: row.date))
			let digest = UnionMerge.ledgerDigest(date: date, kind: kind, text: row.text)
			#expect(Array(digest.utf8) == Array(row.digest.utf8))
		}
	}

	private func record(
		device: DeviceID,
		wall: Int64,
		logical: UInt32 = 0,
		ulid: ULID,
		body: RecordBody
	) -> AthleteRecord {
		storedRecord(device: device, wall: wall, logical: logical, ulid: ulid, body: body)
	}

	private func ulid(_ offset: Int) -> ULID {
		ULID.generate(at: Date(timeIntervalSince1970: 899_164_800 + Double(offset)))
	}
}
