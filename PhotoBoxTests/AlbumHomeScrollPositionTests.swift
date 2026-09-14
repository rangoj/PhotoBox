import Testing
import UIKit
@testable import PhotoBox

@MainActor
struct AlbumHomeScrollPositionTests {
    @Test("A tab bar inset restored after appearance restores the bottom scroll position")
    func tabBarInsetSettlesAfterAppearance() {
        let fixture = ScrollPositionFixture()
        withExtendedLifetime(fixture.window) {
            fixture.scrollView.contentInset.bottom = 83
            fixture.scrollView.contentOffset.y = 1_583
            fixture.position.captureForNavigation()
            fixture.controller.viewWillDisappear(false)
            fixture.controller.viewWillAppear(false)
            fixture.scrollView.contentInset.bottom = 34
            fixture.scrollView.contentOffset.y = 1_534
            fixture.controller.viewDidAppear(false)
            fixture.scrollView.contentInset.bottom = 83
            #expect(fixture.scrollView.contentOffset.y == 1_583)
        }
    }

    // Production break: preserving only contentOffset lets toolbar geometry shift the visible content on return.
    @Test("Navigation restores the same content position across viewport changes")
    func navigationRestoresContentAcrossViewportChanges() {
        let fixture = ScrollPositionFixture()
        withExtendedLifetime(fixture.window) {
            fixture.scrollView.contentOffset.y = 100
            fixture.position.captureForNavigation()
            fixture.controller.viewWillDisappear(false)
            fixture.scrollView.frame.origin.y = 49
            fixture.scrollView.contentOffset.y = 0
            fixture.controller.viewWillAppear(false)
            fixture.controller.viewDidAppear(false)

            #expect(fixture.scrollView.convert(.zero, to: fixture.window).y == -100)
            #expect(fixture.scrollView.contentOffset.y == 149)
        }
    }

    // Production break: leaving without a navigation activation reuses an old visit's snapshot after a user scroll.
    @Test("A tab switch captures the current position without a navigation activation")
    func tabSwitchCapturesCurrentPosition() {
        let fixture = ScrollPositionFixture()
        withExtendedLifetime(fixture.window) {
            fixture.scrollView.contentOffset.y = 100
            fixture.position.captureForNavigation()
            fixture.controller.viewWillDisappear(false)
            fixture.controller.viewWillAppear(false)
            fixture.controller.viewDidAppear(false)

            fixture.scrollView.contentOffset.y = 350
            fixture.controller.viewWillDisappear(false)
            fixture.scrollView.contentOffset.y = 0
            fixture.controller.viewWillAppear(false)
            fixture.controller.viewDidAppear(false)

            #expect(fixture.scrollView.contentOffset.y == 350)
        }
    }
}

@MainActor
private struct ScrollPositionFixture {
    let window: UIWindow
    let scrollView: UIScrollView
    let position: AlbumHomeScrollPosition
    let controller: AlbumHomeScrollPositionController

    init() {
        let window = UIWindow(frame: CGRect(x: 0, y: 0, width: 320, height: 500))
        let scrollView = UIScrollView(frame: window.bounds)
        scrollView.contentInsetAdjustmentBehavior = .never
        scrollView.contentSize = CGSize(width: 320, height: 2_000)
        window.addSubview(scrollView)
        let position = AlbumHomeScrollPosition()
        let controller = AlbumHomeScrollPositionController(position: position)
        controller.view.frame = CGRect(x: 0, y: 0, width: 320, height: 2_000)
        scrollView.addSubview(controller.view)
        controller.viewDidLayoutSubviews()
        controller.viewDidAppear(false)
        self.window = window
        self.scrollView = scrollView
        self.position = position
        self.controller = controller
    }
}
