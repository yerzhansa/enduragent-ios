import Foundation

public enum Console {
	public static func say(_ text: String) throws {
		try FileHandle.standardOutput.write(contentsOf: Data("\(text)\n".utf8))
	}

	public static func complain(_ text: String) throws {
		try FileHandle.standardError.write(contentsOf: Data("\(text)\n".utf8))
	}
}
