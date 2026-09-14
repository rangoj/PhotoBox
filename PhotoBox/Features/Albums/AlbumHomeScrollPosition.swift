import SwiftUI
import UIKit

@MainActor
final class AlbumHomeScrollPosition {
    private weak var scrollView: UIScrollView?
    private var observations: [NSKeyValueObservation] = []
    private var savedContentOrigin: CGFloat?
    private var capturedForNavigation = false
    private var restoring = false
    private var applyingOffset = false
    private var savedBottomInset: CGFloat = 0
    private var hasAppeared = false

    func captureForNavigation() {
        guard let scrollView, let window = scrollView.window else { return }
        savedContentOrigin = scrollView.convert(.zero, to: window).y
        savedBottomInset = scrollView.adjustedContentInset.bottom
        capturedForNavigation = true
    }

    fileprivate func attach(from view: UIView) {
        var ancestor = view.superview
        while let candidate = ancestor {
            if let scrollView = candidate as? UIScrollView {
                if self.scrollView !== scrollView {
                    self.scrollView = scrollView
                    observations = [
                        scrollView.observe(\.contentOffset, options: [.new]) { [weak self] _, _ in
                            MainActor.assumeIsolated { self?.restoreIfNeeded() }
                        },
                        scrollView.observe(\.bounds, options: [.new]) { [weak self] _, _ in
                            MainActor.assumeIsolated { self?.restoreIfNeeded() }
                        },
                        scrollView.observe(\.adjustedContentInset, options: [.new]) { [weak self] _, _ in
                            MainActor.assumeIsolated { self?.restoreIfNeeded() }
                        },
                        scrollView.observe(\.contentSize, options: [.new]) { [weak self] _, _ in
                            MainActor.assumeIsolated { self?.restoreIfNeeded() }
                        }
                    ]
                }
                restoreIfNeeded()
                return
            }
            ancestor = candidate.superview
        }
    }

    fileprivate func willAppear() {
        hasAppeared = false
        restoring = savedContentOrigin != nil
        restoreIfNeeded()
    }

    fileprivate func didAppear() {
        hasAppeared = true
        restoreIfNeeded()
        capturedForNavigation = false
    }

    fileprivate func willDisappear() {
        if !capturedForNavigation { captureForNavigation() }
        restoring = false
    }

    private func restoreIfNeeded() {
        guard restoring, !applyingOffset, let savedContentOrigin,
              let scrollView, let window = scrollView.window else { return }
        guard !scrollView.isTracking, !scrollView.isDragging else {
            restoring = false
            return
        }

        // Tab/navigation bars change the viewport during a pop. Preserve the content's window position.
        let delta = scrollView.convert(.zero, to: window).y - savedContentOrigin
        let minimumOffset = -scrollView.adjustedContentInset.top
        let maximumOffset = max(minimumOffset, scrollView.contentSize.height - scrollView.bounds.height
                                + scrollView.adjustedContentInset.bottom)
        let target = min(maximumOffset, max(minimumOffset, scrollView.contentOffset.y + delta))
        if abs(target - scrollView.contentOffset.y) > 0.5 {
            applyingOffset = true
            scrollView.setContentOffset(CGPoint(x: scrollView.contentOffset.x, y: target), animated: false)
            applyingOffset = false
        }
        // SwiftUI can restore the tab-bar inset after viewDidAppear. Keep observing that transition.
        if hasAppeared && scrollView.adjustedContentInset.bottom >= savedBottomInset - 0.5 {
            restoring = false
        }
    }
}

struct AlbumHomeScrollPositionProbe: UIViewControllerRepresentable {
    let position: AlbumHomeScrollPosition

    func makeUIViewController(context: Context) -> AlbumHomeScrollPositionController {
        AlbumHomeScrollPositionController(position: position)
    }

    func updateUIViewController(_ controller: AlbumHomeScrollPositionController, context: Context) {
        controller.position.attach(from: controller.view)
    }
}

final class AlbumHomeScrollPositionController: UIViewController {
    let position: AlbumHomeScrollPosition

    init(position: AlbumHomeScrollPosition) {
        self.position = position
        super.init(nibName: nil, bundle: nil)
    }

    required init?(coder: NSCoder) { return nil }

    override func loadView() {
        view = UIView()
        view.isUserInteractionEnabled = false
        view.accessibilityElementsHidden = true
    }

    override func viewWillAppear(_ animated: Bool) {
        super.viewWillAppear(animated)
        position.attach(from: view)
        position.willAppear()
    }

    override func viewDidAppear(_ animated: Bool) {
        super.viewDidAppear(animated)
        position.attach(from: view)
        position.didAppear()
    }

    override func viewWillDisappear(_ animated: Bool) {
        position.willDisappear()
        super.viewWillDisappear(animated)
    }

    override func viewDidLayoutSubviews() {
        super.viewDidLayoutSubviews()
        position.attach(from: view)
    }
}
