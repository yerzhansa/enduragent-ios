import EnduragentCoachFixtures
import Foundation

@testable import EnduragentCoach

func makeCoach(
	records: RecordStore,
	secrets: any SecretStore = keyedSecrets(),
	models: ModelService,
	intervals: any IntervalsClient = FakeIntervalsClient(athleteName: "Ada", ftp: 250),
	clock: any Clock = FixedClock(now: "1998-06-13T08:00:00+02:00", timeZone: "Europe/Amsterdam"),
	openRouterSignIn: OpenRouterSignInService? = nil,
	watchdogClock: HeldClock? = nil,
	builtInModel: ModelID = testModel,
	coalescing: CoalescingPolicy = quickWindow
) -> Coach {
	var ports = CoachPorts(
		records: records, secrets: secrets, models: models,
		training: .fake { _, _ in intervals }, credits: .fake(FakeCreditsClient()),
		host: ImmediateExecutionHost(), clock: clock, openRouterSignIn: openRouterSignIn)
	if let watchdogClock { ports.watchdogSleep = watchdogClock.sleep }
	return Coach(
		sport: .cycling, ports: ports, builtInModel: builtInModel,
		displayLocale: testDisplayLocale, coalescing: coalescing)
}
