import Foundation

struct ToolFailure: Error, CustomStringConvertible {
	let description: String
}

enum Tool {
	static func output(_ name: String, _ arguments: [String]) throws -> String {
		let pipe = Pipe()
		let process = Process()
		process.executableURL = URL(fileURLWithPath: "/usr/bin/env")
		process.arguments = [name] + arguments
		process.standardInput = FileHandle.nullDevice
		process.standardOutput = pipe
		try process.run()
		let data = try pipe.fileHandleForReading.readToEnd() ?? Data()
		process.waitUntilExit()
		guard process.terminationReason == .exit, process.terminationStatus == 0 else {
			throw ToolFailure(description: "\(name) exited \(process.terminationStatus)")
		}
		return String(decoding: data, as: UTF8.self)
	}
}
