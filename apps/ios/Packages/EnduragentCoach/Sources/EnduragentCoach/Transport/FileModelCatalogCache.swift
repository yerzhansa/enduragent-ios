import Foundation

package protocol ModelCatalogCache: Sendable {
	func load() throws -> ModelCatalog?
	func replaceAtomically(_ catalog: ModelCatalog) throws
}

package struct FileModelCatalogCache: ModelCatalogCache {
	private let file: URL

	package init(directory: URL) {
		file = directory.appending(path: "model-catalog.json")
	}

	package func load() throws -> ModelCatalog? {
		do {
			return try ModelCatalog(validating: Data(contentsOf: file))
		} catch let error as CocoaError where error.code == .fileReadNoSuchFile {
			return nil
		}
	}

	package func replaceAtomically(_ catalog: ModelCatalog) throws {
		try FileManager.default.createDirectory(
			at: file.deletingLastPathComponent(), withIntermediateDirectories: true)
		try catalog.encoded().write(to: file, options: .atomic)
	}
}
