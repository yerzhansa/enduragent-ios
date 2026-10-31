import EnduragentCoach

extension ShellModel {
	func deleteEverything() async {
		await yourData.begin()
		guard yourData.isErasing else { return }
		route = .erasing
		await yourData.run()
	}

	func cancelErasure() {
		yourData.cancel()
		route = .loading
		updateRoute()
	}
}
