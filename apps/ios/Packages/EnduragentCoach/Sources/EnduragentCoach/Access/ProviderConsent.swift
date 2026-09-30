import Foundation

public struct ProviderConsent: Codable, Hashable, Sendable {
	public static let currentVersion = 1
	public let version: Int
	public let at: Date

	package init(version: Int = Self.currentVersion, at: Date) {
		self.version = version
		self.at = at
	}
}
