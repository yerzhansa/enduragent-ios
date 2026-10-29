#if DEBUG
	import EnduragentCoach
	import EnduragentCoachFixtures
	import Foundation
	import Security

	struct FixtureServices: Sendable {
		let catalogSource: FakeModelCatalogSource
		let transport: FakeModelTransport
		let records: RecordFaults
		let host: ImmediateExecutionHost?
		let secrets: ICloudKeychainStore
		let secretBacking: FixtureSecretStoreBacking?
		let nativeKeychain: NativeKeychainProof?
		let trainingPeer: FixtureTrainingPeer
		let recordStore: RecordStore
		let intervals: FakeIntervalsClient
		let credits: FakeCreditsClient
		let openRouterAuthorizer: FakeOpenRouterAuthorizer
		let signInOutcome: FixtureSignInOutcome
		let replyParser: ReplyParser
		let reviewProofDriver: FixtureReviewProofDriver?
		let planTapDriver: FixturePlanTapDriver?
		let presentationFault: FixturePresentationFault?
		let feedback: FakeFeedbackServer
	}

	extension AppServices {
		var fixtureTransport: FakeModelTransport? { fixture?.transport }
		var fixtureRecordFaults: RecordFaults? { fixture?.records }

		@MainActor
		static func fixture(
			_ launch: FixtureLaunch, defaults: UserDefaults,
			displayLocale: @escaping DisplayLocaleResolver,
			backgroundSystem: any BackgroundSystem
		) throws -> AppServices {
			guard launch.name == FixtureLaunch.firstWeekName else {
				throw FixtureLaunchError.unknownFixture(launch.name)
			}
			let identity = try installedIdentity()
			let clock = FixtureClock(
				calendar: FixedClock(now: launch.clock, timeZone: FixtureLaunch.timeZone))
			let intervals = FakeIntervalsClient.firstWeek(today: FirstWeekFixture.today)
			FirstWeekFixture.install(launch.trainingDisplay, on: intervals)
			intervals.loseCalendarSaveAnswerOnce = launch.calendarSaveFault == .loseAnswerOnce
			intervals.failCalendarReadOnce = launch.calendarReadFault == .failOnce
			let fixture = try FixtureRecordStore(
				directory: launch.directory, deviceId: persistedDeviceID(in: defaults),
				unreadable: launch.store == .unreadable)
			let records = fixture.faults
			try launch.reviewStage.map { try $0.install(on: intervals, records: records) }
			try launch.planSaveStage.map { try $0.install(on: records) }
			if launch.resetFault == .failBoundary { try records.failAppends(ofKind: "windowStart") }
			records.failRecoveryReads = launch.recovery == .unreadable
			let (secrets, backing, native) = try fixtureSecrets(launch)
			let peerSecrets: ICloudKeychainStore
			if let backing {
				peerSecrets = backing.store()
			} else if let native {
				peerSecrets = native.store()
			} else {
				throw FixtureLaunchError.nativeProofBuildRequired
			}
			let peer = FixtureTrainingPeer(secrets: peerSecrets, athleteA: intervals)
			let credits = FakeCreditsClient()
			FirstWeekFixture.install(on: credits)
			FirstWeekFixture.install(launch.creditsOutcome, on: credits)
			let response = FirstWeekFixture.responses(intervals: intervals, credits: credits)
			let transport = FakeModelTransport { request in
				if launch.accessMethod == .rejectedOpenRouter,
					request.credential == FirstWeekFixture.openRouterKey
				{
					return ScriptedReply([.fail(.http(status: 401))])
				}
				return response(request)
			}
			let host: any ExecutionHost
			let fixtureHost: ImmediateExecutionHost?
			let leases: @Sendable () async -> [LeaseRecord]
			switch launch.host {
			case .backgroundTime:
				let background = BackgroundTimeHost(
					bundleIdentifier: bundleIdentifier, system: backgroundSystem)
				host = background
				fixtureHost = nil
				leases = { await background.leases }
			case .immediate, .expireAfter:
				let immediate = ImmediateExecutionHost(expiringAfter: launch.host.expiry)
				host = immediate
				fixtureHost = immediate
				leases = { immediate.leases }
			}
			let authorizer = FakeOpenRouterAuthorizer(response: launch.signInOutcome.response)
			let catalogSource = FakeModelCatalogSource(response: launch.catalogResponse)
			let feedback = FakeFeedbackServer(script: launch.feedback?.answers ?? [])
			let coach = Coach(
				sport: .cycling,
				ports: CoachPorts(
					records: fixture.store,
					secrets: secrets,
					models: .scripted(
						transport, catalogSource: catalogSource, cacheDirectory: launch.directory),
					training: .fake { credential, selection in
						native?.bind(credential, selection: selection)
						return peer.client(for: credential)
					},
					credits: .fake(credits, mintedKey: FirstWeekFixture.creditsKey),
					host: host,
					clock: clock,
					support: .fixture(
						directory: launch.directory, app: identity, server: feedback,
						journal: launch.journal),
					openRouterSignIn: .fake(
						authorizer: authorizer,
						exchangeFails: launch.signInOutcome == .exchangeFailure)
				),
				builtInModel: builtInModel,
				displayLocale: displayLocale,
				coalescing: launch.coalescing
			)
			return AppServices(
				coach: coach,
				deviceCheck: FakeDeviceCheckTokenProvider(),
				clock: clock,
				leases: leases,
				packPrices: { _ in [:] },
				fixture: FixtureServices(
					catalogSource: catalogSource, transport: transport, records: records,
					host: fixtureHost, secrets: secrets,
					secretBacking: backing, nativeKeychain: native, trainingPeer: peer,
					recordStore: fixture.store,
					intervals: intervals, credits: credits, openRouterAuthorizer: authorizer,
					signInOutcome: launch.signInOutcome,
					replyParser: launch.replyParserFault == .fail ? .failing : .foundation,
					reviewProofDriver: launch.recordReadFault == .failAfterPresentedOnce
						? FixtureReviewProofDriver() : nil,
					planTapDriver: launch.planTap.map {
						FixturePlanTapDriver(tap: $0, calendar: clock.calendar)
					},
					presentationFault: launch.presentationFault, feedback: feedback)
			)
		}

		private static func fixtureSecrets(_ launch: FixtureLaunch) throws
			-> (ICloudKeychainStore, FixtureSecretStoreBacking?, NativeKeychainProof?)
		{
			if launch.keychain == .nativeProof {
				#if KEYCHAIN_DEVICE_PROOF && !targetEnvironment(simulator)
					guard bundleIdentifier == "icu.enduragent.keychainproof",
						launch.store == .fresh || launch.store == .keep
					else { throw FixtureLaunchError.nativeProofBuildRequired }
					let proof = NativeKeychainProof()
					let secrets = proof.store()
					if launch.store == .fresh {
						for slot in [
							CredentialSlot.creditsAccount, .openRouterAccountKey,
							.intervalsConnection, .accessSelection,
						] {
							try secrets.delete(slot)
						}
						try FirstWeekFixture.install(on: secrets)
					}
					return (secrets, nil, proof)
				#else
					throw FixtureLaunchError.nativeProofBuildRequired
				#endif
			}
			let fixture = try ICloudKeychainStore.fixture(directory: launch.directory)
			if launch.store != .keep, launch.keychain != .empty {
				try FirstWeekFixture.install(launch.accessMethod, on: fixture.store)
			}
			if launch.store.keepsSeedConnection {
				try FirstWeekFixture.installReviewSeedConnection(on: fixture.store)
			}
			fixture.backing.locked = launch.keychain == .locked
			fixture.backing.unavailable = launch.keychain == .unavailable
			if launch.keychain == .malformedIntervals {
				try fixture.backing.corruptIntervalsConnection()
			}
			if launch.keychain == .malformedAccess {
				try fixture.backing.corruptAccessSelection()
			}
			fixture.backing.failNextWrite = launch.credentialWriteFault == .failOnce
			if launch.credentialWriteFault == .failSelection {
				fixture.backing.failWrites(
					CredentialSlot.accessSelection.rawValue, with: errSecNotAvailable)
			}
			return (fixture.store, fixture.backing, nil)
		}
	}
	extension FixturePlanSaveStage {
		static let savedPlanKind = "savedPlan"

		func install(on records: RecordFaults) throws {
			switch self {
			case .saving: try records.holdAppends(ofKind: Self.savedPlanKind)
			case .storage: try records.failAppends(ofKind: Self.savedPlanKind)
			}
		}
	}

	extension FixtureReviewStage {
		static let sendingHeldWrite = 2
		static let storageStallAfter = 3
		static let refreshedMinutes = 90

		func install(on intervals: FakeIntervalsClient, records: RecordFaults) throws {
			switch self {
			case .sending:
				intervals.holdCalendarWrite = Self.sendingHeldWrite
			case .partial:
				intervals.refuseCalendarUpdateOnce = true
				intervals.answerCalendarDeletesGone = true
			case .unconfirmed:
				intervals.loseCalendarSaveAnswerOnce = true
				intervals.failCalendarReadAfterLostAnswer = true
			case .refreshed:
				intervals.driftAfterFirstRead = [
					WorkoutReviewFixture.editedEvent: .lengthen(minutes: Self.refreshedMinutes)
				]
			case .blocked:
				intervals.driftAfterFirstRead = [WorkoutReviewFixture.deletedEvent: .remove]
			case .storage:
				try records.failReviewAppend(after: Self.storageStallAfter)
			}
		}
	}
#endif
