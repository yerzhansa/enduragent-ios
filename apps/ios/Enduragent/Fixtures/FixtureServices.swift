#if DEBUG
	import EnduragentCoach
	import EnduragentCoachFixtures
	import Foundation

	struct FixtureServices: Sendable {
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
		let replyParser: ReplyParser
		let reviewProofDriver: FixtureReviewProofDriver?
	}

	extension AppServices {
		var fixtureTransport: FakeModelTransport? { fixture?.transport }
		var fixtureRecordFaults: RecordFaults? { fixture?.records }

		@MainActor
		static func fixture(
			_ launch: FixtureLaunch, defaults: UserDefaults, language: LanguageTag,
			backgroundSystem: any BackgroundSystem
		) throws -> AppServices {
			guard launch.name == FixtureLaunch.firstWeekName else {
				throw FixtureLaunchError.unknownFixture(launch.name)
			}
			FixtureBlockingURLProtocol.register()
			let clock = FixtureClock(
				calendar: FixedClock(now: launch.clock, timeZone: FixtureLaunch.timeZone))
			let intervals = FakeIntervalsClient(athleteName: FirstWeekFixture.athleteName, ftp: 250)
			FirstWeekFixture.install(on: intervals)
			FirstWeekFixture.install(launch.trainingDisplay, on: intervals)
			intervals.loseCalendarSaveAnswerOnce = launch.calendarSaveFault == .loseAnswerOnce
			intervals.failCalendarReadOnce = launch.calendarReadFault == .failOnce
			let transport = FakeModelTransport(
				respond: FirstWeekFixture.responses(intervals: intervals))
			let fixture = try FixtureRecordStore(
				directory: launch.directory, deviceId: persistedDeviceID(in: defaults),
				unreadable: launch.store == .unreadable)
			let records = fixture.faults
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
			let host: any ExecutionHost
			let fixtureHost: ImmediateExecutionHost?
			let leases: @Sendable () async -> [LeaseRecord]
			if launch.host == .continuedProcessing {
				let continued = ContinuedProcessingHost(
					bundleIdentifier: bundleIdentifier, system: backgroundSystem)
				host = continued
				fixtureHost = nil
				leases = { await continued.leases }
			} else {
				let immediate = ImmediateExecutionHost(expiringAfter: launch.host.expiry)
				host = immediate
				fixtureHost = immediate
				leases = { immediate.leases }
			}
			let coach = Coach(
				sport: .cycling,
				ports: CoachPorts(
					records: fixture.store,
					secrets: secrets,
					models: .scripted(transport),
					training: .fake { credential, selection in
						native?.bind(credential, selection: selection)
						return peer.client(for: credential)
					},
					credits: .fake(credits),
					host: host,
					clock: clock
				),
				builtInModel: builtInModel,
				deviceLanguage: language,
				coalescing: launch.coalescing
			)
			return AppServices(
				coach: coach,
				deviceCheck: FakeDeviceCheckTokenProvider(),
				clock: clock,
				leases: leases,
				packPrices: { _ in [:] },
				fixture: FixtureServices(
					transport: transport, records: records, host: fixtureHost, secrets: secrets,
					secretBacking: backing, nativeKeychain: native, trainingPeer: peer,
					recordStore: fixture.store,
					intervals: intervals, credits: credits,
					replyParser: launch.replyParserFault == .fail ? .failing : .foundation,
					reviewProofDriver: launch.recordReadFault == .failAfterPresentedOnce
						? FixtureReviewProofDriver() : nil)
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
			if launch.keychain != .empty { try FirstWeekFixture.install(on: fixture.store) }
			fixture.backing.locked = launch.keychain == .locked
			fixture.backing.unavailable = launch.keychain == .unavailable
			if launch.keychain == .malformedIntervals {
				try fixture.backing.corruptIntervalsConnection()
			}
			fixture.backing.failNextWrite = launch.credentialWriteFault == .failOnce
			return (fixture.store, fixture.backing, nil)
		}
	}
#endif
