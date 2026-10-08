import Foundation

@main
struct GenerateCatalogsCommand {
	static func main() throws {
		let root = URL(fileURLWithPath: FileManager.default.currentDirectoryPath, isDirectory: true)
		do {
			let summary = try CatalogGenerator(root: root).generate()
			try FileHandle.standardOutput.write(contentsOf: Data("\(summary)\n".utf8))
		} catch {
			try FileHandle.standardError.write(
				contentsOf: Data("generate-catalogs: \(error)\n".utf8))
			exit(1)
		}
	}
}
