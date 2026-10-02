import Foundation

package enum TurnPolicy {
	package static let compactionTimeout: Duration = .seconds(120)
	package static let toolResultTokenCap = 24_000
	package static let athleteContextChars = 20_000
	package static let historyBudgetFloor = 8_000
	package static let contextWindowCap = 200_000
	package static let reserveTokens = 20_000
	package static let proposalTTL: Duration = .seconds(10 * 60)
	package static let ungatedPrefixTokenCeiling = 13_200
	package static let gatedPrefixTokenCeiling = 13_600
}
