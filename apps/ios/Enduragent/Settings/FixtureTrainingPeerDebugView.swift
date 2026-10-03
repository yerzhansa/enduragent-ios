#if DEBUG
	import EnduragentCoachFixtures
	import SwiftUI

	struct FixtureTrainingPeerDebugView: View {
		let peer: FixtureTrainingPeer
		@State private var receipt = "waiting"
		@State private var failure: String?

		var body: some View {
			Button("Peer replaces with athlete A") { replace(.athleteA) }
				.accessibilityIdentifier("fixture.peerA")
			Button("Peer replaces with athlete B") { replace(.athleteB) }
				.accessibilityIdentifier("fixture.switchAthlete")
			Button("Peer rotates athlete A's key") { replace(.rotatedA) }
				.accessibilityIdentifier("fixture.peerRotateA")
			Button("Peer replaces with rejected key") { replace(.rejected) }
				.accessibilityIdentifier("fixture.peerReject")
			Button("Peer replaces with unavailable identity") { replace(.unavailable) }
				.accessibilityIdentifier("fixture.peerUnavailable")
			Button("Peer deletes training key") {
				do { try peer.delete() } catch { failure = String(describing: error) }
			}
			.accessibilityIdentifier("fixture.peerDelete")
			Button("Hold next athlete A profile read") { peer.holdNextProfile() }
				.accessibilityIdentifier("fixture.peerHoldProfile")
			Button("Release held profile read") { Task { await peer.releaseProfile() } }
				.accessibilityIdentifier("fixture.peerReleaseProfile")
			Text("Peer training receipts")
				.accessibilityIdentifier("fixture.peerReceipt")
				.accessibilityValue(receipt)
				.task { await observeReceipt() }
			if let failure { Text(failure).accessibilityIdentifier("fixture.peerFailure") }
		}

		private func replace(_ key: FixtureTrainingPeer.Key) {
			do { try peer.replace(key) } catch { failure = String(describing: error) }
		}

		private func observeReceipt() async {
			do {
				while !Task.isCancelled {
					receipt = try peer.report()
					try await Task.sleep(for: .seconds(1))
				}
			} catch is CancellationError {
			} catch { failure = String(describing: error) }
		}
	}
#endif
