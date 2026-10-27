import Foundation

package struct ShareFolder: Sendable {
	package let directory: URL

	package init(in temporary: URL) {
		directory = temporary.appending(path: "EnduragentDiagnostics", directoryHint: .isDirectory)
	}

	package func sweep() throws {
		let entries: [URL]
		do {
			entries = try FileManager.default.contentsOfDirectory(
				at: directory, includingPropertiesForKeys: nil)
		} catch let error as CocoaError where error.code == .fileReadNoSuchFile {
			return
		}
		for entry in entries {
			try FileManager.default.removeItem(at: entry)
		}
	}

	package func write(_ data: Data, named name: String, id: ULID) throws -> DiagnosticsFileHandle {
		let folder = directory.appending(path: id.rawValue, directoryHint: .isDirectory)
		try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
		let file = folder.appending(path: name, directoryHint: .notDirectory)
		try data.write(to: file, options: .atomic)
		return DiagnosticsFileHandle(url: file, id: id)
	}

	package func remove(_ handle: DiagnosticsFileHandle) throws {
		try FileManager.default.removeItem(at: handle.url.deletingLastPathComponent())
	}
}

package enum DiagnosticsFileState: Sendable, Equatable {
	case idle
	case preparing
	case ready(DiagnosticsFileHandle)
	case shared
	case saved
	case canceled
	case failed(DiagnosticsFileFailure)
}

package struct DiagnosticsFileHandle: Sendable, Equatable {
	package let url: URL
	package let id: ULID
}

package enum DiagnosticsFileFailure: String, Sendable, Equatable, Codable {
	case couldNotWrite
	case shareFailed
}

package enum ShareOutcome: Sendable, Equatable {
	case saved
	case shared
	case canceled
	case failed

	package static let saveToFilesActivity = "com.apple.DocumentManagerUICore.SaveToFiles"

	package static func of(activityType: String?, completed: Bool, error: (any Error)?)
		-> ShareOutcome
	{
		if error != nil { return .failed }
		guard completed else { return .canceled }
		return activityType == saveToFilesActivity ? Self.saved : Self.shared
	}

	package var state: DiagnosticsFileState {
		switch self {
		case .saved: .saved
		case ShareOutcome.shared: DiagnosticsFileState.shared
		case .canceled: .canceled
		case .failed: .failed(.shareFailed)
		}
	}
}
