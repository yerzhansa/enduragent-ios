#if DEBUG
	import EnduragentCoach
	import EnduragentCoachFixtures
	import Foundation

	struct FixtureServices: Sendable {
		let transport: FakeModelTransport
		let records: RecordFaults
		let host: ImmediateExecutionHost
		let secrets: ICloudKeychainStore
		let secretBacking: FixtureSecretStoreBacking
		let intervals: FakeIntervalsClient
		let credits: FakeCreditsClient
	}

	extension AppServices {
		var fixtureTransport: FakeModelTransport? { fixture?.transport }
		var fixtureRecordFaults: RecordFaults? { fixture?.records }

		static func fixture(_ launch: FixtureLaunch, defaults: UserDefaults) throws -> AppServices {
			guard launch.name == FixtureLaunch.firstWeekName else {
				throw FixtureLaunchError.unknownFixture(launch.name)
			}
			FixtureBlockingURLProtocol.register()
			let clock = FixtureClock(
				calendar: FixedClock(now: launch.clock, timeZone: FixtureLaunch.timeZone))
			let intervals = FakeIntervalsClient(athleteName: FirstWeekFixture.athleteName, ftp: 250)
			FirstWeekFixture.install(on: intervals)
			let transport = FakeModelTransport(respond: FirstWeekFixture.respond)
			let fixture = try FixtureRecordStore(
				directory: launch.directory, deviceId: persistedDeviceID(in: defaults),
				unreadable: launch.store == .unreadable)
			let records = fixture.faults
			records.failRecoveryReads = launch.recovery == .unreadable
			let secretFixture = try ICloudKeychainStore.fixture(directory: launch.directory)
			let secrets = secretFixture.store
			if launch.keychain != .empty {
				try FirstWeekFixture.install(on: secrets)
			}
			secretFixture.backing.locked = launch.keychain == .locked
			let credits = FakeCreditsClient()
			FirstWeekFixture.install(on: credits)
			let host = ImmediateExecutionHost(expiringAfter: launch.host.expiry)
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
				deviceLanguage: Language.uiTag(systemLanguages: Locale.preferredLanguages),
				coalescing: launch.coalescing
			)
			return AppServices(
				coach: coach,
				deviceCheck: FakeDeviceCheckTokenProvider(),
				clock: clock,
				leases: { host.leases },
				packPrices: { _ in [:] },
				fixture: FixtureServices(
					transport: transport, records: records, host: host, secrets: secrets,
					secretBacking: secretFixture.backing,
					intervals: intervals, credits: credits)
			)
		}
	}
#endif
