import Foundation
import Testing

@testable import EnduragentCoach

@Suite
struct DisplayZonesTests {
	@Test func ftpOutsideRangeThrows() {
		#expect(throws: IntervalsError.self) {
			_ = try DisplayZones.table(ftpWatts: 49)
		}
		#expect(throws: IntervalsError.self) {
			_ = try DisplayZones.table(ftpWatts: 601)
		}
	}
}
