import Foundation
import Testing
@testable import PhotoBox

@Suite("B01 directional drag threshold")
struct DecisionDragStateTests {
    @Test("Recognition displacement is excluded and threshold fires immediately only once")
    func threshold() {
        var state = DecisionDragState()
        #expect(state.update(x: 8, y: 0) == nil)
        #expect(state.progress == 0)
        #expect(state.update(x: 9, y: 0) == nil)
        #expect(state.progress == 0)
        #expect(state.update(x: 108, y: 0) == nil)
        #expect(state.progress == 0.99)
        #expect(state.update(x: 109, y: 0) == .right)
        #expect(state.didTrigger)
        #expect(state.update(x: -200, y: 0) == nil)
        #expect(state.progress == 1)
    }

    @Test("A short drag can retreat but never changes its locked direction")
    func retreat() {
        var state = DecisionDragState()
        _ = state.update(x: 0, y: -9)
        _ = state.update(x: 0, y: -59)
        #expect(state.progress == 0.5)
        _ = state.update(x: 0, y: -34)
        #expect(state.progress == 0.25)
        #expect(state.update(x: 180, y: 180) == nil)
        #expect(state.direction == .up)
        #expect(state.progress == 0)
        state.reset()
        #expect(state.direction == nil)
        #expect(!state.didTrigger)
    }

    @Test("Ambiguous diagonal motion waits for a dominant direction")
    func diagonal() {
        var state = DecisionDragState()
        #expect(state.update(x: 20, y: 19) == nil)
        #expect(state.direction == nil)
        _ = state.update(x: 20, y: 30)
        #expect(state.direction == .down)
        #expect(state.progress == 0)
        #expect(state.update(x: 20, y: 130) == .down)
    }

    @Test("All four directions require 100 effective points", arguments: DecisionDragDirection.allCases)
    func directions(_ direction: DecisionDragDirection) {
        var state = DecisionDragState()
        let x = direction == .left ? -1.0 : direction == .right ? 1.0 : 0
        let y = direction == .up ? -1.0 : direction == .down ? 1.0 : 0
        _ = state.update(x: x * 8, y: y * 8)
        #expect(state.update(x: x * 68, y: y * 68) == nil)
        #expect(!state.didTrigger)
        #expect(state.update(x: x * 168, y: y * 168) == direction)
        #expect(state.update(x: x * 208, y: y * 208) == nil)
    }
}
