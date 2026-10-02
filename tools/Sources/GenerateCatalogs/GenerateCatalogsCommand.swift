import Foundation
import ToolSupport

@main
struct GenerateCatalogsCommand {
	static func main() throws {
		let root = URL(fileURLWithPath: FileManager.default.currentDirectoryPath, isDirectory: true)
		do {
			try Console.say(try CatalogGenerator(root: root).generate())
		} catch {
			try Console.complain("generate-catalogs: \(error)")
			exit(1)
		}
	}
}
