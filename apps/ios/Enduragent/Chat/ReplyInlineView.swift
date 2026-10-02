import EnduragentCoach
import SwiftUI

struct ReplyInlineView: View {
	let runs: [ReplyRun]
	var font: Font = .body

	var body: some View {
		Text(Self.attributed(runs, font: font))
			.fixedSize(horizontal: false, vertical: true)
	}

	static func attributed(_ runs: [ReplyRun], font: Font = .body) -> AttributedString {
		var result = AttributedString()
		for run in runs {
			switch run {
			case .text(let text):
				result.append(attributed(text, font: font))
			case .literal(let source):
				var literal = AttributedString(source)
				literal.font = font
				result.append(literal)
			case .link(let label, let target):
				for text in label {
					var linked = attributed(text, font: font)
					linked.link = target.url
					result.append(linked)
				}
			}
		}
		return result
	}

	private static func attributed(_ text: StyledText, font: Font) -> AttributedString {
		var result = AttributedString(text.text)
		var styledFont = text.styles.contains(.inlineCode) ? font.monospaced() : font
		if text.styles.contains(.bold) { styledFont = styledFont.bold() }
		if text.styles.contains(.italic) { styledFont = styledFont.italic() }
		result.font = styledFont
		if text.styles.contains(.strikethrough) { result.strikethroughStyle = .single }
		if text.styles.contains(.inlineCode) {
			result.backgroundColor = Color.primary.opacity(0.06)
		}
		return result
	}
}
