import Foundation
import Testing

@testable import EnduragentCoach

@Suite struct SingleProposalReviewsTests {
	let transport = FakeModelTransport()
	let records = InMemoryRecordLog()
	let clock = FixedClock(now: "1998-06-13T08:00:00+02:00", timeZone: "Europe/Amsterdam")
	let ada = FakeIntervalsClient(athleteName: "Ada Kovač", ftp: 250, athleteId: "i1001")
	let bo = FakeIntervalsClient(athleteName: "Bo Lind", ftp: 240, athleteId: "i2002")
	let secrets = keyedSecrets()
	let phrasebook = CatalogPhrasebook(tag: .en, locale: LanguageTag.en.defaultLocale)

	@Test func controlsAreNoneUntilPresented() async throws {
		let coach = await coach()
		let review = try await propose(on: coach)
		#expect(review.controls == .none)
		#expect(review.cards.map { $0.name.sentence(in: phrasebook) } == ["Endurance"])
		#expect(review.cards.first?.lines(in: LanguageTag.en.phrasebook).first == "Warmup")

		#expect(await coach.decide(.presented(review.ref), in: .main) == .presentationRecorded)

		let presented = try #require(await coach.currentSnapshot(.main)?.review)
		#expect(presented.ref == review.ref)
		#expect(presented.token?.ref == review.ref)
	}

	@Test func cancelCommitsClearedCanceledAndSnapshotIsNil() async throws {
		let coach = await coach()
		let token = try await presentedToken(on: coach)

		#expect(await coach.decide(.cancel(token), in: .main) == .canceled(kept: []))

		#expect(await coach.currentSnapshot(.main)?.review == nil)
		let cleared = try await records.fetch(
			RecordQuery(scope: .deviceLocal([.proposalCleared]), chatId: "main")
		).records
		let proposed = try await records.fetch(
			RecordQuery(scope: .deviceLocal([.pendingProposal]), chatId: "main")
		).records
		guard case .deviceLocal(.pendingProposal(let proposal))? = proposed.first?.body else {
			Issue.record("expected the proposal row, got \(proposed)")
			return
		}
		#expect(
			cleared.map(\.body) == [
				.deviceLocal(
					.proposalCleared(
						ProposalClearedBody(chatId: .main, nonce: proposal.nonce, reason: .canceled)
					))
			])
		transport.script = [.text("Saturday went well."), .finish(reason: .stop)]
		_ = try await coach.sendAndSettle("How did Saturday go")
		#expect(await coach.currentSnapshot(.main)?.review == nil)
		#expect(await self.coach().currentSnapshot(.main)?.review == nil)
		#expect(ada.calls.allSatisfy { !$0.isWrite })
	}

	@Test func approveWithStaleTokenIsStaleControl() async throws {
		let coach = await coach()
		let token = try await presentedToken(on: coach)
		#expect(await coach.decide(.showAgain(token.ref), in: .main) == .presentationRecorded)
		#expect(await coach.decide(.presented(token.ref), in: .main) == .staleControl)
		#expect(await coach.currentSnapshot(.main)?.review?.controls == ReviewControls.none)
		#expect(await coach.decide(.approve(token), in: .main) == .staleControl)

		let fresh = try await presentedToken(on: coach)
		#expect(fresh.ref.set == token.ref.set)
		#expect(fresh.ref.delivery != token.ref.delivery)
		clock.advance(by: 11 * 60)
		#expect(await coach.decide(.approve(fresh), in: .main) == .staleControl)
		#expect(ada.calls.allSatisfy { !$0.isWrite })
		#expect(
			ReviewOutcome.staleControl.notice?.sentence(in: phrasebook)
				== "That proposal expired — ask me again and I'll re-propose.")
	}

	@Test func approveWritesOnceAndASecondTapIsStale() async throws {
		let coach = await coach()
		let token = try await presentedToken(on: coach)

		let outcome = await coach.decide(.approve(token), in: .main)

		#expect(outcome == .applied([ReviewReceipt(index: 0, result: .confirmed(eventId: "1"))]))
		#expect(outcome.notice == nil)
		#expect(
			ada.calls.filter(\.isWrite)
				== [
					.createEvent(
						date: "1998-06-14", externalId: "cycling-coach:1998-06-14:endurance")
				])
		#expect(await coach.currentSnapshot(.main)?.review == nil)
		#expect(await coach.decide(.approve(token), in: .main) == .staleControl)
		#expect(ada.calls.filter(\.isWrite).count == 1)
		let clears = try await records.fetch(
			RecordQuery(scope: .deviceLocal([.proposalCleared]), chatId: "main")
		).records
		guard
			case .operation(.workoutChangeSet(token.ref.set, token.ref.revision), _)? =
				clears.first?.cause
		else {
			Issue.record("expected the change-set stamp on the clear, got \(clears)")
			return
		}
	}

	@Test func presentationFailedWithdrawsTheControl() async throws {
		let coach = await coach()
		let token = try await presentedToken(on: coach)

		#expect(
			await coach.decide(.presentationFailed(token.ref), in: .main) == .presentationRecorded)

		#expect(await coach.currentSnapshot(.main)?.review?.controls == ReviewControls.none)
		#expect(await coach.decide(.approve(token), in: .main) == .staleControl)
		#expect(await coach.decide(.cancel(token), in: .main) == .staleControl)
		#expect(ada.calls.allSatisfy { !$0.isWrite })
	}

	@Test func racingApprovalsWriteOnce() async throws {
		let claim = ReviewGate()
		let coach = await gatedCoach(log: GatedReviewLog(inner: records, gate: claim), client: ada)
		let token = try await presentedToken(on: coach)
		await claim.arm()

		let first = Task { await coach.decide(.approve(token), in: .main) }
		#expect(await claim.waitUntilEntered())
		#expect(await coach.decide(.approve(token), in: .main) == .staleControl)
		#expect(await coach.decide(.cancel(token), in: .main) == .staleControl)
		await claim.release()

		#expect(
			await first.value
				== .applied([ReviewReceipt(index: 0, result: .confirmed(eventId: "1"))]))
		#expect(ada.calls.filter(\.isWrite).count == 1)
	}

	@Test func accountChangedBlocksApproval() async throws {
		let coach = await coach()
		let token = try await presentedToken(on: coach)

		_ = await coach.changeTraining(
			.replaceConfirmingAthleteSwitch(apiKey: "other-athlete", athlete: .keyOwner))

		let review = try #require(await coach.currentSnapshot(.main)?.review)
		#expect(review.notice?.kind == .accountChanged)
		#expect(review.controls == .none)
		#expect(
			phrasebook.say(try #require(review.notice).key, try #require(review.notice).vars)
				== "This workout was prepared for a different intervals.icu athlete. Ask me again to prepare it for the connected athlete."
		)
		#expect(await coach.decide(.approve(token), in: .main) == .blocked(.accountChanged))
		#expect(ada.calls.allSatisfy { !$0.isWrite })
		#expect(bo.calls.allSatisfy { !$0.isWrite })
		#expect(await self.coach().currentSnapshot(.main)?.review?.notice?.kind == .accountChanged)
	}

	@Test func lockedKeychainBlocksApprovalAndKeepsTheReview() async throws {
		let coach = await coach()
		let token = try await presentedToken(on: coach)
		secrets.locked = true

		let blocked = await coach.decide(.approve(token), in: .main)

		#expect(blocked == .blocked(.cannotVerify))
		#expect(
			blocked.notice?.sentence(in: phrasebook)
				== "Couldn't check your intervals.icu connection, so nothing was changed. Try again in a moment."
		)
		#expect(await coach.currentSnapshot(.main)?.review?.token == token)
		secrets.locked = false
		#expect(
			await coach.decide(.approve(token), in: .main)
				== .applied([ReviewReceipt(index: 0, result: .confirmed(eventId: "1"))]))
	}

	@Test func rejectedWriteSettlesPartiallyAppliedWithACatalogSentence() async throws {
		let coach = await coach()
		let token = try await presentedToken(on: coach)
		let card = try #require(await coach.currentSnapshot(.main)?.review?.cards.first)
		ada.writeFailure = IntervalsError(code: "http", details: "status 422", status: 422)

		let outcome = await coach.decide(.approve(token), in: .main)

		#expect(
			outcome == .partiallyApplied(done: [], stoppedAt: card, failure: .requestRejected))
		#expect(
			outcome.notice?.sentence(in: phrasebook)
				== "intervals.icu rejected the request — check your intervals.icu connection or API key."
		)
		#expect(await coach.currentSnapshot(.main)?.review == nil)
		#expect(
			coach.diagnostics.entries.contains {
				if case .toolFailed(_, .intervalsCreateWorkout, _) = $0.event {
					true
				} else {
					false
				}
			})
	}

	@Test func lostResponseSettlesUncertain() async throws {
		let coach = await coach()
		let token = try await presentedToken(on: coach)
		let card = try #require(await coach.currentSnapshot(.main)?.review?.cards.first)
		ada.writeFailure = URLError(.timedOut)

		let outcome = await coach.decide(.approve(token), in: .main)

		#expect(outcome == .uncertain(done: [], unresolved: card))
		#expect(
			outcome.notice?.sentence(in: phrasebook)
				== "Couldn't confirm whether this reached your intervals.icu calendar. Check your calendar before asking again."
		)
		#expect(await coach.currentSnapshot(.main)?.notes.isEmpty == true)
	}

	@Test func redisplayIssuesNoModelRequest() async throws {
		let coach = await coach()
		let review = try await propose(on: coach)
		let requests = transport.requests.count

		for _ in 0..<3 {
			_ = await coach.currentSnapshot(.main)
		}
		#expect(await coach.decide(.presented(review.ref), in: .main) == .presentationRecorded)
		#expect(await coach.decide(.showAgain(review.ref), in: .main) == .presentationRecorded)
		let rotated = try #require(await coach.currentSnapshot(.main)?.review)
		#expect(await coach.decide(.presented(rotated.ref), in: .main) == .presentationRecorded)
		#expect(await self.coach().currentSnapshot(.main)?.review?.cards == review.cards)

		#expect(transport.requests.count == requests)
	}

	@Test func everyReviewOutcomeReadsACatalogSentenceWithNoSwiftType() {
		let card = ReviewCard(
			index: 0, action: .add, name: .supplied("Endurance"), date: "1998-06-14", chart: nil,
			instructions: ReviewInstructions(content: .supplied("Warmup")), durationMinutes: nil,
			estimatedLoad: nil)
		let rows: [(ReviewOutcome, String?)] = [
			(.applied([ReviewReceipt(index: 0, result: .confirmed(eventId: "1"))]), nil),
			(.canceled(kept: []), nil),
			(.presentationRecorded, nil),
			(
				.partiallyApplied(done: [], stoppedAt: card, failure: .temporarilyUnavailable),
				"Couldn't reach intervals.icu right now — try again shortly."
			),
			(
				.partiallyApplied(done: [], stoppedAt: card, failure: .requestRejected),
				"intervals.icu rejected the request — check your intervals.icu connection or API key."
			),
			(
				.uncertain(done: [], unresolved: card),
				"Couldn't confirm whether this reached your intervals.icu calendar. Check your calendar before asking again."
			),
			(
				.blocked(.accountChanged),
				"This workout was prepared for a different intervals.icu athlete. Ask me again to prepare it for the connected athlete."
			),
			(
				.blocked(.cannotVerify),
				"Couldn't check your intervals.icu connection, so nothing was changed. Try again in a moment."
			),
			(.staleControl, "That proposal expired — ask me again and I'll re-propose."),
			(.storageUnavailable, "Sorry, something went wrong. Please try again."),
		]
		for (outcome, sentence) in rows {
			let notice = outcome.notice
			#expect(notice?.sentence(in: phrasebook) == sentence, "\(outcome)")
			#expect(notice?.action == nil)
		}
	}

	func coach() async -> Coach {
		let (ada, bo) = (ada, bo)
		return await consentingCoach(
			Coach(
				sport: .cycling,
				ports: CoachPorts(
					records: RecordStore(log: records), secrets: secrets,
					models: .scripted(transport),
					training: .fake { credential, _ in
						credential == .apiKey("other-athlete") ? bo : ada
					},
					credits: .fake(FakeCreditsClient()), host: ImmediateExecutionHost(),
					clock: clock),
				builtInModel: testModel,
				deviceLanguage: .en,
				coalescing: quickWindow
			))
	}

	func propose(on coach: Coach) async throws -> ReviewSnapshot {
		transport.script = [
			.toolCall(
				name: "intervals_create_workout",
				arguments:
					#"{"date":"1998-06-14","workout":{"name":"Endurance","steps":[{"type":"warmup","duration":{"value":10,"unit":"minutes"},"power":{"kind":"percent_ftp","low":55,"high":65}},{"type":"steady","duration":{"value":60,"unit":"minutes"},"power":{"kind":"percent_ftp","low":56,"high":75}}]}}"#
			),
			.finish(reason: .toolCalls),
			.text("I've prepared the ride. Confirm to add it."),
			.finish(reason: .stop),
		]
		_ = try await coach.sendAndSettle("Give me an endurance ride for tomorrow")
		return try #require(await coach.currentSnapshot(.main)?.review)
	}

	func presentedToken(on coach: Coach) async throws -> ReviewControlToken {
		let review =
			if let shown = await coach.currentSnapshot(.main)?.review {
				shown
			} else {
				try await propose(on: coach)
			}
		#expect(await coach.decide(.presented(review.ref), in: .main) == .presentationRecorded)
		return try #require(await coach.currentSnapshot(.main)?.review?.token)
	}
}

extension ReviewSnapshot {
	var token: ReviewControlToken? {
		guard case .approveOrCancel(let token) = controls else { return nil }
		return token
	}
}

extension FakeIntervalsCall {
	var isWrite: Bool {
		switch self {
		case .createEvent, .updateEvent, .deleteEvent: true
		default: false
		}
	}
}
