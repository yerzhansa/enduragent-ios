import Testing

@testable import EnduragentCoach

@Suite struct ViewSeamTurnTests {
	@Test func athleteLineIsVisibleBeforeAnyCoachDelta() {
		let seam = ViewSeam.empty.postingUser(
			ChatMessage(role: .user, text: "hi", civilDate: "1998-06-15")
		)
		#expect(seam.transcript == [ChatMessage(role: .user, text: "hi", civilDate: "1998-06-15")])
		#expect(seam.streamingText.isEmpty)
		#expect(seam.phase == .streaming)
	}

	@Test func coachDeltasAccumulateWithoutWaitingForFinish() {
		var seam = ViewSeam.empty.postingUser(ChatMessage(role: .user, text: "hi"))
		seam = seam.applying(.textDelta("Hel"))
		seam = seam.applying(.textDelta("lo"))
		#expect(seam.transcript.map(\.role) == [.user])
		#expect(seam.streamingText == "Hello")
		#expect(seam.phase == .streaming)
		seam = seam.applying(.finished)
		#expect(seam.streamingText == "Hello")
		#expect(seam.transcript.map(\.role) == [.user])
	}
}
