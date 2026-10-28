import SwiftUI
import UIKit

struct ShareSheet: UIViewControllerRepresentable {
	let file: URL
	let finished: (String?, Bool, (any Error)?) -> Void

	func makeUIViewController(context: Context) -> UIActivityViewController {
		let controller = UIActivityViewController(activityItems: [file], applicationActivities: nil)
		controller.completionWithItemsHandler = { activity, completed, _, error in
			finished(activity?.rawValue, completed, error)
		}
		return controller
	}

	func updateUIViewController(_ controller: UIActivityViewController, context: Context) {}
}
