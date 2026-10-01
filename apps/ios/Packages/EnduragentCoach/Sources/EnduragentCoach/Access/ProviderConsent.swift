import Foundation

public struct ProviderConsent: Hashable, Sendable {
	public static let currentVersion = 1
	public let version: Int
	public let at: Date

	package var isCurrent: Bool { version == Self.currentVersion }

	package init(version: Int = Self.currentVersion, at: Date) {
		self.version = version
		self.at = at
	}
}
