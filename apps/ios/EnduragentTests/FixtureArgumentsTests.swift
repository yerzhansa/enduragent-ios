import EnduragentCoach
import EnduragentCoachFixtures
import Foundation
import Testing

@testable import Enduragent

@Suite struct FixtureArgumentsTests {
	@Test(arguments: FixtureStorePolicy.allCases)
	func builderRoundTripsThroughTheAppParser(store: FixtureStorePolicy) throws {
		let expected = FixtureArguments(
			store: store, keychain: .locked, coalescingMilliseconds: 1,
			recovery: "unreadable", host: "expire-after 3", language: "de", locale: "de_DE",
			clock: "1998-06-16T07:00:00Z", onboarded: true,
			calendarSaveFault: .loseAnswerOnce, calendarReadFault: .failOnce,
			recordReadFault: .failAfterPresentedOnce, presentationFault: .failLastCardOnce,
			reviewStage: .partial, planSaveStage: .saving, planTap: .replaced,
			resetFault: .failBoundary,
			replyParserFault: .fail, trainingDisplay: .wellnessUnavailable,
			credentialWriteFault: .failOnce, accessMethod: .openRouterNeedsCredits,
			creditsOutcome: .provisioningFailed, signInOutcome: .held,
			catalogResponse: .omittedSelectedModel, textSize: .accessibilityXXXL,
			feedback: FixtureFeedbackScript(rawValue: "lost,lost"), journal: .notSaving)
		var restored = FixtureArguments()
		try restored.update(from: expected.launchArguments)
		#expect(restored == expected)
		let otherSuite = "enduragent.fixture.arguments.other.\(UUID().uuidString)"
		let otherDefaults = try #require(UserDefaults(suiteName: otherSuite))
		defer { otherDefaults.removePersistentDomain(forName: otherSuite) }
		otherDefaults.setPersistentDomain(
			[
				FixtureLaunch.clockArgumentKey: FixtureLaunch.defaultClock,
				FixtureLaunch.coalescingArgumentKey: "2000",
				FixtureLaunch.recoveryArgumentKey: "readable",
				"enduragent.onboardingCompleted": false,
			], forName: otherSuite)
		let suite = "enduragent.fixture.arguments.test.\(UUID().uuidString)"
		let defaults = try #require(UserDefaults(suiteName: suite))
		defer { defaults.removePersistentDomain(forName: suite) }
		var values: [String: String] = [:]
		for index in stride(from: 0, to: expected.launchArguments.count, by: 2) {
			values[String(expected.launchArguments[index].dropFirst())] =
				expected.launchArguments[index + 1]
		}
		defaults.setPersistentDomain(values, forName: suite)
		let parsed = try #require(try FixtureLaunch.fromArguments(defaults))
		#expect(parsed.name == FixtureLaunch.firstWeekName)
		#expect(parsed.store.rawValue == store.rawValue)
		#expect(parsed.keychain == .locked)
		#expect(parsed.coalescing == CoalescingPolicy(window: .milliseconds(1)))
		#expect(parsed.recovery == .unreadable)
		#expect(parsed.host == .expireAfter(.seconds(3)))
		#expect(parsed.clock == expected.clock)
		#expect(parsed.calendarSaveFault == expected.calendarSaveFault)
		#expect(parsed.calendarReadFault == expected.calendarReadFault)
		#expect(parsed.recordReadFault == expected.recordReadFault)
		#expect(parsed.presentationFault == expected.presentationFault)
		#expect(parsed.reviewStage == expected.reviewStage)
		#expect(parsed.planSaveStage == expected.planSaveStage)
		#expect(parsed.planTap == expected.planTap)
		#expect(parsed.resetFault == expected.resetFault)
		#expect(parsed.replyParserFault == expected.replyParserFault)
		#expect(parsed.trainingDisplay == expected.trainingDisplay)
		#expect(parsed.credentialWriteFault == expected.credentialWriteFault)
		#expect(parsed.accessMethod == expected.accessMethod)
		#expect(parsed.creditsOutcome == expected.creditsOutcome)
		#expect(parsed.signInOutcome == expected.signInOutcome)
		#expect(parsed.catalogResponse == expected.catalogResponse)
		#expect(parsed.feedback?.answers == [.lostAnswer, .lostAnswer])
		#expect(parsed.journal == .notSaving)
		#expect(
			otherDefaults.string(forKey: FixtureLaunch.clockArgumentKey)
				== FixtureLaunch.defaultClock)
		#expect(otherDefaults.string(forKey: FixtureLaunch.coalescingArgumentKey) == "2000")
		#expect(otherDefaults.string(forKey: FixtureLaunch.recoveryArgumentKey) == "readable")
		#expect(otherDefaults.bool(forKey: "enduragent.onboardingCompleted") == false)
	}

	@Test(arguments: [
		FixtureLaunch.calendarSaveArgumentKey, FixtureLaunch.calendarReadArgumentKey,
		FixtureLaunch.recordReadArgumentKey, FixtureLaunch.presentationArgumentKey,
		FixtureLaunch.reviewStageArgumentKey, FixtureLaunch.planSaveArgumentKey,
		FixtureLaunch.planTapArgumentKey, FixtureLaunch.signInArgumentKey,
		FixtureLaunch.catalogArgumentKey,
		FixtureLaunch.resetArgumentKey,
		FixtureLaunch.replyParserArgumentKey,
		FixtureLaunch.trainingDisplayArgumentKey, FixtureLaunch.credentialWriteArgumentKey,
		FixtureLaunch.feedbackArgumentKey, FixtureLaunch.journalArgumentKey,
	])
	func rejectsUnknownProofFaults(key: String) throws {
		var builder = FixtureArguments()
		#expect(throws: DecodingError.self) {
			try builder.update(from: ["-\(key)", "unknown"])
		}
		let suite = "enduragent.fixture.invalid-fault.\(UUID().uuidString)"
		let defaults = try #require(UserDefaults(suiteName: suite))
		defer { defaults.removePersistentDomain(forName: suite) }
		defaults.setPersistentDomain(
			[FixtureLaunch.nameArgumentKey: FixtureLaunch.firstWeekName, key: "unknown"],
			forName: suite)
		#expect(throws: FixtureLaunchError.self) {
			try FixtureLaunch.fromArguments(defaults)
		}
	}

	@Test func proofFaultsAreOptIn() throws {
		let expected = FixtureArguments()
		var restored = FixtureArguments(
			calendarSaveFault: .loseAnswerOnce, calendarReadFault: .failOnce,
			recordReadFault: .failAfterPresentedOnce, presentationFault: .failLastCardOnce,
			reviewStage: .partial, resetFault: .failBoundary,
			replyParserFault: .fail, trainingDisplay: .wellnessUnavailable,
			credentialWriteFault: .failOnce, textSize: .accessibilityXXXL,
			feedback: FixtureFeedbackScript(rawValue: "timeout"), journal: .notSaving)
		try restored.update(from: expected.launchArguments)
		#expect(restored == expected)
		let suite = "enduragent.fixture.no-fault.\(UUID().uuidString)"
		let defaults = try #require(UserDefaults(suiteName: suite))
		defer { defaults.removePersistentDomain(forName: suite) }
		defaults.set(FixtureLaunch.firstWeekName, forKey: FixtureLaunch.nameArgumentKey)
		let parsed = try #require(try FixtureLaunch.fromArguments(defaults))
		#expect(parsed.calendarSaveFault == nil)
		#expect(parsed.calendarReadFault == nil)
		#expect(parsed.recordReadFault == nil)
		#expect(parsed.presentationFault == nil)
		#expect(parsed.reviewStage == nil)
		#expect(parsed.resetFault == nil)
		#expect(parsed.replyParserFault == nil)
		#expect(parsed.trainingDisplay == nil)
		#expect(parsed.credentialWriteFault == nil)
		#expect(parsed.signInOutcome == .cancel)
		#expect(parsed.catalogResponse == .offline)
		#expect(parsed.feedback == nil)
		#expect(parsed.journal == .saving)
	}
}
