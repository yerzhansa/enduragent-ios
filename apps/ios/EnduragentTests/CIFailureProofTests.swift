import Testing

struct CIFailureProofTests {
	@Test
	func appTestFailureFailsCI() {
		Issue.record("P01 deliberate failure proves EnduragentTests fails CI")
	}
}
