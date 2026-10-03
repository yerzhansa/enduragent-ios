import EnduragentCoachFixtures
import Foundation
import Testing

@testable import EnduragentCoach

struct StarterGrantTests {
	@Test(
		arguments: [
			GrantOutcome.minted(Credits(units: 1)),
			.toppedUp(added: Credits(units: 2)),
			.alreadyGranted,
		], [false, true])
	func eachGrantResultReturnsOneNotice(outcome: GrantOutcome, hasKey: Bool) async throws {
		let credits = FakeCreditsClient()
		credits.grantResult = .success(outcome)
		credits.balanceResult = .success(CreditBalance(credits: Credits(units: 73)))
		let coach = await coach(credits: credits, hasKey: hasKey)
		let notice = await coach.claimStarter(deviceCheck: Data([0x01]))
		let expected: AthleteNotice
		switch outcome {
		case .minted:
			expected = AthleteNotice(
				key: Catalog.creditsBalance, count: 1, vars: ["formattedCount": .integer(1)],
				action: nil)
		case .toppedUp:
			expected = AthleteNotice(
				key: Catalog.onboardingStarterAdded, count: 2,
				vars: ["formattedCount": .integer(2)], action: nil)
		case .alreadyGranted where hasKey:
			expected = AthleteNotice(
				key: Catalog.creditsBalance, count: 73, vars: ["formattedCount": .integer(73)],
				action: nil)
		case .alreadyGranted:
			expected = AthleteNotice(key: Catalog.onboardingStarterAlreadyGranted, action: nil)
		}
		#expect(notice == expected)
		#expect(
			credits.calls == (outcome == .alreadyGranted && hasKey ? [.grant, .balance] : [.grant]))
	}

	@Test(arguments: [CreditsFailure.unavailable, .accountChanged, .noAthleteKey])
	func grantFailureReturnsOneNotice(failure: CreditsFailure) async {
		let credits = FakeCreditsClient()
		credits.grantResult = .failure(failure)
		let coach = await coach(credits: credits)
		let notice = await coach.claimStarter(deviceCheck: Data([0x01]))
		#expect(notice == AthleteNotice.credits(failure: failure))
	}

	@Test func balanceFailureReturnsOneNotice() async {
		let credits = FakeCreditsClient()
		credits.grantResult = .success(.alreadyGranted)
		credits.balanceResult = .failure(.unavailable)
		let coach = await coach(credits: credits)
		let notice = await coach.claimStarter(deviceCheck: Data([0x01]))
		#expect(notice == AthleteNotice.credits(failure: CreditsFailure.unavailable))
	}

	private func coach(credits: FakeCreditsClient, hasKey: Bool = true) async -> Coach {
		await consentingCoach(
			Coach(
				sport: .cycling,
				ports: CoachPorts(
					records: RecordStore(log: InMemoryRecordLog()),
					secrets: hasKey
						? keyedSecrets()
						: ICloudKeychainStore(backing: FixtureSecretStoreBacking()),
					models: .scripted(FakeModelTransport()),
					training: .fake { _, _ in FakeIntervalsClient(athleteName: "Ada", ftp: 250) },
					credits: .fake(credits), host: ImmediateExecutionHost(),
					clock: FixedClock(
						now: "1998-06-13T08:00:00+02:00", timeZone: "Europe/Amsterdam")),
				builtInModel: testModel, displayLocale: testDisplayLocale))
	}
}
