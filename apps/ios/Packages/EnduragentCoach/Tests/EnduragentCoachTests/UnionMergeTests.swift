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
		#expect(events.map(\.text) == ["Keep Saturdays free.", "Knee niggle."])
		#expect(events.map(\.kind) == [.decision, .illness])
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

	@Test func planningDeviceAndReplyLanguageHighestHLC() {
		let firstDevice = record(
			device: phoneA,
			wall: 1,
			ulid: ulid(1),
			body: .synced(
				.planningDevice(
					PlanningDeviceBody(
						planningDeviceId: phoneA, planUlid: ulid(10),
						activatedAt: Date(timeIntervalSince1970: 10))))
		)
		let secondDevice = record(
			device: phoneB,
			wall: 2,
			ulid: ulid(2),
			body: .synced(
				.planningDevice(
					PlanningDeviceBody(
						planningDeviceId: phoneB, planUlid: ulid(11),
						activatedAt: Date(timeIntervalSince1970: 20))))
		)
		#expect(UnionMerge.planningDevice([firstDevice, secondDevice])?.planningDeviceId == phoneB)
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
		#expect(UnionMerge.coachReplyLanguage([italian]) == .it)
		#expect(UnionMerge.coachReplyLanguage([italian, automatic]) == nil)
	}

	@Test func ledgerDigestMatchesDesktop() throws {
		let rows = try loadLedgerDigestTable()
		var computed: [LedgerDigestRow] = []
		for row in rows {
			let kind = try #require(LedgerKind(rawValue: row.kind))
			let date = try #require(CivilDate(rawValue: row.date))
			let normalized = row.text.replacing(/^[\s]+|[\s]+$/, with: "").replacing(
				/\s+/, with: " "
			).lowercased()
			let digestInput = JSONValue.array([
				.string(row.date),
				.string(row.kind),
				.string(normalized),
			]).canonicalDigestInput()
			let digest = UnionMerge.ledgerDigest(date: date, kind: kind, text: row.text)
			#expect(Array(digestInput.utf8) == Array(row.digestInput.utf8))
			#expect(Array(digest.utf8) == Array(row.digest.utf8))
			computed.append(
				LedgerDigestRow(
					date: row.date,
					kind: row.kind,
					text: row.text,
					digestInput: digestInput,
					digest: digest,
					estimateTokens: estimateTokens(row.text)
				)
			)
		}
		if let path = ProcessInfo.processInfo.environment["ENDURAGENT_DIGEST_OUT"], !path.isEmpty {
			try encodeDigestTable(computed).write(toFile: path, atomically: true, encoding: .utf8)
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

private func encodeDigestTable(_ rows: [LedgerDigestRow]) -> String {
	let objects = rows.map { row in
		let fields = [
			("date", JSONValue.string(row.date).canonicalDigestInput()),
			("kind", JSONValue.string(row.kind).canonicalDigestInput()),
			("text", JSONValue.string(row.text).canonicalDigestInput()),
			("digestInput", JSONValue.string(row.digestInput).canonicalDigestInput()),
			("digest", JSONValue.string(row.digest).canonicalDigestInput()),
			("estimateTokens", String(row.estimateTokens)),
		]
		let inner = fields.map { "    \"\($0.0)\": \($0.1)" }.joined(separator: ",\n")
		return "  {\n\(inner)\n  }"
	}
	return "[\n" + objects.joined(separator: ",\n") + "\n]\n"
}
