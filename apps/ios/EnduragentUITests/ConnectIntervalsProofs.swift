import XCTest

@MainActor
final class ConnectIntervalsProof: XCTestCase {
	func testConnectIntervals() {
		OnboardingConnectionProofScreen.resultMatrix(self, dark: false)
	}

	func testConnectLaterWithLatinKeyboard() {
		OnboardingConnectionProofScreen.connectLater(self, dark: false)
	}
}

@MainActor
final class ConnectIntervalsDarkProof: XCTestCase {
	func testConnectIntervals() {
		OnboardingConnectionProofScreen.resultMatrix(self, dark: true)
	}

	func testConnectLaterWithLatinKeyboard() {
		OnboardingConnectionProofScreen.connectLater(self, dark: true)
	}
}
