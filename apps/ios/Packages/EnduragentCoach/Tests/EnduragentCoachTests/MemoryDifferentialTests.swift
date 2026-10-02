import Testing

@testable import EnduragentCoach

@Suite struct MemoryDifferentialTests {
	@Test func copiedQueryStringsMatchDesktop() {
		#expect(
			MemoryQuery.render([], from: "1998-06-01", to: "1998-06-30")
				== "Memory query 1998-06-01..1998-06-30: no daily notes, events, or history found."
		)
		#expect(
			MemoryQuery.truncationNotice
				== "[truncated — narrow the date range or add a query term]")
		#expect(MemoryQuery.emptySuffix == ": no daily notes, events, or history found.")
	}

}
