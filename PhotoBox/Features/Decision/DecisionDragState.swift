import Foundation

nonisolated enum DecisionDragDirection: CaseIterable, Equatable, Sendable {
    case left
    case right
    case up
    case down
}

/// State machine for the four directional B01 drag gestures.
/// The first eight points identify and lock the dominant direction; movement
/// after that point is the effective distance used for the 100 point threshold.
nonisolated struct DecisionDragState: Equatable, Sendable {
    private(set) var direction: DecisionDragDirection?
    private(set) var progress: Double = 0
    private(set) var didTrigger = false

    private var originX: Double = 0
    private var originY: Double = 0
    private var currentX: Double = 0
    private var currentY: Double = 0

    var effectiveTranslation: (x: Double, y: Double) {
        (currentX - originX, currentY - originY)
    }

    @discardableResult
    mutating func update(x: Double, y: Double) -> DecisionDragDirection? {
        guard !didTrigger else { return nil }
        currentX = x
        currentY = y
        if direction == nil {
            let distance = max(abs(x), abs(y))
            guard distance > 8 else { return nil }
            // Keep watching nearly diagonal motion until one axis is clearly
            // dominant. This avoids committing a diagonal flick accidentally.
            guard abs(abs(x) - abs(y)) >= 4 else { return nil }
            direction = if abs(x) > abs(y) {
                x < 0 ? .left : .right
            } else {
                y < 0 ? .up : .down
            }
            originX = x
            originY = y
            progress = 0
            return nil
        }

        guard let direction else { return nil }
        let effectiveDistance: Double
        switch direction {
        case .left: effectiveDistance = max(0, originX - x)
        case .right: effectiveDistance = max(0, x - originX)
        case .up: effectiveDistance = max(0, originY - y)
        case .down: effectiveDistance = max(0, y - originY)
        }
        progress = min(1, effectiveDistance / 100)
        guard progress >= 1 else { return nil }
        didTrigger = true
        return direction
    }

    mutating func reset() {
        direction = nil
        progress = 0
        didTrigger = false
        originX = 0
        originY = 0
        currentX = 0
        currentY = 0
    }
}
