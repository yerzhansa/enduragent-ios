import Foundation

public enum CreditsRecordFate: String, Sendable, Equatable {
	case erased
	case kept
}

package enum ICloudErasure: String, Sendable, Equatable {
	case notErased
	case erasedUnconfirmed
	case confirmed
}

package struct LocalErasure: Sendable, Equatable {
	var credits: CreditsRecordFate
	var iCloud: ICloudErasure
}

package enum ErasureProgress: Sendable, Equatable {
	case askingCredits
	case erasingLocally(LocalErasure)
}

public struct ErasureRun: Sendable, Equatable {
	let progress: ErasureProgress
	let began: Date
	let device: DeviceDefaults
}

package enum ErasureMarker: Sendable, Equatable {
	case running(ErasureProgress, began: Date)
	case iCloudPending(began: Date)
}

public struct DeviceDefaults: Sendable, Equatable {
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

	public var erasureRun: ErasureRun? {
		guard case .running(let progress, let began)? = erasure else { return nil }
		return ErasureRun(progress: progress, began: began, device: self)
	}

	package var erasure: ErasureMarker? {
		defaults.dictionary(forKey: Self.erasureKey).flatMap(ErasureMarker.init(stored:))
	}

	func mark(_ marker: ErasureMarker?) {
		if let marker {
			defaults.set(marker.stored, forKey: Self.erasureKey)
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

extension ErasureMarker {
	private enum Field {
		static let step = "step"
		static let credits = "credits"
		static let iCloud = "iCloud"
		static let began = "began"
	}

	private enum Step: String {
		case askingCredits
		case erasingLocally
		case iCloudPending
	}

	init?(stored: [String: Any]) {
		guard let began = stored[Field.began] as? Date,
			let step = (stored[Field.step] as? String).flatMap(Step.init(rawValue:))
		else { return nil }
		switch step {
		case .askingCredits:
			self = .running(.askingCredits, began: began)
		case .iCloudPending:
			self = .iCloudPending(began: began)
		case .erasingLocally:
			guard
				let credits = (stored[Field.credits] as? String).flatMap(
					CreditsRecordFate.init(rawValue:)),
				let iCloud = (stored[Field.iCloud] as? String).flatMap(
					ICloudErasure.init(rawValue:))
			else { return nil }
			self = .running(
				.erasingLocally(LocalErasure(credits: credits, iCloud: iCloud)), began: began)
		}
	}

	var stored: [String: Any] {
		switch self {
		case .running(.askingCredits, let began):
			[Field.step: Step.askingCredits.rawValue, Field.began: began]
		case .running(.erasingLocally(let local), let began):
			[
				Field.step: Step.erasingLocally.rawValue, Field.began: began,
				Field.credits: local.credits.rawValue, Field.iCloud: local.iCloud.rawValue,
			]
		case .iCloudPending(let began):
			[Field.step: Step.iCloudPending.rawValue, Field.began: began]
		}
	}
}
