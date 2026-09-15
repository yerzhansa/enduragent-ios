import SwiftUI

struct TranscriptView: View {
	var model: ShellModel

	var body: some View {
		ScrollView {
			LazyVStack(alignment: .leading, spacing: 16) {
				if showsGreeting {
					Text(model.athleteFirstName.isEmpty ? "Hello." : "Hello, \(model.athleteFirstName).")
				}
				ForEach(Array(model.seam.transcript.enumerated()), id: \.offset) { _, message in
					Text(message.text)
				}
				if !model.seam.streamingText.isEmpty {
					Text(model.seam.streamingText)
				}
				if let confirmLine = model.confirmLine {
					Text(confirmLine)
				}
			}
			.padding()
			.frame(maxWidth: .infinity, alignment: .leading)
		}
	}

	private var showsGreeting: Bool {
		model.seam.transcript.isEmpty && model.seam.streamingText.isEmpty
	}
}
