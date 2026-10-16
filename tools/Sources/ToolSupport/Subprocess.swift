import Foundation
import os

public protocol DescribedFailure: LocalizedError, CustomStringConvertible {}

extension DescribedFailure {
	public var errorDescription: String? { description }
}

public struct SubprocessFailure: DescribedFailure {
	public let description: String

	public init(description: String) {
		self.description = description
	}
}

public struct SubprocessEnd: Sendable {
	public let status: Int32?
	public let signal: String?

	public var succeeded: Bool { status == 0 }

	public var statusText: String { status.map(String.init) ?? "null" }

	public var signalText: String { signal ?? "null" }
}

public struct Subprocess {
	public enum Stream {
		case discarded
		case file(FileHandle)
	}

	public let directory: String?
	public let environment: [String: String]?

	public init(directory: String? = nil, environment: [String: String]? = nil) {
		self.directory = directory
		self.environment = environment
	}

	public func start(_ command: String, _ arguments: [String], output: Stream) throws -> Process {
		switch output {
		case .discarded:
			try launch(
				command, arguments, output: FileHandle.nullDevice, errors: FileHandle.nullDevice)
		case .file(let handle):
			try launch(command, arguments, output: handle, errors: handle)
		}
	}

	public func run(_ command: String, _ arguments: [String], output: Stream) throws
		-> SubprocessEnd
	{
		let process = try start(command, arguments, output: output)
		process.waitUntilExit()
		return Self.end(of: process)
	}

	public func logged(
		_ log: String, _ command: String, _ arguments: [String], exclusive: Bool = false
	)
		throws -> SubprocessEnd
	{
		let descriptor = open(log, O_WRONLY | O_CREAT | (exclusive ? O_EXCL : O_TRUNC), 0o644)
		guard descriptor >= 0 else { throw FileFailure(code: errno, path: log) }
		let handle = FileHandle(fileDescriptor: descriptor, closeOnDealloc: false)
		defer { close(descriptor) }
		return try run(command, arguments, output: .file(handle))
	}

	public func capture(_ command: String, _ arguments: [String]) throws -> String {
		let captured = try collect(command, arguments)
		guard captured.end.succeeded else {
			let line = ([command] + arguments).joined(separator: " ")
			let errors = String(decoding: captured.errors, as: UTF8.self)
			throw SubprocessFailure(
				description: "Command failed: \(line)" + (errors.isEmpty ? "" : "\n\(errors)"))
		}
		return String(decoding: captured.output, as: UTF8.self).trimmedAsJavaScript
	}

	public func printed(_ command: String, _ arguments: [String]) throws -> String {
		let output = Pipe()
		let process = try launch(
			command, arguments, output: output, errors: FileHandle.standardError)
		let printed = try output.fileHandleForReading.readToEnd() ?? Data()
		process.waitUntilExit()
		let end = Self.end(of: process)
		guard end.succeeded else {
			throw SubprocessFailure(description: "\(command) exited \(end.statusText)")
		}
		return String(decoding: printed, as: UTF8.self)
	}

	public func collect(_ command: String, _ arguments: [String]) throws -> (
		end: SubprocessEnd, output: Data, errors: Data
	) {
		let output = Pipe()
		let errors = Pipe()
		let process = try launch(command, arguments, output: output, errors: errors)
		let collectedErrors = OSAllocatedUnfairLock(
			initialState: Result<Data, Error>.success(Data()))
		let finishedReading = DispatchSemaphore(value: 0)
		let errorReader = errors.fileHandleForReading
		Thread {
			let read = Result { try errorReader.readToEnd() ?? Data() }
			collectedErrors.withLock { $0 = read }
			finishedReading.signal()
		}.start()
		let printed = try output.fileHandleForReading.readToEnd() ?? Data()
		finishedReading.wait()
		process.waitUntilExit()
		return (Self.end(of: process), printed, try collectedErrors.withLock { $0 }.get())
	}

	private func launch(_ command: String, _ arguments: [String], output: Any, errors: Any) throws
		-> Process
	{
		let process = Process()
		process.executableURL = URL(fileURLWithPath: "/usr/bin/env")
		process.arguments = [command] + arguments
		if let directory { process.currentDirectoryURL = URL(fileURLWithPath: directory) }
		if let environment { process.environment = environment }
		process.standardInput = FileHandle.nullDevice
		process.standardOutput = output
		process.standardError = errors
		try process.run()
		return process
	}

	public static func end(of process: Process) -> SubprocessEnd {
		guard process.terminationReason == .uncaughtSignal else {
			return SubprocessEnd(status: process.terminationStatus, signal: nil)
		}
		return SubprocessEnd(status: nil, signal: signalName(process.terminationStatus))
	}

	private static func signalName(_ number: Int32) -> String {
		let name = withUnsafeBytes(of: sys_signame) { names in
			let known = names.bindMemory(to: UnsafePointer<CChar>?.self)
			return known.indices.contains(Int(number)) ? known[Int(number)] : nil
		}
		return "SIG" + (name.map { String(cString: $0).uppercased() } ?? String(number))
	}
}

public enum Checkout {
	public static func root(ofExecutable path: String) throws -> String {
		let resolved = try FileSystem.realPath(path)
		let segments = NodePath.segments(resolved)
		guard
			let build = segments.indices.last(where: {
				$0 > 0 && segments[$0].hasSameUnits(as: ".build")
					&& segments[$0 - 1].hasSameUnits(as: "tools")
			})
		else {
			throw SubprocessFailure(
				description:
					"\(resolved) is outside tools/.build; run it with swift run --package-path tools"
			)
		}
		return "/" + segments[..<(build - 1)].filter { !$0.isEmpty }.joined(separator: "/")
	}
}

public enum Console {
	public static func text(of error: Error) -> String {
		error.localizedDescription
	}

	public static func say(_ text: String) throws {
		try FileHandle.standardOutput.write(contentsOf: Data("\(text)\n".utf8))
	}

	public static func complain(_ text: String) throws {
		try FileHandle.standardError.write(contentsOf: Data("\(text)\n".utf8))
	}
}
