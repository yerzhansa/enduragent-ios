import EnduragentCoachFixtures
import Foundation
import Testing

@testable import EnduragentCoach

@Suite(.timeLimit(.minutes(2))) struct ReviewReadOwnershipTests {
	enum Read: String, CaseIterable, Sendable {
		case syncedScope = "ConversationFold.syncedScope"
		case localScope, flushJobs, consumedMarkers, importRetainedProposal, importLiveProposal
		case notes, snapshotWrites, snapshotRetainedProposal, snapshotLiveProposal
		case approvalLiveProposal, approvalWrites, recoveryWrites, recoveryRetainedProposal
		case cancelWrites, cancelRetainedProposal, cancelLiveProposal

		var imported: Bool {
			switch self {
			case .syncedScope, .localScope, .flushJobs, .consumedMarkers,
				.importRetainedProposal, .importLiveProposal:
				true
			default: false
			}
		}

		var unapproved: Bool {
			switch self {
			case .importLiveProposal, .snapshotLiveProposal, .approvalLiveProposal,
				.approvalWrites, .cancelLiveProposal:
				true
			default: false
			}
		}

		var scope: RecordQuery.Scope {
			switch self {
			case .syncedScope: ConversationFold.syncedScope
			case .localScope: ConversationFold.localScope
			case .flushJobs: ConversationFold.flushScope
			case .consumedMarkers: ConversationFold.consumedMarkerScope
			case .notes: .synced([.reviewApplied, .reviewWrite, .reviewCancelledUnknown])
			case .snapshotWrites, .approvalWrites, .recoveryWrites, .cancelWrites:
				.synced([.reviewWrite, .reviewCancelledUnknown])
			default: ProposalPolicy.proposalQuery(.main).scope
			}
		}

		var skipping: Int {
			self == .approvalLiveProposal || self == .approvalWrites ? 1 : 0
		}

		func decision(_ ready: ReviewSnapshot) throws -> ReviewDecision {
			switch self {
			case .approvalLiveProposal, .approvalWrites: return .approve(try #require(ready.token))
			case .recoveryWrites, .recoveryRetainedProposal: return .checkAgain(ready.ref)
			case .cancelWrites, .cancelRetainedProposal:
				guard case .retryRemainingOrCancel(let token) = ready.controls else {
					throw ReviewReadFixtureFailure()
				}
				return .cancel(token)
			case .cancelLiveProposal:
				return .cancel(try #require(ready.token))
			default: return .presented(ready.ref)
			}
		}
	}

	@Test(arguments: Read.allCases)
	func everySavedReviewReadRetainsDisablesPublishesAndRestores(read: Read) async throws {
		let server = try CalendarWriteServer()
		let url = try await server.start()
		defer { server.stop() }
		server.state.withLock { $0.response = .status(502) }
		let faults = FaultInjectingRecordLog(wrapping: InMemoryRecordLog())
		let store = ImportingRecordLog(inner: faults)
		let helper = DurableCalendarWriteTests()
		let fixture = await helper.fixture(url: url, store: store)
		let coach = fixture.coach
		let (_, token) = try await helper.proposal(on: coach, model: fixture.model)
		if !read.unapproved { _ = await coach.decide(.approve(token), in: .main) }
		await coach.stop(.main)
		if read == .cancelWrites || read == .cancelRetainedProposal {
			server.state.withLock { $0.readResponse = .body("[]") }
			_ = await coach.decide(.checkAgain(token.ref), in: .main)
		}
		_ = await coach.decide(.presented(token.ref), in: .main)
		let ready = try #require(await coach.currentSnapshot(.main)?.review)
		let content = try #require(ready.content)
		let buttons = DisabledReviewButtons(ready.controls)
		try #require(buttons != .none)
		if read == .consumedMarkers {
			try await store.append(
				[
					storedRecord(
						device: store.deviceId, wall: 1, ulid: fixedUlid(700),
						body: .deviceLocal(
							.flushPending(FlushPendingBody(chatId: .main, messageUlids: []))))
				],
				locality: .deviceLocal)
		}
		let observed = ImportSnapshots(await coach.observe(.main))
		try await waitUntil { observed.latest?.review == ready }
		let calls = server.state.withLock { $0.requests.count }
		faults.failNextFetch(in: read.scope, skipping: read.skipping)
		if read.imported {
			store.notifyImport()
			try await waitUntil {
				coach.diagnostics.entries.contains {
					$0.event == .importsUnavailable(.main, .unavailable)
				}
			}
		} else {
			_ = await coach.decide(try read.decision(ready), in: .main)
		}
		#expect(faults.failedFetchCount == 1)
		let failed = try #require(await coach.currentSnapshot(.main)?.review)
		#expect(failed.ref == ready.ref)
		#expect(failed.content == content)
		#expect(failed.state == .storageUnavailable(content, buttons))
		#expect(failed.controls == .none)
		#expect(failed.token == nil)
		let snapshot = try #require(await coach.currentSnapshot(.main))
		let sentence = LanguageTag.en.phrasebook.say(Catalog.reviewStorageUnavailable)
		let lines =
			[failed.notice].compactMap { $0 }.map {
				LanguageTag.en.phrasebook.say($0.key, $0.vars)
			}
			+ snapshot.notes.values.flatMap { $0 }.map {
				$0.sentence(in: displayLocale())
			}
		#expect(lines.filter { $0 == sentence }.count == 1)
		#expect(server.state.withLock { $0.requests.count } == calls)
		if case .storageUnavailable = failed.state {
			try await waitUntil { observed.latest?.review == failed }
		}
		#expect(observed.latest?.review?.state == .storageUnavailable(content, buttons))
		if read.imported {
			store.notifyImport()
			try await waitUntil { observed.latest?.review == ready }
		} else {
			#expect(await coach.decide(.checkAgain(ready.ref), in: .main) == .presentationRecorded)
		}
		#expect(await coach.currentSnapshot(.main)?.review == ready)
		try await waitUntil { observed.latest?.review == ready }
		#expect(server.state.withLock { $0.requests.count } == calls)
		await coach.lifecycle(.willTerminate)
	}
}

private struct ReviewReadFixtureFailure: Error {}
