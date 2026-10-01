import Foundation
import Security
import Testing

@testable import EnduragentCoach

extension CredentialVaultTests {
	@Test func legacyProposalAppliesOnAnotherDevice() async throws {
		let legacy = Data(#"{"apiKey":{"_0":"icu-test-key"}}"#.utf8)
		let phoneBacking = legacyIntervalsBacking(legacy)
		let padBacking = legacyIntervalsBacking(legacy)
		let phone = ICloudKeychainStore(backing: phoneBacking)
		let pad = ICloudKeychainStore(backing: padBacking)
		let phoneConnection = try #require(try phone.intervalsConnection())
		let padConnection = try #require(try pad.intervalsConnection())
		#expect(phoneConnection.id == padConnection.id)
		let pending = try await proposeRide(on: coach(phone))
		let peer = await coach(pad)
		let review = try #require(await peer.currentSnapshot(.main)?.review)
		#expect(review.ref.set == pending.ref.set)
		#expect(await peer.decide(.presented(review.ref), in: .main) == .presentationRecorded)
		let token = try #require(await peer.currentSnapshot(.main)?.review?.token)
		#expect(
			await peer.decide(.approve(token), in: .main)
				== .applied([ReviewReceipt(index: 0, result: .confirmed(eventId: "1"))]))
		#expect(
			ada.calls.contains {
				if case .createEvent = $0 { return true }
				return false
			})
		for backing in [phoneBacking, padBacking] {
			#expect(
				try backing.copy(account: CredentialSlot.intervalsConnection.rawValue) == legacy)
			#expect(backing.writes(to: CredentialSlot.intervalsConnection.rawValue) == 0)
		}
	}

	@Test func legacyTrainingStaysConnectedWhenWritesFail() async throws {
		let legacy = Data(#"{"apiKey":{"_0":"icu-test-key"}}"#.utf8)
		let backing = legacyIntervalsBacking(legacy)
		backing.failWrites(CredentialSlot.intervalsConnection.rawValue, with: errSecNotAvailable)
		let store = ICloudKeychainStore(backing: backing)
		let coach = await coach(store)
		guard case .connected(let summary, let account) = try await coach.refreshedStatus().training
		else {
			Issue.record("expected the legacy connection to remain readable when writes fail")
			return
		}
		let connection = try #require(try store.intervalsConnection())
		#expect(summary == adaSummary)
		#expect(account == self.account(connection))
		#expect(try backing.copy(account: CredentialSlot.intervalsConnection.rawValue) == legacy)
		#expect(backing.writes(to: CredentialSlot.intervalsConnection.rawValue) == 0)
	}
}

extension KeychainStoreTests {
	@Test(arguments: [
		(
			#"{"apiKey":{"_0":"icu-test-key"}}"#,
			#"{"credential":{"apiKey":{"_0":"icu-test-key"}}}"#
		),
		(
			#"{"oauth":{"access":"test-access","refresh":"test-refresh"}}"#,
			#"{"credential":{"oauth":{"refresh":"test-refresh","access":"test-access"}}}"#
		),
		(
			#"{"credential":{"apiKey":{"_0":"icu-test-key"}},"athlete":"i1001","resolvedAthlete":"i1001"}"#,
			#"{"resolvedAthlete":"i1001","athlete":"i1001","credential":{"apiKey":{"_0":"icu-test-key"}}}"#
		),
	])
	func legacyIdentityIgnoresFieldOrderAndFormat(_ first: String, _ second: String) throws {
		let phone = ICloudKeychainStore(backing: legacyIntervalsBacking(Data(first.utf8)))
		let pad = ICloudKeychainStore(backing: legacyIntervalsBacking(Data(second.utf8)))
		let connection = try #require(try phone.intervalsConnection())
		#expect(try pad.intervalsConnection() == connection)
	}
}

private func legacyIntervalsBacking(_ legacy: Data) -> FixtureSecretStoreBacking {
	FixtureSecretStoreBacking(items: [
		CredentialSlot.creditsAccount.rawValue: Data(
			#"{"appAccountToken":"11111111-2222-4333-8444-555555555555","key":"sk-or-test-credits-key"}"#
				.utf8),
		CredentialSlot.intervalsConnection.rawValue: legacy,
	])
}
