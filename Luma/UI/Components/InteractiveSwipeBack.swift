import SwiftUI

#if os(iOS) || os(visionOS)
import UIKit

extension View {
    /// Re-enables iOS's native interactive swipe-back on a pushed view whose
    /// back button is hidden. Hiding the back button (or the whole bar) disables
    /// `interactivePopGestureRecognizer`; installing a permissive delegate brings
    /// it back — giving the real interactive transition that reveals the previous
    /// screen as you drag (not an abrupt jump).
    func interactiveSwipeBack() -> some View {
        background(SwipeBackEnabler())
    }
}

private struct SwipeBackEnabler: UIViewControllerRepresentable {
    func makeUIViewController(context: Context) -> Controller {
        let controller = Controller()
        controller.coordinator = context.coordinator
        return controller
    }

    func updateUIViewController(_ uiViewController: Controller, context: Context) {
        uiViewController.enableSwipeBack()
    }

    func makeCoordinator() -> Coordinator { Coordinator() }

    final class Coordinator: NSObject, UIGestureRecognizerDelegate {
        weak var navigationController: UINavigationController?

        func gestureRecognizerShouldBegin(_ gestureRecognizer: UIGestureRecognizer) -> Bool {
            (navigationController?.viewControllers.count ?? 0) > 1
        }
    }

    final class Controller: UIViewController {
        weak var coordinator: Coordinator?

        override func viewDidLoad() {
            super.viewDidLoad()
            view.backgroundColor = .clear
        }

        override func viewWillAppear(_ animated: Bool) {
            super.viewWillAppear(animated)
            enableSwipeBack()
        }

        override func didMove(toParent parent: UIViewController?) {
            super.didMove(toParent: parent)
            enableSwipeBack()
        }

        func enableSwipeBack() {
            // The navigation controller may not be wired up on the first call.
            DispatchQueue.main.async { [weak self] in
                guard let self,
                      let coordinator = self.coordinator,
                      let nav = self.resolveNavigationController() else { return }
                coordinator.navigationController = nav
                nav.interactivePopGestureRecognizer?.isEnabled = true
                nav.interactivePopGestureRecognizer?.delegate = coordinator
            }
        }

        private func resolveNavigationController() -> UINavigationController? {
            if let nav = navigationController { return nav }
            var ancestor = parent
            while let current = ancestor {
                if let nav = current as? UINavigationController { return nav }
                ancestor = current.parent
            }
            return view.window?.rootViewController?.firstNavigationController()
        }
    }
}

private extension UIViewController {
    func firstNavigationController() -> UINavigationController? {
        if let nav = self as? UINavigationController { return nav }
        for child in children {
            if let nav = child.firstNavigationController() { return nav }
        }
        if let presented = presentedViewController {
            return presented.firstNavigationController()
        }
        return nil
    }
}
#else
extension View {
    func interactiveSwipeBack() -> some View { self }
}
#endif
