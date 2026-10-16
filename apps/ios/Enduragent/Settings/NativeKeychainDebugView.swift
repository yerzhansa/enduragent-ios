#if DEBUG
	import EnduragentCoach
	import EnduragentCoachFixtures
	import Foundation
	import SwiftUI

	struct NativeKeychainDebugView: View {
		let proof: NativeKeychainProof
		let fixture: FixtureServices
		let coach: Coach
		@State private var report = "waiting"

		var body: some View {
			Text("Native Keychain receipts")
				.accessibilityIdentifier("fixture.nativeKeychain")
				.accessibilityValue(report)
				.task {
					do {
						report = try await proof.report(
							coach: coach, records: fixture.recordStore,
							intervals: fixture.intervals,
							buildVersion: buildVersion)
					} catch {
						report = "Native Keychain evidence unavailable: \(error)"
					}
				}
		}

		private var buildVersion: String {
			let version = Bundle.main.object(forInfoDictionaryKey: "CFBundleShortVersionString")
			let build = Bundle.main.object(forInfoDictionaryKey: "CFBundleVersion")
			return "\(version as? String ?? "missing") (\(build as? String ?? "missing"))"
		}
	}
#endif
