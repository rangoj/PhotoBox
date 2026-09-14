import SwiftUI
import Testing
@testable import PhotoBox

@Suite("PhotoBox motion policy")
struct PhotoBoxMotionTests {
    @Test("Reduce Motion disables local state-change animation")
    func reduceMotionDisablesAnimation() {
        let transaction: Transaction? = PhotoBoxMotion.transaction(reduceMotion: true)

        #expect(transaction?.disablesAnimations == true)
        #expect(transaction?.animation == nil)
    }

    @Test("Normal motion leaves the caller's native transaction unchanged")
    func normalMotionDoesNotOverrideTransaction() {
        let transaction: Transaction? = PhotoBoxMotion.transaction(reduceMotion: false)

        #expect(transaction == nil)
    }

    @Test("Normal motion executes directly and reports the native path")
    func normalMotionPerformsNativeAction() {
        var actionCount = 0
        var recordedMode: PhotoBoxMotion.Mode?

        PhotoBoxMotion.perform(reduceMotion: false, recordMode: { recordedMode = $0 }) {
            actionCount += 1
        }

        #expect(actionCount == 1)
        #expect(recordedMode == .native)
    }

    @Test("Reduce Motion executes once and reports the reduced path")
    func reduceMotionPerformsReducedAction() {
        var actionCount = 0
        var recordedMode: PhotoBoxMotion.Mode?

        PhotoBoxMotion.perform(reduceMotion: true, recordMode: { recordedMode = $0 }) {
            actionCount += 1
        }

        #expect(actionCount == 1)
        #expect(recordedMode == .reduced)
    }
}
