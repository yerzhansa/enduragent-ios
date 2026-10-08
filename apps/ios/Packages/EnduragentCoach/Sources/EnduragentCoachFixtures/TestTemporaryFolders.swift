import Darwin
import Foundation

public final class TestTemporaryFolders: Sendable {
	private static let prefix = "enduragent-test-process-"
	private static let shared = Result {
		try TestTemporaryFolders(parent: FileManager.default.temporaryDirectory)
	}
	private let directory: URL
	private let owner: FileHandle

	public static func make() throws -> URL {
		try shared.get().nextDirectory()
	}

	package init(parent: URL) throws {
		let coordination = try Self.open(
			parent.appending(path: ".enduragent-test-process.lock"), flags: O_RDWR | O_CREAT)
		guard flock(coordination.fileDescriptor, LOCK_EX) == 0 else { throw Self.systemError() }
		let name = "\(Self.prefix)\(getpid())-\(UUID().uuidString)"
		directory = parent.appending(path: name, directoryHint: .isDirectory)
		owner = try Self.open(Self.marker(for: directory), flags: O_RDWR | O_CREAT | O_EXCL)
		guard flock(owner.fileDescriptor, LOCK_EX) == 0 else { throw Self.systemError() }
		try owner.write(contentsOf: Data(name.utf8))
		try FileManager.default.createDirectory(
			at: directory, withIntermediateDirectories: false,
			attributes: [.posixPermissions: 0o700])
		try withExtendedLifetime(coordination) {
			try Self.removeEndedRoots(in: parent)
		}
	}

	package func nextDirectory() -> URL {
		directory.appending(path: UUID().uuidString, directoryHint: .isDirectory)
	}

	private static func removeEndedRoots(in parent: URL) throws {
		let files = FileManager.default
		let roots = try files.contentsOfDirectory(
			at: parent, includingPropertiesForKeys: [.isDirectoryKey, .isSymbolicLinkKey])
		for root in roots {
			let name = root.lastPathComponent
			guard name.hasPrefix(prefix) else { continue }
			let identity = name.dropFirst(prefix.count).split(separator: "-", maxSplits: 1)
			guard identity.count == 2, let process = Int32(identity[0]), process > 0,
				UUID(uuidString: String(identity[1])) != nil
			else { continue }
			let kind = try root.resourceValues(forKeys: [.isDirectoryKey, .isSymbolicLinkKey])
			guard kind.isDirectory == true, kind.isSymbolicLink != true else { continue }
			let marker: FileHandle
			do {
				marker = try open(Self.marker(for: root), flags: O_RDONLY)
			} catch let error as POSIXError where error.code == .ENOENT || error.code == .ELOOP {
				continue
			}
			var status = stat()
			guard fstat(marker.fileDescriptor, &status) == 0 else { throw systemError() }
			guard status.st_mode & S_IFMT == S_IFREG else { continue }
			if flock(marker.fileDescriptor, LOCK_EX | LOCK_NB) != 0 {
				guard errno == EWOULDBLOCK else { throw systemError() }
				continue
			}
			try withExtendedLifetime(marker) {
				guard try marker.read(upToCount: name.utf8.count + 1) == Data(name.utf8) else {
					return
				}
				try files.removeItem(at: root)
				try files.removeItem(at: Self.marker(for: root))
			}
		}
	}

	private static func marker(for root: URL) -> URL {
		root.deletingLastPathComponent().appending(path: ".\(root.lastPathComponent).owner")
	}

	private static func open(_ url: URL, flags: Int32) throws -> FileHandle {
		let descriptor = Darwin.open(url.path, flags | O_NOFOLLOW | O_CLOEXEC | O_NONBLOCK, 0o600)
		guard descriptor >= 0 else { throw systemError() }
		return FileHandle(fileDescriptor: descriptor, closeOnDealloc: true)
	}

	private static func systemError() -> POSIXError {
		POSIXError(POSIXErrorCode(rawValue: errno) ?? .EIO)
	}
}
