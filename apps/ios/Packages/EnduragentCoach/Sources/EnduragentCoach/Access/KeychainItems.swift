import CryptoKit
import Foundation
import Security

package struct StoredIntervalsConnection: Codable, Equatable, Sendable {
	private enum CodingKeys: String, CodingKey {
		case id
		case credential
		case athlete
		case resolvedAthlete
	}

	package private(set) var id: UUID?
	private var credential: StoredIntervalsCredential
	private var athlete: String?
	private var resolvedAthlete: String?

	package init(_ connection: IntervalsConnection) {
		self.id = connection.id.rawValue
		self.credential = StoredIntervalsCredential(connection.credential)
		switch connection.selection {
		case .keyOwner:
			self.athlete = nil
		case .athlete(let athlete):
			self.athlete = athlete.rawValue
		}
		self.resolvedAthlete = connection.resolvedAthlete?.rawValue
	}

	package init(from decoder: any Decoder) throws {
		let container = try decoder.container(keyedBy: CodingKeys.self)
		guard container.contains(.credential) else {
			self.id = nil
			self.credential = try StoredIntervalsCredential(from: decoder)
			self.athlete = nil
			self.resolvedAthlete = nil
			return
		}
		self.id = try container.decodeIfPresent(UUID.self, forKey: .id)
		self.credential = try container.decode(StoredIntervalsCredential.self, forKey: .credential)
		self.athlete = try container.decodeIfPresent(String.self, forKey: .athlete)
		self.resolvedAthlete = try container.decodeIfPresent(String.self, forKey: .resolvedAthlete)
	}

	package func connection() throws -> IntervalsConnection {
		IntervalsConnection(
			id: try id.map(ConnectionID.init(rawValue:)) ?? legacyID(),
			credential: credential.credential,
			selection: try athlete.map { .athlete(try Self.athleteID($0)) } ?? .keyOwner,
			resolvedAthlete: try resolvedAthlete.map(Self.athleteID)
		)
	}

	private func legacyID() throws -> ConnectionID {
		let encoder = JSONEncoder()
		encoder.outputFormatting = .sortedKeys
		var input = Data("icu.enduragent.ios/intervals-connection-id/v1".utf8)
		input.append(try encoder.encode(self))
		var bytes = Array(SHA256.hash(data: input))
		bytes[6] = (bytes[6] & 0x0F) | 0x80
		bytes[8] = (bytes[8] & 0x3F) | 0x80
		return ConnectionID(
			rawValue: UUID(
				uuid: (
					bytes[0], bytes[1], bytes[2], bytes[3], bytes[4], bytes[5], bytes[6], bytes[7],
					bytes[8], bytes[9], bytes[10], bytes[11], bytes[12], bytes[13], bytes[14],
					bytes[15]
				)))
	}

	private static func athleteID(_ raw: String) throws -> IntervalsAthleteID {
		guard let athlete = IntervalsAthleteID(rawValue: raw) else {
			throw KeychainStoreError.keychain(errSecDecode)
		}
		return athlete
	}
}

package enum StoredIntervalsCredential: Codable, Equatable, Sendable {
	case apiKey(String)
	case oauth(access: String, refresh: String)

	package init(_ credential: IntervalsCredential) {
		switch credential {
		case .apiKey(let key):
			self = .apiKey(key)
		case .oauth(let access, let refresh):
			self = .oauth(access: access, refresh: refresh)
		}
	}

	package var credential: IntervalsCredential {
		switch self {
		case .apiKey(let key):
			return .apiKey(key)
		case .oauth(let access, let refresh):
			return .oauth(access: access, refresh: refresh)
		}
	}
}

package enum StoredAccessSelection: Codable, Equatable, Sendable {
	case credits
	case openRouterAccount(model: String)

	package init(_ selection: AccessSelection) {
		switch selection {
		case .credits: self = .credits
		case .openRouterAccount(let model): self = .openRouterAccount(model: model.rawValue)
		}
	}

	package func selection() -> AccessSelection {
		switch self {
		case .credits: .credits
		case .openRouterAccount(let model): .openRouterAccount(model: ModelID(rawValue: model))
		}
	}
}
