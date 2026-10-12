import XCTest

@MainActor
final class ConnectIntervalsProof: XCTestCase {
	func testConnectIntervals() {
		OnboardingConnectionProofScreen.resultMatrix(self)
	}

	func testConnectLaterWithLatinKeyboard() {
		OnboardingConnectionProofScreen.connectLater(self)
	}
}
