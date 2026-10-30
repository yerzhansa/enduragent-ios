import Foundation

public enum ErasureMarker: String, Sendable, Equatable {
	case started
	case creditsErased
	case iCloudPending
}

public struct DeviceDefaults: Sendable {
	private static let namespace = "enduragent."
	private static let erasureKey = "enduragent.erasure"
	private let suiteName: String?

	public init(suiteName: String?) {
		self.suiteName = suiteName
	}

	private var defaults: UserDefaults {
		guard let defaults = UserDefaults(suiteName: suiteName) else {
			preconditionFailure("The defaults suite \(suiteName ?? "standard") cannot be opened")
		}
		return defaults
	}

	public var erasure: ErasureMarker? {
		defaults.string(forKey: Self.erasureKey).flatMap(ErasureMarker.init(rawValue:))
	}

	func mark(_ marker: ErasureMarker?) {
		if let marker {
			defaults.set(marker.rawValue, forKey: Self.erasureKey)
		} else {
			defaults.removeObject(forKey: Self.erasureKey)
		}
	}

	func erase(keeping marker: ErasureMarker?) {
		for key in defaults.dictionaryRepresentation().keys
		where key.hasPrefix(Self.namespace) && key != Self.erasureKey {
			defaults.removeObject(forKey: key)
		}
		mark(marker)
	}
}
