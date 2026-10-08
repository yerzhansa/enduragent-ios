import Foundation

public struct FileFailure: DescribedFailure {
	public let code: Int32
	public let path: String

	public init(code: Int32, path: String) {
		self.code = code
		self.path = path
	}

	public var description: String { "\(String(cString: strerror(code))): \(path)" }
}

public enum NodePath {
	public static func segments(_ path: String) -> [String] {
		path.utf8.split(separator: UInt8(ascii: "/"), omittingEmptySubsequences: false).map {
			String(decoding: $0, as: UTF8.self)
		}
	}

	public static func isAbsolute(_ path: String) -> Bool {
		path.utf8.first == UInt8(ascii: "/")
	}

	public static func resolve(_ base: String, _ parts: String...) -> String {
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

	public static func join(_ parts: String...) -> String {
		let joined = parts.filter { !$0.isEmpty }.joined(separator: "/")
		var kept: [String] = []
		for segment in segments(joined) where !segment.isEmpty && !segment.hasSameUnits(as: ".") {
			if segment.hasSameUnits(as: ".."), let last = kept.last, !last.hasSameUnits(as: "..") {
				kept.removeLast()
			} else if !segment.hasSameUnits(as: "..") || !isAbsolute(joined) {
				kept.append(segment)
			}
		}
		let path = kept.joined(separator: "/")
		return isAbsolute(joined) ? "/" + path : path.isEmpty ? "." : path
	}

	public static func basename(_ path: String) -> String {
		segments(path).last ?? ""
	}

	public static func dirname(_ path: String) -> String {
		"/" + segments(path).dropLast().filter { !$0.isEmpty }.joined(separator: "/")
	}
}

public enum FileSystem {
	public static func realPath(_ path: String) throws -> String {
		guard let resolved = realpath(path, nil) else { throw FileFailure(code: errno, path: path) }
		defer { free(resolved) }
		return String(cString: resolved)
	}

	public static func isSymbolicLink(_ path: String) throws -> Bool {
		var status = stat()
		guard lstat(path, &status) == 0 else { throw FileFailure(code: errno, path: path) }
		return status.st_mode & S_IFMT == S_IFLNK
	}

	public static func linkTarget(_ path: String) throws -> String {
		try FileManager.default.destinationOfSymbolicLink(atPath: path)
	}

	public static func read(_ path: String) throws -> Data {
		try Data(contentsOf: URL(fileURLWithPath: path))
	}
}
