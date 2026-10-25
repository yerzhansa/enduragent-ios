#if os(macOS)
	import Foundation
	import Testing

	@testable import EnduragentCoach

	@Suite(.serialized) struct LivePlanCheck {
		@Test(.enabled(if: LiveCheck.selected == .plan), .timeLimit(.minutes(60)))
		func planningSuiteAgainstTheRealModel() async throws {
			let run = try await LiveCoachSuite.live.run(
				LivePlanScenarios.planned, check: .plan, title: LivePlanScenarios.title)
			for failure in run.failures {
				Issue.record(Comment(rawValue: failure))
			}
		}
	}
#endif
