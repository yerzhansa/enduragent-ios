import Testing

@testable import EnduragentCoach

@Suite struct ReplyLanguageSectionTests {
	private let protected =
		"The rule covers your prose only. Leave these exactly as they are: tool arguments and every JSON field name and value, metric names and units (FTP, Fitness, Fatigue, Form, Load, Intensity, weighted average power, W/kg, bpm), memory-file section headings and the numerals inside them, compaction summary headings, plan and workout identifiers, activity names copied from the athlete's data, cited titles, and command names such as /review. Do not translate stored athlete text or rewrite historical content. Do not change numeric values, units, dates, or cited evidence because of the language."

	@Test func resolvedItalianDirectionPreservesProtectedDataContract() {
		let section = PromptAssembly.replyLanguageSection(
			.it
		)
		let expected = """
			# Reply language

			Reply in Italian (Italiano). Write every athlete-facing sentence in Italian, even when the athlete writes in another language. This rule outranks "Mirror the athlete's register": mirror register, tone, and level of detail within Italian; never mirror the language itself.

			\(protected)
			"""
		#expect(section == expected)
		#expect(section.contains("Fitness, Fatigue, Form"))
		#expect(!section.contains("CTL"))
		#expect(!section.contains("ATL"))
		#expect(!section.contains("TSB"))
	}

	@Test func everyTagUsesTheResolvedLanguage() {
		for tag in LanguageTag.contractOrder {
			let preference = PromptAssembly.replyLanguageSection(
				tag
			)

			#expect(preference.contains("Reply in \(tag.englishName) (\(tag.endonym))"))
			#expect(preference.contains(protected))
			#expect(preference.contains("Fitness, Fatigue, Form"))
		}
	}
}
