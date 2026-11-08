import SwiftUI
import UIKit

extension View {
    func interactiveBackSwipe(enabled: Bool = true) -> some View {
        background(InteractiveBackSwipeEnabler(isEnabled: enabled).frame(width: 0, height: 0))
    }
}

private struct InteractiveBackSwipeEnabler: UIViewControllerRepresentable {
    let isEnabled: Bool

    func makeUIViewController(context: Context) -> Controller {
        Controller()
    }

    func updateUIViewController(_ controller: Controller, context: Context) {
        controller.isEnabled = isEnabled
        controller.attach()
    }

    final class Controller: UIViewController, UIGestureRecognizerDelegate {
        var isEnabled = true
        private weak var previousDelegate: UIGestureRecognizerDelegate?
        private weak var attachedRecognizer: UIGestureRecognizer?

        override func viewDidAppear(_ animated: Bool) {
            super.viewDidAppear(animated)
            attach()
        }

        override func viewWillDisappear(_ animated: Bool) {
            super.viewWillDisappear(animated)
            detach()
        }

        func attach() {
            guard let recognizer = navigationController?.interactivePopGestureRecognizer else { return }
            if recognizer.delegate !== self {
                previousDelegate = recognizer.delegate
                recognizer.delegate = self
                attachedRecognizer = recognizer
            }
            recognizer.isEnabled = true
        }

        private func detach() {
            guard let recognizer = attachedRecognizer, recognizer.delegate === self else { return }
            recognizer.delegate = previousDelegate
            attachedRecognizer = nil
        }

        func gestureRecognizerShouldBegin(_ gestureRecognizer: UIGestureRecognizer) -> Bool {
            guard isEnabled, let navigationController else { return false }
            return navigationController.viewControllers.count > 1
        }

        func gestureRecognizer(
            _ gestureRecognizer: UIGestureRecognizer,
            shouldBeRequiredToFailBy otherGestureRecognizer: UIGestureRecognizer
        ) -> Bool {
            true
        }
    }
}
