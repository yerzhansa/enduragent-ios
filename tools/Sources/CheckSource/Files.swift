import Foundation

struct FileFailure: Error, CustomStringConvertible {
	let code: Int32
	let path: String

	var description: String { "\(String(cString: strerror(code))): \(path)" }
}

struct ToolFailure: Error, CustomStringConvertible {
	let description: String
}

enum NodePath {
	static func segments(_ path: String) -> [String] {
		path.utf8.split(separator: UInt8(ascii: "/"), omittingEmptySubsequences: false).map {
			String(decoding: $0, as: UTF8.self)
		}
	}

	static func isAbsolute(_ path: String) -> Bool {
		path.utf8.first == UInt8(ascii: "/")
	}

	static func resolve(_ base: String, _ parts: String...) -> String {
		var resolved: [String] = []
		for part in [base] + parts {
			if isAbsolute(part) { resolved = [] }
			for segment in segments(part) where !segment.isEmpty && !segment.hasSameUnits(as: ".") {
				if segment.hasSameUnits(as: "..") {
					_ = resolved.popLast()
				} else {
					resolved.append(segment)
				}
			}
		}
		return "/" + resolved.joined(separator: "/")
	}

	static func basename(_ path: String) -> String {
		segments(path).last ?? ""
	}

	static func dirname(_ path: String) -> String {
		"/" + segments(path).dropLast().filter { !$0.isEmpty }.joined(separator: "/")
	}
}

enum FileSystem {
	static func realPath(_ path: String) throws -> String {
		guard let resolved = realpath(path, nil) else { throw FileFailure(code: errno, path: path) }
		defer { free(resolved) }
		return String(cString: resolved)
	}

	static func isSymbolicLink(_ path: String) throws -> Bool {
		var status = stat()
		guard lstat(path, &status) == 0 else { throw FileFailure(code: errno, path: path) }
		return status.st_mode & S_IFMT == S_IFLNK
	}

	static func linkTarget(_ path: String) throws -> String {
		try FileManager.default.destinationOfSymbolicLink(atPath: path)
	}

	static func read(_ path: String) throws -> Data {
		try Data(contentsOf: URL(fileURLWithPath: path))
	}
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
