#if DEBUG
	import EnduragentCoach
	import EnduragentCoachFixtures
	import Foundation

	struct FixtureServices: Sendable {
		let transport: FakeModelTransport
		let records: RecordFaults
		let host: ImmediateExecutionHost?
		let secrets: ICloudKeychainStore
		let secretBacking: FixtureSecretStoreBacking
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
			_ launch: FixtureLaunch, defaults: UserDefaults,
			displayLocale: @escaping DisplayLocaleResolver,
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
			let secretFixture = try ICloudKeychainStore.fixture(directory: launch.directory)
			let secrets = secretFixture.store
			if launch.keychain != .empty {
				try FirstWeekFixture.install(on: secrets)
			}
			secretFixture.backing.locked = launch.keychain == .locked
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
					training: FirstWeekFixture.training(intervals),
					credits: .fake(credits),
					host: host,
					clock: clock
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
					transport: transport, records: records, host: fixtureHost, secrets: secrets,
					secretBacking: secretFixture.backing,
					intervals: intervals, credits: credits,
					replyParser: launch.replyParserFault == .fail ? .failing : .foundation,
					reviewProofDriver: launch.recordReadFault == .failAfterPresentedOnce
						? FixtureReviewProofDriver() : nil)
			)
		}
	}
#endif
