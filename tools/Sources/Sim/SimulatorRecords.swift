struct DeviceList: Decodable {
	let devices: [String: [Device]]
}

struct Device: Decodable {
	let name: String
	let udid: String
	let state: String
}

struct RuntimeList: Decodable {
	let runtimes: [Runtime]
}

struct Runtime: Decodable {
	let name: String
	let identifier: String
	let platform: String?
	let version: String
	let isAvailable: Bool
}

struct DeviceTypeList: Decodable {
	let devicetypes: [DeviceType]
}

struct DeviceType: Decodable {
	let name: String
}

struct RunRecord: Encodable {
	let id: String
	let simulator: String
	let deviceType: String
	let runtime: String
	let checkout: String
	let revision: String
	let udid: String?
}

struct TestSummary: Decodable {
	let result: String
	let passedTests: Int
	let failedTests: Int
	let skippedTests: Int
}

struct AttachmentManifestEntry: Decodable {
	let testIdentifier: String
	let attachments: [Attachment]
}

struct Attachment: Decodable {
	let suggestedHumanReadableName: String
	let exportedFileName: String
}
