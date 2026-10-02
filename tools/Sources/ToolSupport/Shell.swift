import Foundation

public struct ShellFailure: Error, CustomStringConvertible {
	public let description: String
}

public enum Shell {
	public static func output(_ command: String, _ arguments: [String]) throws -> String {
		let pipe = Pipe()
		let process = try start(command, arguments, output: pipe, errors: FileHandle.standardError)
		let data = try pipe.fileHandleForReading.readToEnd() ?? Data()
		process.waitUntilExit()
		guard process.terminationStatus == 0 else {
			throw ShellFailure(
				description: "\(line(command, arguments)) exited \(process.terminationStatus)")
		}
		guard let text = String(validating: data, as: UTF8.self) else {
			throw ShellFailure(description: "\(line(command, arguments)) printed invalid UTF-8")
		}
		return text
	}

	public static func status(_ command: String, _ arguments: [String]) throws -> Int32 {
		let process = try start(
			command, arguments, output: FileHandle.nullDevice, errors: FileHandle.nullDevice)
		process.waitUntilExit()
		return process.terminationStatus
	}

	public static func status(_ command: String, _ arguments: [String], log: URL) throws -> Int32 {
		guard FileManager.default.createFile(atPath: log.path, contents: nil) else {
			throw ShellFailure(description: "cannot create \(log.path)")
		}
		let handle = try FileHandle(forWritingTo: log)
		let process: Process
		do {
			process = try start(command, arguments, output: handle, errors: handle)
		} catch {
			try handle.close()
			throw error
		}
		process.waitUntilExit()
		try handle.close()
		return process.terminationStatus
	}

	private static func start(
		_ command: String, _ arguments: [String], output: Any, errors: Any
	) throws -> Process {
		let process = Process()
		process.executableURL = URL(fileURLWithPath: "/usr/bin/env")
		process.arguments = [command] + arguments
		process.standardInput = FileHandle.nullDevice
		process.standardOutput = output
		process.standardError = errors
		try process.run()
		return process
	}

	private static func line(_ command: String, _ arguments: [String]) -> String {
		([command] + arguments).joined(separator: " ")
	}
}
